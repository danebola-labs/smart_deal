# frozen_string_literal: true

require 'test_helper'

class TwilioControllerTest < ActionDispatch::IntegrationTest
  TEST_SESSION_ID = 'test-session-123'
  TEST_QUESTION = 'What is S3?'
  TEST_ANSWER = 'This is a test answer about S3'

  # Helper method to stub BedrockRagService.new at the class level.
  def with_mock_bedrock_rag_service(mock_service)
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    BedrockRagService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to create a mock BedrockRagService
  def create_mock_service(answer:, citations: [], session_id: TEST_SESSION_ID, should_raise: false,
                          error_class: StandardError, error_message: nil)
    mock_session_id = session_id
    mock_service = Object.new
    mock_service.define_singleton_method(:query) do |_question, session_id: nil, **_kwargs|
      raise error_class, error_message || 'Service error' if should_raise

      {
        answer: answer,
        citations: citations,
        session_id: session_id || mock_session_id
      }
    end
    mock_service
  end

  test 'webhook does not require authentication' do
    mock_service = create_mock_service(answer: TEST_ANSWER)

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }
      assert_response :success
    end
  end

  test 'webhook returns TwiML XML response' do
    mock_service = create_mock_service(answer: TEST_ANSWER)

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_equal 'application/xml; charset=utf-8', @response.content_type

      # Verify TwiML structure
      assert_includes @response.body, '<?xml'
      assert_includes @response.body, '<Response>'
      assert_includes @response.body, '<Message>'
      assert_includes @response.body, TEST_ANSWER
      assert_includes @response.body, '</Message>'
      assert_includes @response.body, '</Response>'
    end
  end

  test 'webhook returns answer with citations' do
    citations = [ 'document1.pdf', 'document2.pdf' ]
    mock_service = create_mock_service(answer: TEST_ANSWER, citations: citations)

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, TEST_ANSWER
      assert_includes @response.body, 'Sources:'
      assert_includes @response.body, 'document1.pdf'
      assert_includes @response.body, 'document2.pdf'
    end
  end

  test 'webhook handles empty message' do
    post twilio_webhook_url, params: { 'Body' => '', 'From' => 'whatsapp:+56912345678' }

    assert_response :success
    assert_includes @response.body, '<Response>'
    assert_includes @response.body, 'Please send a question'
    assert_includes @response.body, 'cannot be empty'
  end

  test 'webhook handles nil message' do
    post twilio_webhook_url, params: { 'Body' => nil, 'From' => 'whatsapp:+56912345678' }

    assert_response :success
    assert_includes @response.body, 'Please send a question'
  end

  test 'webhook handles whitespace-only message' do
    post twilio_webhook_url, params: { 'Body' => '   ', 'From' => 'whatsapp:+56912345678' }

    assert_response :success
    assert_includes @response.body, 'Please send a question'
  end

  test 'webhook handles MissingKnowledgeBaseError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::MissingKnowledgeBaseError,
      error_message: 'Knowledge Base ID not configured'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, '<Response>'
      assert_includes @response.body, 'The query service is not properly configured'
    end
  end

  test 'webhook handles BedrockServiceError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: 'Failed to query Knowledge Base'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, '<Response>'
      assert_includes @response.body, 'Error querying knowledge base'
      assert_includes @response.body, 'Please try again later'
    end
  end

  test 'webhook handles unexpected StandardError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: StandardError,
      error_message: 'Unexpected database error'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, '<Response>'
      assert_includes @response.body, 'Sorry, an error occurred'
      assert_includes @response.body, 'Unexpected database error'
    end
  end

  test 'webhook returns fallback message when answer is empty' do
    mock_service = create_mock_service(answer: '')

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, "I couldn't find an answer"
    end
  end

  test 'webhook returns fallback message when answer is nil' do
    mock_service = create_mock_service(answer: nil)

    with_mock_bedrock_rag_service(mock_service) do
      post twilio_webhook_url, params: { 'Body' => TEST_QUESTION, 'From' => 'whatsapp:+56912345678' }

      assert_response :success
      assert_includes @response.body, "I couldn't find an answer"
    end
  end
end
