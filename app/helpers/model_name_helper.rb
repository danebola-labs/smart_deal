# frozen_string_literal: true

module ModelNameHelper
  # Get the current LLM model name for display
  # Reads from last query or configuration
  def current_llm_model_name
    model_id = current_llm_model_id
    format_llm_model_name(model_id)
  end

  # Get the current embedding model name for display
  # Reads from configuration
  def current_embedding_model_name
    model_id = current_embedding_model_id
    format_embedding_model_name(model_id)
  end

  private

  def current_llm_model_id
    last_query = BedrockQuery.order(created_at: :desc).first
    if last_query&.model_id
      last_query.model_id
    else
      Rails.application.credentials.dig(:bedrock, :model_id) ||
        ENV['BEDROCK_MODEL_ID'] ||
        'anthropic.claude-3-haiku-20240307-v1:0'
    end
  end

  def current_embedding_model_id
    Rails.application.credentials.dig(:bedrock, :embedding_model_id) ||
      ENV['BEDROCK_EMBEDDING_MODEL_ID'] ||
      'amazon.titan-embed-text-v1'
  end

  def format_llm_model_name(model_id)
    # Remove 'us.' prefix if present
    model_id = model_id.gsub(/^us\./, '') if model_id.start_with?('us.')

    # Format model name for display
    if model_id.include?('claude-3-5')
      'Claude 3.5 Sonnet'
    elsif model_id.include?('claude-3-sonnet')
      'Claude 3 Sonnet'
    elsif model_id.include?('claude-3-haiku')
      'Claude 3 Haiku'
    elsif model_id.include?('claude-3-opus')
      'Claude 3 Opus'
    else
      # Fallback: extract readable name from model_id
      model_id.split('.').last.split('-').map(&:capitalize).join(' ')
    end
  end

  def format_embedding_model_name(model_id)
    # Format embedding model name for display
    if model_id.include?('titan-embed') || model_id.include?('titan.embed')
      'Amazon Titan Embed'
    elsif model_id.include?('cohere') && (model_id.include?('embed') || model_id.include?('embedding'))
      'Cohere Embed'
    elsif model_id.include?('text-embedding')
      'Text Embedding'
    else
      # Fallback: extract readable name from model_id
      model_id.split('.').last.split('-').map(&:capitalize).join(' ')
    end
  end
end
