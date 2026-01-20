# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  test 'should get index' do
    get root_path
    assert_response :success
  end

  test 'should set current_llm_model from last query' do
    # Create a test query
    BedrockQuery.create!(
      model_id: 'anthropic.claude-3-sonnet-20240229-v1:0',
      input_tokens: 100,
      output_tokens: 200,
      user_query: 'Test query',
      latency_ms: 500,
      created_at: Time.current
    )

    get root_path
    assert_response :success
    assert_select '.explanation-subtitle', text: /LLM Model: Claude 3 Sonnet/
  end

  test 'should set current_llm_model from configuration when no queries exist' do
    # Clear all queries
    BedrockQuery.delete_all

    # Set configuration
    ENV['BEDROCK_MODEL_ID'] = 'anthropic.claude-3-haiku-20240307-v1:0'

    get root_path
    assert_response :success
    assert_select '.explanation-subtitle', text: /LLM Model: Claude 3 Haiku/
  ensure
    ENV.delete('BEDROCK_MODEL_ID')
  end

  test 'should set current_embedding_model from configuration' do
    get root_path
    assert_response :success
    # Check that both subtitles are present
    assert_select '.explanation-subtitle', minimum: 2
    # Check specifically for embedding model subtitle
    assert_select '.explanation-subtitle', text: /Embedding Model: Amazon Titan Embed/
  end

  test 'should set custom embedding model from configuration' do
    ENV['BEDROCK_EMBEDDING_MODEL_ID'] = 'cohere.embed-english-v3'

    get root_path
    assert_response :success
    # Check that both subtitles are present
    assert_select '.explanation-subtitle', minimum: 2
    # Get all subtitles and check that one contains the embedding model
    subtitles = css_select('.explanation-subtitle')
    embedding_subtitle = subtitles.find { |s| s.text.include?('Embedding Model:') }
    assert_not_nil embedding_subtitle, 'Should have embedding model subtitle'
    assert_match(/Embedding Model: Cohere Embed/, embedding_subtitle.text)
  ensure
    ENV.delete('BEDROCK_EMBEDDING_MODEL_ID')
  end

  test 'should format claude 3.5 sonnet correctly' do
    BedrockQuery.create!(
      model_id: 'anthropic.claude-3-5-sonnet-20241022-v1:0',
      input_tokens: 100,
      output_tokens: 200,
      user_query: 'Test',
      latency_ms: 500,
      created_at: Time.current
    )

    get root_path
    assert_response :success
    assert_select '.explanation-subtitle', text: /LLM Model: Claude 3.5 Sonnet/
  end

  test 'should format claude 3 opus correctly' do
    BedrockQuery.create!(
      model_id: 'anthropic.claude-3-opus-20240229-v1:0',
      input_tokens: 100,
      output_tokens: 200,
      user_query: 'Test',
      latency_ms: 500,
      created_at: Time.current
    )

    get root_path
    assert_response :success
    assert_select '.explanation-subtitle', text: /LLM Model: Claude 3 Opus/
  end

  test 'should handle model_id with us. prefix' do
    BedrockQuery.create!(
      model_id: 'us.anthropic.claude-3-haiku-20240307-v1:0',
      input_tokens: 100,
      output_tokens: 200,
      user_query: 'Test',
      latency_ms: 500,
      created_at: Time.current
    )

    get root_path
    assert_response :success
    assert_select '.explanation-subtitle', text: /LLM Model: Claude 3 Haiku/
  end
end
