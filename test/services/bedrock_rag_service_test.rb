require "test_helper"
require "ostruct"

class BedrockRagServiceTest < ActiveSupport::TestCase
  # Disable parallelization for this test class because it manipulates
  # global constants (Aws) which can cause race conditions when running in parallel
  parallelize(workers: 1)

  TEST_KB_ID = "test-kb-id"
  TEST_AWS_REGION = "us-east-1"
  TEST_SESSION_ID = "test-session-123"

  setup do
    # Set up test knowledge base ID to avoid initialization errors
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = TEST_KB_ID
    ENV["AWS_REGION"] = TEST_AWS_REGION
    # Clean up BedrockQuery records between tests
    BedrockQuery.delete_all
  end

  teardown do
    ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
    ENV.delete("AWS_REGION")
  end

  # Fake AWS BedrockAgentRuntime Client
  class FakeBedrockAgentRuntimeClient
    attr_accessor :retrieve_and_generate_response, :should_raise_error, :error_message

    def initialize(*)
      @retrieve_and_generate_response = nil
      @should_raise_error = false
      @error_message = nil
    end

    def retrieve_and_generate(params)
      raise StandardError.new(@error_message || "AWS Error") if @should_raise_error
      @retrieve_and_generate_response || default_response
    end

    private

    def default_response
      # Create a mock response object that mimics AWS SDK response structure
      ::OpenStruct.new(
        output: ::OpenStruct.new(
          text: "This is a test answer about AWS S3."
        ),
        citations: [
          ::OpenStruct.new(
            retrieved_references: [
              ::OpenStruct.new(
                location: ::OpenStruct.new(
                  s3_location: ::OpenStruct.new(
                    uri: "s3://bucket/documents/AWS-Certified-Solutions-Architect-v4.pdf"
                  )
                ),
                content: ::OpenStruct.new(
                  text: "Amazon S3 is a storage service that provides object storage..."
                )
              )
            ]
          )
        ],
        session_id: TEST_SESSION_ID,
        usage: ::OpenStruct.new(
          input_tokens: 50,
          output_tokens: 100
        )
      )
    end
  end

  # Helper method to stub AWS BedrockAgentRuntime client
  def with_mock_bedrock_client(mock_response: nil, should_raise: false, error_message: nil)
    fake_client = FakeBedrockAgentRuntimeClient.new
    
    if mock_response
      fake_client.retrieve_and_generate_response = mock_response
    end
    
    if should_raise
      fake_client.should_raise_error = true
      fake_client.error_message = error_message
    end
    
    # Save original .new method
    original_new = Aws::BedrockAgentRuntime::Client.method(:new)
    
    # Stub the .new method to return our fake client
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args| fake_client }
    
    yield fake_client
  ensure
    # Restore original method
    if original_new
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args| original_new.call(*args) }
    end
  end

  # Helper method to temporarily modify environment variables
  def with_env_vars(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    original.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test "query returns answer and citations when successful" do
    with_mock_bedrock_client do
      service = BedrockRagService.new
      result = service.query("What is S3?")

      assert_equal "This is a test answer about AWS S3.", result[:answer]
      assert_equal TEST_SESSION_ID, result[:session_id]
      assert result[:citations].is_a?(Array)
      assert_equal 1, result[:citations].length
      
      citation = result[:citations].first
      assert_equal "AWS-Certified-Solutions-Architect-v4.pdf", citation[:file_name]
      assert_equal "s3://bucket/documents/AWS-Certified-Solutions-Architect-v4.pdf", citation[:uri]
      assert_not_nil citation[:content], "Citation content should not be nil"
    end
  end

  test "query saves BedrockQuery to database" do
    with_mock_bedrock_client do
      service = BedrockRagService.new
      
      assert_difference "BedrockQuery.count", 1 do
        service.query("What is S3?")
      end
      
      query = BedrockQuery.last
      assert_equal "anthropic.claude-3-haiku-20240307-v1:0", query.model_id
      assert_equal 50, query.input_tokens
      assert_equal 100, query.output_tokens
      assert_equal "What is S3?", query.user_query
      assert_kind_of Numeric, query.latency_ms, "latency_ms should be a number"
      assert query.latency_ms >= 0, "latency_ms should be >= 0, got #{query.latency_ms}"
    end
  end

  test "query handles response without citations" do
    response_without_citations = ::OpenStruct.new(
      output: ::OpenStruct.new(text: "Answer without citations"),
      citations: [],
      session_id: "test-session-456",
      usage: ::OpenStruct.new(input_tokens: 30, output_tokens: 50)
    )

    with_mock_bedrock_client(mock_response: response_without_citations) do
      service = BedrockRagService.new
      result = service.query("Test question")

      assert_equal "Answer without citations", result[:answer]
      assert_equal [], result[:citations]
      assert_equal "test-session-456", result[:session_id]
    end
  end

  test "query handles response without usage data and estimates tokens" do
    response_without_usage = ::OpenStruct.new(
      output: ::OpenStruct.new(text: "This is a longer answer that should generate some tokens for estimation purposes."),
      citations: [],
      session_id: "test-session-789"
      # No usage field
    )

    with_mock_bedrock_client(mock_response: response_without_usage) do
      service = BedrockRagService.new
      question = "What is AWS?"
      
      result = service.query(question)
      
      # Should estimate tokens based on text length
      query = BedrockQuery.last
      assert query.input_tokens > 0
      assert query.output_tokens > 0
      # Rough check: output text is longer, so output_tokens should be higher
      assert query.output_tokens >= query.input_tokens
    end
  end

  test "query handles AWS errors gracefully" do
    BedrockQuery.delete_all
    
    with_mock_bedrock_client(should_raise: true, error_message: "AccessDeniedException: User is not authorized") do
      service = BedrockRagService.new
      
      assert_raises(RuntimeError) do
        service.query("Test question")
      end
      
      # Should not save query on error
      assert_equal 0, BedrockQuery.count
    end
  end

  test "query handles timeout errors" do
    with_mock_bedrock_client(should_raise: true, error_message: "Net::ReadTimeout") do
      service = BedrockRagService.new
      
      assert_raises(RuntimeError) do
        service.query("Test question")
      end
    end
  end

  test "query formats citations with different location structures" do
    # Test citation with direct URI (not s3_location)
    citation_with_uri = ::OpenStruct.new(
      retrieved_references: [
        ::OpenStruct.new(
          location: ::OpenStruct.new(
            uri: "s3://bucket/direct-uri-document.pdf"
          ),
          content: ::OpenStruct.new(text: "Content from direct URI")
        )
      ]
    )

    response_with_uri = ::OpenStruct.new(
      output: ::OpenStruct.new(text: "Answer with URI citation"),
      citations: [citation_with_uri],
      session_id: "test-session-uri",
      usage: ::OpenStruct.new(input_tokens: 40, output_tokens: 80)
    )

    with_mock_bedrock_client(mock_response: response_with_uri) do
      service = BedrockRagService.new
      result = service.query("Test question")

      assert_equal 1, result[:citations].length
      citation = result[:citations].first
      assert_equal "direct-uri-document.pdf", citation[:file_name]
      assert_equal "s3://bucket/direct-uri-document.pdf", citation[:uri]
    end
  end

  test "query truncates citation content to 200 characters" do
    long_content = "A" * 300 # 300 characters
    
    citation_with_long_content = ::OpenStruct.new(
      retrieved_references: [
        ::OpenStruct.new(
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(uri: "s3://bucket/long-doc.pdf")
          ),
          content: ::OpenStruct.new(text: long_content)
        )
      ]
    )

    response_with_long_content = ::OpenStruct.new(
      output: ::OpenStruct.new(text: "Answer"),
      citations: [citation_with_long_content],
      session_id: "test-session",
      usage: ::OpenStruct.new(input_tokens: 30, output_tokens: 60)
    )

    with_mock_bedrock_client(mock_response: response_with_long_content) do
      service = BedrockRagService.new
      result = service.query("Test question")

      citation = result[:citations].first
      assert citation[:content].length <= 200
    end
  end

  test "query raises error when knowledge base ID is not configured" do
    with_env_vars("BEDROCK_KNOWLEDGE_BASE_ID" => nil) do
      with_mock_bedrock_client do
        service = BedrockRagService.new
        
        error = assert_raises(RuntimeError) do
          service.query("Test question")
        end
        
        assert_includes error.message, "Knowledge Base ID not configured"
      end
    end
  end

  test "query uses custom model_arn when provided" do
    custom_model_arn = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
    
    with_mock_bedrock_client do |mock_client|
      service = BedrockRagService.new
      service.query("Test question", model_arn: custom_model_arn)
      
      # Verify that the query was saved with the custom model ID
      query = BedrockQuery.last
      assert_equal "anthropic.claude-3-sonnet-20240229-v1:0", query.model_id
    end
  end

  test "query handles citation content extraction errors gracefully" do
    # Citation with content that raises error when accessing .text
    citation_with_error = ::OpenStruct.new(
      retrieved_references: [
        ::OpenStruct.new(
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(uri: "s3://bucket/error-doc.pdf")
          ),
          content: ::OpenStruct.new(
            # Simulate error when accessing text
            text: nil
          )
        )
      ]
    )

    response_with_error = ::OpenStruct.new(
      output: ::OpenStruct.new(text: "Answer"),
      citations: [citation_with_error],
      session_id: "test-session",
      usage: ::OpenStruct.new(input_tokens: 30, output_tokens: 60)
    )

    with_mock_bedrock_client(mock_response: response_with_error) do
      service = BedrockRagService.new
      
      # Should not raise error, just handle gracefully
      result = service.query("Test question")
      
      assert_equal 1, result[:citations].length
      citation = result[:citations].first
      assert_nil citation[:content]
    end
  end
end

