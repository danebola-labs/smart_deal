# frozen_string_literal: true

require 'test_helper'
require 'ostruct'
require 'aws-sdk-bedrockruntime'

class BedrockRagServiceTest < ActiveSupport::TestCase
  # Disable parallelization for this test class because it manipulates
  # global constants (Aws) which can cause race conditions when running in parallel
  parallelize(workers: 1)

  TEST_KB_ID = 'test-kb-id'
  TEST_AWS_REGION = 'us-east-1'
  TEST_SESSION_ID = 'test-session-123'

  setup do
    # Set up test knowledge base ID to avoid initialization errors
    ENV['BEDROCK_KNOWLEDGE_BASE_ID'] = TEST_KB_ID
    ENV['AWS_REGION'] = TEST_AWS_REGION
    # Clean up BedrockQuery records between tests
    BedrockQuery.delete_all
  end

  teardown do
    ENV.delete('BEDROCK_KNOWLEDGE_BASE_ID')
    ENV.delete('AWS_REGION')
  end

  # Fake AWS BedrockAgentRuntime Client
  class FakeBedrockAgentRuntimeClient
    attr_accessor :retrieve_response, :should_raise_error, :error_message

    def initialize(*)
      @retrieve_response = nil
      @should_raise_error = false
      @error_message = nil
    end

    def retrieve(_params)
      raise StandardError, @error_message || 'AWS Error' if @should_raise_error

      @retrieve_response || default_retrieve_response
    end

    private

    def default_retrieve_response
      # Create a mock retrieve response with retrieval_results
      ::OpenStruct.new(
        retrieval_results: [
          ::OpenStruct.new(
            content: ::OpenStruct.new(
              text: 'Amazon S3 is a storage service that provides object storage...'
            ),
            location: ::OpenStruct.new(
              s3_location: ::OpenStruct.new(
                uri: 's3://bucket/documents/AWS-Certified-Solutions-Architect-v4.pdf'
              )
            ),
            score: 0.85,
            metadata: {}
          )
        ]
      )
    end
  end

  # Fake AWS BedrockRuntime Client for LLM invocation
  class FakeBedrockRuntimeClient
    attr_accessor :invoke_model_response, :should_raise_error, :error_message

    def initialize(*)
      @invoke_model_response = nil
      @should_raise_error = false
      @error_message = nil
    end

    def invoke_model(_params)
      raise StandardError, @error_message || 'AWS Error' if @should_raise_error

      @invoke_model_response || default_invoke_model_response
    end

    private

    def default_invoke_model_response
      # Create a mock LLM response
      response_body = {
        'content' => [
          {
            'text' => 'This is a test answer about AWS S3.'
          }
        ]
      }.to_json

      ::OpenStruct.new(
        body: ::OpenStruct.new(read: response_body)
      )
    end
  end

  # Helper method to stub AWS BedrockAgentRuntime and BedrockRuntime clients
  def with_mock_bedrock_client(mock_retrieve_response: nil, mock_llm_response: nil, should_raise: false,
                               error_message: nil)
    fake_agent_client = FakeBedrockAgentRuntimeClient.new
    fake_runtime_client = FakeBedrockRuntimeClient.new

    fake_agent_client.retrieve_response = mock_retrieve_response if mock_retrieve_response

    fake_runtime_client.invoke_model_response = mock_llm_response if mock_llm_response

    if should_raise
      fake_agent_client.should_raise_error = true
      fake_agent_client.error_message = error_message
    end

    # Save original .new methods
    original_agent_new = Aws::BedrockAgentRuntime::Client.method(:new)
    original_runtime_new = Aws::BedrockRuntime::Client.method(:new)

    # Stub the .new methods to return our fake clients
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*_args| fake_agent_client }
    Aws::BedrockRuntime::Client.define_singleton_method(:new) { |*_args| fake_runtime_client }

    yield fake_agent_client
  ensure
    # Restore original methods
    if original_agent_new
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args| original_agent_new.call(*args) }
    end
    if original_runtime_new
      Aws::BedrockRuntime::Client.define_singleton_method(:new) { |*args| original_runtime_new.call(*args) }
    end
  end

  # Helper method to temporarily modify environment variables
  def with_env_vars(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV.fetch(key, nil)
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

  test 'query returns answer and citations when successful' do
    with_mock_bedrock_client do
      service = BedrockRagService.new
      result = service.query('What is S3?')

      assert_equal 'This is a test answer about AWS S3.', result[:answer]
      assert_nil result[:session_id] # retrieve API doesn't return session_id
      assert result[:citations].is_a?(Array)
      assert_equal 1, result[:citations].length

      citation = result[:citations].first
      assert_equal 'AWS-Certified-Solutions-Architect-v4.pdf', citation[:file_name]
      assert_equal 'Amazon S3 is a storage service that provides object storage...', citation[:chunk]
      assert_equal 0.85, citation[:similarity_score]
      assert_equal 1, citation[:rank]
    end
  end

  test 'query saves BedrockQuery to database' do
    with_mock_bedrock_client do
      service = BedrockRagService.new

      assert_difference 'BedrockQuery.count', 1 do
        service.query('What is S3?')
      end

      query = BedrockQuery.last
      assert_equal 'anthropic.claude-3-haiku-20240307-v1:0', query.model_id
      # Tokens are now estimated, so just verify they're positive numbers
      assert query.input_tokens.positive?, 'input_tokens should be > 0'
      assert query.output_tokens.positive?, 'output_tokens should be > 0'
      assert_equal 'What is S3?', query.user_query
      assert_kind_of Numeric, query.latency_ms, 'latency_ms should be a number'
      assert query.latency_ms >= 0, "latency_ms should be >= 0, got #{query.latency_ms}"
    end
  end

  test 'query handles response without citations' do
    retrieve_response_without_results = ::OpenStruct.new(
      retrieval_results: []
    )

    llm_response = ::OpenStruct.new(
      body: ::OpenStruct.new(
        read: { 'content' => [{ 'text' => 'Answer without citations' }] }.to_json
      )
    )

    with_mock_bedrock_client(mock_retrieve_response: retrieve_response_without_results,
                             mock_llm_response: llm_response) do
      service = BedrockRagService.new
      result = service.query('Test question')

      assert_equal 'Answer without citations', result[:answer]
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'query handles response without usage data and estimates tokens' do
    retrieve_response = ::OpenStruct.new(
      retrieval_results: []
    )

    llm_response = ::OpenStruct.new(
      body: ::OpenStruct.new(
        read: { 'content' => [{ 'text' => 'This is a longer answer that should generate some tokens for estimation purposes.' }] }.to_json
      )
    )

    with_mock_bedrock_client(mock_retrieve_response: retrieve_response, mock_llm_response: llm_response) do
      service = BedrockRagService.new
      question = 'What is AWS?'

      service.query(question)

      # Should estimate tokens based on text length
      query = BedrockQuery.last
      assert query.input_tokens.positive?
      assert query.output_tokens.positive?
      # Rough check: output text is longer, so output_tokens should be higher
      assert query.output_tokens >= query.input_tokens
    end
  end

  test 'query handles AWS errors gracefully' do
    BedrockQuery.delete_all

    with_mock_bedrock_client(should_raise: true, error_message: 'AccessDeniedException: User is not authorized') do
      service = BedrockRagService.new

      assert_raises(RuntimeError) do
        service.query('Test question')
      end

      # Should not save query on error
      assert_equal 0, BedrockQuery.count
    end
  end

  test 'query handles timeout errors' do
    with_mock_bedrock_client(should_raise: true, error_message: 'Net::ReadTimeout') do
      service = BedrockRagService.new

      assert_raises(RuntimeError) do
        service.query('Test question')
      end
    end
  end

  test 'query formats citations with different location structures' do
    # Test citation with s3_location structure
    retrieve_response = ::OpenStruct.new(
      retrieval_results: [
        ::OpenStruct.new(
          content: ::OpenStruct.new(text: 'Content from document'),
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(
              uri: 's3://bucket/direct-uri-document.pdf'
            )
          ),
          score: 0.75,
          metadata: {}
        )
      ]
    )

    llm_response = ::OpenStruct.new(
      body: ::OpenStruct.new(
        read: { 'content' => [{ 'text' => 'Answer with URI citation' }] }.to_json
      )
    )

    with_mock_bedrock_client(mock_retrieve_response: retrieve_response, mock_llm_response: llm_response) do
      service = BedrockRagService.new
      result = service.query('Test question')

      assert_equal 1, result[:citations].length
      citation = result[:citations].first
      assert_equal 'direct-uri-document.pdf', citation[:file_name]
      assert_equal 'Content from document', citation[:chunk]
      assert_equal 0.75, citation[:similarity_score]
      assert_equal 1, citation[:rank]
    end
  end

  test 'query returns full chunk text without truncation' do
    long_content = 'A' * 300 # 300 characters

    retrieve_response = ::OpenStruct.new(
      retrieval_results: [
        ::OpenStruct.new(
          content: ::OpenStruct.new(text: long_content),
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(uri: 's3://bucket/long-doc.pdf')
          ),
          score: 0.80,
          metadata: {}
        )
      ]
    )

    llm_response = ::OpenStruct.new(
      body: ::OpenStruct.new(
        read: { 'content' => [{ 'text' => 'Answer' }] }.to_json
      )
    )

    with_mock_bedrock_client(mock_retrieve_response: retrieve_response, mock_llm_response: llm_response) do
      service = BedrockRagService.new
      result = service.query('Test question')

      citation = result[:citations].first
      # Chunk should not be truncated in the service (truncation happens in UI)
      assert_equal 300, citation[:chunk].length
      assert_equal long_content, citation[:chunk]
    end
  end

  test 'query raises error when knowledge base ID is not configured' do
    with_env_vars('BEDROCK_KNOWLEDGE_BASE_ID' => nil) do
      with_mock_bedrock_client do
        service = BedrockRagService.new

        error = assert_raises(RuntimeError) do
          service.query('Test question')
        end

        assert_includes error.message, 'Knowledge Base ID not configured'
      end
    end
  end

  test 'query uses custom model_arn when provided' do
    custom_model_arn = 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0'

    with_mock_bedrock_client do |_mock_client|
      service = BedrockRagService.new
      service.query('Test question', model_arn: custom_model_arn)

      # Verify that the query was saved with the custom model ID
      query = BedrockQuery.last
      assert_equal 'anthropic.claude-3-sonnet-20240229-v1:0', query.model_id
    end
  end

  test 'query handles citation content extraction errors gracefully' do
    # Citation with nil content text
    retrieve_response = ::OpenStruct.new(
      retrieval_results: [
        ::OpenStruct.new(
          content: ::OpenStruct.new(text: nil),
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(uri: 's3://bucket/error-doc.pdf')
          ),
          score: 0.70,
          metadata: {}
        )
      ]
    )

    llm_response = ::OpenStruct.new(
      body: ::OpenStruct.new(
        read: { 'content' => [{ 'text' => 'Answer' }] }.to_json
      )
    )

    with_mock_bedrock_client(mock_retrieve_response: retrieve_response, mock_llm_response: llm_response) do
      service = BedrockRagService.new

      # Should not raise error, just handle gracefully
      result = service.query('Test question')

      assert_equal 1, result[:citations].length
      citation = result[:citations].first
      assert_nil citation[:chunk]
      assert_equal 'error-doc.pdf', citation[:file_name]
    end
  end
end
