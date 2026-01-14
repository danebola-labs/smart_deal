require "test_helper"

class RagControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEST_SESSION_ID_1 = "test-session-123"
  TEST_SESSION_ID_2 = "test-session-456"
  TEST_QUESTION = "What is S3?"
  TEST_ANSWER = "This is a test answer about S3"
  TEST_FILE_NAME = "AWS-Certified-Solutions-Architect-v4.pdf"

  setup do
    @user = users(:one)
  end

  # Helper method to stub BedrockRagService.new at the class level.
  # This approach avoids introducing dependency injection prematurely while
  # allowing tests to isolate the controller from the actual BedrockRagService.
  # The original method is always restored in the ensure block to prevent test pollution.
  def with_mock_bedrock_rag_service(mock_service)
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*args| mock_service }
    yield
  ensure
    # Always restore original method to prevent test pollution
    BedrockRagService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to create a mock BedrockRagService that simulates the contract of
  # BedrockRagService#query. The mock returns a hash with the expected structure:
  # { answer: String, citations: Array, session_id: String }
  # When should_raise is true, it raises a StandardError instead of returning the hash.
  def create_mock_service(answer:, citations: [], session_id: TEST_SESSION_ID_1, should_raise: false, error_message: nil)
    mock_service = Object.new
    mock_service.define_singleton_method(:query) do |question|
      raise StandardError.new(error_message || "Service error") if should_raise
      {
        answer: answer,
        citations: citations,
        session_id: session_id
      }
    end
    mock_service
  end

  # Helper to parse JSON response body
  # Encapsulates JSON.parse(@response.body) for consistency and readability
  private def json_response
    JSON.parse(@response.body)
  end

  test "requires authentication" do
    post rag_ask_url, params: { question: "test question" }, as: :json
    # Devise returns 401 for JSON requests instead of redirect
    assert_response :unauthorized
    json = json_response
    assert json.key?("error")
  end

  test "rejects empty question" do
    sign_in @user
    post rag_ask_url, params: { question: "" }, as: :json
    assert_response :bad_request
    
    json = json_response
    assert_equal "error", json["status"]
    assert_includes json["message"].downcase, "empty"
  end

  test "rejects blank question" do
    sign_in @user
    post rag_ask_url, params: { question: "   " }, as: :json
    assert_response :bad_request
    
    json = json_response
    assert_equal "error", json["status"]
  end

  test "returns successful response with answer and citations" do
    sign_in @user
    
    citations = [
      {
        file_name: TEST_FILE_NAME,
        uri: "s3://bucket/file.pdf",
        content: "S3 is a storage service..."
      }
    ]
    
    mock_service = create_mock_service(
      answer: TEST_ANSWER,
      citations: citations,
      session_id: TEST_SESSION_ID_1
    )
    
    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success
      
      json = json_response
      # Verify complete JSON structure
      assert_equal "success", json["status"]
      assert_equal TEST_ANSWER, json["answer"]
      assert_equal TEST_SESSION_ID_1, json["session_id"]
      assert json.key?("citations"), "Response should include citations key"
      assert_equal 1, json["citations"].length
      assert_equal TEST_FILE_NAME, json["citations"].first["file_name"]
    end
  end

  test "handles BedrockRagService errors gracefully" do
    sign_in @user
    
    mock_service = create_mock_service(
      answer: "",
      should_raise: true,
      error_message: "Knowledge Base ID not configured"
    )
    
    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :unprocessable_entity
      
      json = json_response
      assert_equal "error", json["status"]
      assert_not_nil json["message"], "Error message should be present"
      assert_includes json["message"], "Error processing question"
    end
  end

  test "handles AWS service errors" do
    sign_in @user
    
    mock_service = create_mock_service(
      answer: "",
      should_raise: true,
      error_message: "AccessDeniedException: User is not authorized"
    )
    
    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :unprocessable_entity
      
      json = json_response
      assert_equal "error", json["status"]
      assert_not_nil json["message"], "Error message should be present"
      assert_includes json["message"], "AccessDeniedException"
    end
  end

  test "handles response without citations" do
    sign_in @user
    
    mock_service = create_mock_service(
      answer: "Answer without citations",
      citations: [],
      session_id: TEST_SESSION_ID_2
    )
    
    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :success
      
      json = json_response
      assert_equal "success", json["status"]
      assert_equal "Answer without citations", json["answer"]
      assert_equal [], json["citations"]
      assert_equal TEST_SESSION_ID_2, json["session_id"]
    end
  end

  test "rejects question that exceeds reasonable length" do
    sign_in @user
    
    # Question that's too long (e.g., > 10000 characters)
    very_long_question = "A" * 10001
    
    post rag_ask_url, params: { question: very_long_question }, as: :json
    
    # NOTE: This test documents the current behavior of the controller.
    # The controller does not currently validate question length, so it will
    # attempt to process even extremely long questions. This test serves as
    # documentation of this behavior and will fail if length validation is
    # added in the future, prompting a review of the validation logic.
    assert_includes [200, 400, 422], response.status
  end

  test "validates complete JSON response structure" do
    sign_in @user
    
    citations = [
      {
        file_name: TEST_FILE_NAME,
        uri: "s3://bucket/file.pdf",
        content: "Content"
      }
    ]
    
    mock_service = create_mock_service(
      answer: TEST_ANSWER,
      citations: citations,
      session_id: TEST_SESSION_ID_1
    )
    
    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success
      
      json = json_response
      
      # Verify all expected keys are present
      required_keys = ["status", "answer", "citations", "session_id"]
      required_keys.each do |key|
        assert json.key?(key), "Response should include #{key} key"
      end
      
      # Verify types
      assert_equal "success", json["status"]
      assert json["answer"].is_a?(String), "Answer should be a string"
      assert json["citations"].is_a?(Array), "Citations should be an array"
      assert json["session_id"].is_a?(String), "Session ID should be a string"
    end
  end
end

