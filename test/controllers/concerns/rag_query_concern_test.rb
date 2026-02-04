# frozen_string_literal: true

require 'test_helper'

class RagQueryConcernTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestController
    include RagQueryConcern

    # Mock render method for testing render_rag_json_error
    attr_reader :rendered_json, :rendered_status

    def render(json:, status:)
      @rendered_json = json
      @rendered_status = status
    end
  end

  setup do
    @controller = TestController.new
  end

  # Helper method to stub BedrockRagService.new at the class level.
  def with_mock_bedrock_rag_service(mock_service)
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    BedrockRagService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to create a mock BedrockRagService
  def create_mock_service(answer:, citations: [], session_id: 'test-session', should_raise: false,
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

  # ============================================
  # Tests for execute_rag_query
  # ============================================

  test 'execute_rag_query returns success result with valid question' do
    mock_service = create_mock_service(
      answer: 'Test answer',
      citations: [ 'doc1.pdf' ],
      session_id: 'session-123'
    )

    with_mock_bedrock_rag_service(mock_service) do
      result = @controller.send(:execute_rag_query, 'What is S3?')

      assert result.success?
      assert_equal 'Test answer', result.answer
      assert_equal [ 'doc1.pdf' ], result.citations
      assert_equal 'session-123', result.session_id
      assert_nil result.error_type
    end
  end

  test 'execute_rag_query returns error for blank question' do
    result = @controller.send(:execute_rag_query, '')

    assert_not result.success?
    assert_equal :blank_question, result.error_type
    assert_nil result.answer
  end

  test 'execute_rag_query returns error for nil question' do
    result = @controller.send(:execute_rag_query, nil)

    assert_not result.success?
    assert_equal :blank_question, result.error_type
  end

  test 'execute_rag_query returns error for whitespace-only question' do
    result = @controller.send(:execute_rag_query, '   ')

    assert_not result.success?
    assert_equal :blank_question, result.error_type
  end

  test 'execute_rag_query handles MissingKnowledgeBaseError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::MissingKnowledgeBaseError,
      error_message: 'KB not configured'
    )

    with_mock_bedrock_rag_service(mock_service) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :config_error, result.error_type
      assert_equal 'KB not configured', result.error_message
    end
  end

  test 'execute_rag_query handles BedrockServiceError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: 'AWS error'
    )

    with_mock_bedrock_rag_service(mock_service) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :service_error, result.error_type
      assert_equal 'AWS error', result.error_message
    end
  end

  test 'execute_rag_query handles StandardError' do
    mock_service = create_mock_service(
      answer: '',
      should_raise: true,
      error_class: StandardError,
      error_message: 'Unexpected error'
    )

    with_mock_bedrock_rag_service(mock_service) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :unexpected_error, result.error_type
      assert_equal 'Unexpected error', result.error_message
    end
  end

  # ============================================
  # Tests for format_rag_response_for_whatsapp
  # ============================================

  test 'format_rag_response_for_whatsapp returns answer for success' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'This is the answer',
      citations: []
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_equal 'This is the answer', formatted
  end

  test 'format_rag_response_for_whatsapp includes citations' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'This is the answer',
      citations: [ 'doc1.pdf', 'doc2.pdf' ]
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'This is the answer'
    assert_includes formatted, 'Sources:'
    assert_includes formatted, 'doc1.pdf'
    assert_includes formatted, 'doc2.pdf'
  end

  test 'format_rag_response_for_whatsapp returns fallback for empty answer' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: '',
      citations: []
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_equal "I couldn't find an answer.", formatted
  end

  test 'format_rag_response_for_whatsapp returns error message for blank_question' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :blank_question
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Please send a question'
  end

  test 'format_rag_response_for_whatsapp returns error message for config_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :config_error
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'not properly configured'
  end

  test 'format_rag_response_for_whatsapp returns error message for service_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :service_error
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Error querying knowledge base'
    assert_includes formatted, 'Please try again later'
  end

  test 'format_rag_response_for_whatsapp returns error message for unexpected_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :unexpected_error,
      error_message: 'Something went wrong'
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Sorry, an error occurred'
    assert_includes formatted, 'Something went wrong'
  end

  # ============================================
  # Tests for render_rag_json_error
  # ============================================

  test 'render_rag_json_error renders bad_request for blank_question' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :blank_question
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Question cannot be empty', @controller.rendered_json[:message]
    assert_equal :bad_request, @controller.rendered_status
  end

  test 'render_rag_json_error renders internal_server_error for config_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :config_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'RAG service is not properly configured', @controller.rendered_json[:message]
    assert_equal :internal_server_error, @controller.rendered_status
  end

  test 'render_rag_json_error renders bad_gateway for service_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :service_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Error querying knowledge base', @controller.rendered_json[:message]
    assert_equal :bad_gateway, @controller.rendered_status
  end

  test 'render_rag_json_error renders internal_server_error for unexpected_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :unexpected_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Unexpected error processing request', @controller.rendered_json[:message]
    assert_equal :internal_server_error, @controller.rendered_status
  end
end
