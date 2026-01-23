# frozen_string_literal: true

require 'test_helper'

class RagControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEST_SESSION_ID = 'test-session-123'
  TEST_QUESTION = 'What is S3?'
  TEST_ANSWER = 'This is a test answer about S3'

  setup do
    @user = users(:one)
  end

  # Helper method to stub BedrockRagService.new at the class level.
  def with_mock_bedrock_rag_service(mock_service)
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    BedrockRagService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to create a mock BedrockRagService that simulates the contract of
  # BedrockRagService#query. The mock returns a hash with the expected structure:
  # { answer: String, citations: Array, session_id: String }
  def create_mock_service(answer:, citations: [], session_id: TEST_SESSION_ID, should_raise: false,
                          error_class: StandardError, error_message: nil)
    mock_session_id = session_id
    mock_service = Object.new
    mock_service.define_singleton_method(:query) do |_question, session_id: nil, **kwargs|
      if should_raise
        raise error_class, error_message || 'Service error'
      end

      {
        answer: answer,
        citations: citations,
        session_id: session_id || mock_session_id
      }
    end
    mock_service
  end

  test 'requires authentication' do
    post rag_ask_url, params: { question: 'test question' }, as: :json
    assert_response :unauthorized
    json = json_response
    assert json.key?('error')
  end

  test 'rejects empty question' do
    sign_in @user
    post rag_ask_url, params: { question: '' }, as: :json
    assert_response :bad_request

    json = json_response
    assert_equal 'error', json['status']
    assert_includes json['message'].downcase, 'empty'
  end

  test 'returns successful response with answer and citations' do
    sign_in @user

    citations = [{ filename: 'test.pdf', title: 'Test Document' }]

    mock_service = create_mock_service(
      answer: TEST_ANSWER,
      citations: citations,
      session_id: TEST_SESSION_ID
    )

    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      json = json_response
      assert_equal 'success', json['status']
      assert_equal TEST_ANSWER, json['answer']
      assert_equal TEST_SESSION_ID, json['session_id']
      assert json.key?('citations')
      assert json['citations'].is_a?(Array)
      assert_equal 1, json['citations'].length
      assert_equal 'test.pdf', json['citations'].first['filename']
      assert_equal 'Test Document', json['citations'].first['title']
    end
  end

  test 'handles BedrockRagService errors gracefully' do
    sign_in @user

    # Test MissingKnowledgeBaseError
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::MissingKnowledgeBaseError,
      error_message: 'Knowledge Base ID not configured'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :internal_server_error

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'RAG service is not properly configured', json['message']
    end

    # Test BedrockServiceError
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: 'Failed to query Knowledge Base'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :bad_gateway

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'Error querying knowledge base', json['message']
    end

    # Test generic StandardError
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: StandardError,
      error_message: 'Unexpected error'
    )

    with_mock_bedrock_rag_service(mock_service) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :internal_server_error

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'Unexpected error processing request', json['message']
    end
  end

  private

  # Helper to parse JSON response body
  def json_response
    JSON.parse(@response.body)
  end
end
