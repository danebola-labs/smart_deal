# frozen_string_literal: true

require 'test_helper'

class ModelNameHelperTest < ActionView::TestCase
  include ModelNameHelper

  setup do
    BedrockQuery.destroy_all
  end

  test 'current_llm_model_name uses last query model_id' do
    BedrockQuery.create!(
      model_id: 'anthropic.claude-3-sonnet-20240229-v1:0',
      input_tokens: 100,
      output_tokens: 200,
      user_query: 'Test',
      latency_ms: 500,
      created_at: Time.current
    )

    assert_equal 'Claude 3 Sonnet', current_llm_model_name
  end

  test 'current_llm_model_name uses configuration when no queries exist' do
    BedrockQuery.delete_all
    ENV['BEDROCK_MODEL_ID'] = 'anthropic.claude-3-haiku-20240307-v1:0'

    assert_equal 'Claude 3 Haiku', current_llm_model_name
  ensure
    ENV.delete('BEDROCK_MODEL_ID')
  end

  test 'current_llm_model_name uses default when no query and no configuration' do
    BedrockQuery.delete_all
    ENV.delete('BEDROCK_MODEL_ID')

    assert_equal 'Claude 3 Haiku', current_llm_model_name
  end

  test 'current_embedding_model_name uses configuration' do
    ENV.delete('BEDROCK_EMBEDDING_MODEL_ID')

    assert_equal 'Amazon Titan Embed', current_embedding_model_name
  end

  test 'current_embedding_model_name uses custom configuration' do
    ENV['BEDROCK_EMBEDDING_MODEL_ID'] = 'cohere.embed-english-v3'

    assert_equal 'Cohere Embed', current_embedding_model_name
  ensure
    ENV.delete('BEDROCK_EMBEDDING_MODEL_ID')
  end

  test 'format_llm_model_name formats claude 3.5 sonnet' do
    assert_equal 'Claude 3.5 Sonnet', send(:format_llm_model_name, 'anthropic.claude-3-5-sonnet-20241022-v1:0')
  end

  test 'format_llm_model_name formats claude 3 sonnet' do
    assert_equal 'Claude 3 Sonnet', send(:format_llm_model_name, 'anthropic.claude-3-sonnet-20240229-v1:0')
  end

  test 'format_llm_model_name formats claude 3 haiku' do
    assert_equal 'Claude 3 Haiku', send(:format_llm_model_name, 'anthropic.claude-3-haiku-20240307-v1:0')
  end

  test 'format_llm_model_name formats claude 3 opus' do
    assert_equal 'Claude 3 Opus', send(:format_llm_model_name, 'anthropic.claude-3-opus-20240229-v1:0')
  end

  test 'format_llm_model_name removes us. prefix' do
    assert_equal 'Claude 3 Haiku', send(:format_llm_model_name, 'us.anthropic.claude-3-haiku-20240307-v1:0')
  end

  test 'format_llm_model_name uses fallback for unknown models' do
    assert_equal 'Model V1', send(:format_llm_model_name, 'unknown.model-v1')
  end

  test 'format_embedding_model_name formats titan embed' do
    assert_equal 'Amazon Titan Embed', send(:format_embedding_model_name, 'amazon.titan-embed-text-v1')
  end

  test 'format_embedding_model_name formats cohere embed' do
    assert_equal 'Cohere Embed', send(:format_embedding_model_name, 'cohere.embed-english-v3')
  end

  test 'format_embedding_model_name formats text embedding' do
    assert_equal 'Text Embedding', send(:format_embedding_model_name, 'amazon.text-embedding-v1')
  end

  test 'format_embedding_model_name uses fallback for unknown models' do
    assert_equal 'Embedding Model V2', send(:format_embedding_model_name, 'unknown.embedding-model-v2')
  end
end
