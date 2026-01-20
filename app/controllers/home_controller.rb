# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @s3_documents_list = S3DocumentsService.new.list_documents
    @current_llm_model = current_llm_model
    @current_embedding_model = current_embedding_model
  end

  def metrics
    render json: {
      today_tokens: current_metrics[:today_tokens],
      today_queries: current_metrics[:today_queries],
      today_cost: current_metrics[:today_cost],
      updated_at: Time.current.iso8601
    }
  end

  private

  def current_llm_model
    # Get model from last query or default configuration
    last_query = BedrockQuery.order(created_at: :desc).first
    if last_query&.model_id
      format_model_name(last_query.model_id)
    else
      # Get from configuration
      model_id = Rails.application.credentials.dig(:bedrock, :model_id) ||
                 ENV['BEDROCK_MODEL_ID'] ||
                 'anthropic.claude-3-haiku-20240307-v1:0'
      format_model_name(model_id)
    end
  end

  def current_embedding_model
    # Get embedding model from configuration or use default
    embedding_model_id = Rails.application.credentials.dig(:bedrock, :embedding_model_id) ||
                         ENV['BEDROCK_EMBEDDING_MODEL_ID'] ||
                         'amazon.titan-embed-text-v1'
    format_embedding_model_name(embedding_model_id)
  end

  def format_model_name(model_id)
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
