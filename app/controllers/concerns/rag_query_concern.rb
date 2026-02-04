# frozen_string_literal: true

# app/controllers/concerns/rag_query_concern.rb
# Shared logic for RAG queries across controllers (API and Twilio/WhatsApp)

module RagQueryConcern
  extend ActiveSupport::Concern

  # Result object for RAG queries
  RagResult = Struct.new(:success?, :answer, :citations, :session_id, :error_type, :error_message, keyword_init: true)

  private

  # Executes a RAG query and returns a structured result
  # @param question [String] The question to query
  # @return [RagResult] Structured result with success status and data or error info
  def execute_rag_query(question)
    question = question.to_s.strip

    if question.blank?
      return RagResult.new(success?: false, error_type: :blank_question)
    end

    rag_service = BedrockRagService.new
    result = rag_service.query(question)

    RagResult.new(
      success?: true,
      answer: result[:answer],
      citations: result[:citations],
      session_id: result[:session_id]
    )
  rescue BedrockRagService::MissingKnowledgeBaseError => e
    log_rag_error("RAG config error", e)
    RagResult.new(success?: false, error_type: :config_error, error_message: e.message)
  rescue BedrockRagService::BedrockServiceError => e
    log_rag_error("RAG AWS error", e)
    RagResult.new(success?: false, error_type: :service_error, error_message: e.message)
  rescue StandardError => e
    log_rag_error("RAG unexpected error", e, include_backtrace: true)
    RagResult.new(success?: false, error_type: :unexpected_error, error_message: e.message)
  end

  # Formats RAG result for WhatsApp/SMS text responses
  # @param result [RagResult] The result from execute_rag_query
  # @return [String] Human-readable text response
  def format_rag_response_for_whatsapp(result)
    return whatsapp_error_message(result.error_type, result.error_message) unless result.success?

    text = result.answer.to_s
    text += "\n\nSources: #{result.citations.join(', ')}" if result.citations.present?
    text.presence || "I couldn't find an answer."
  end

  # Maps error types to WhatsApp-friendly messages
  def whatsapp_error_message(error_type, error_message = nil)
    case error_type
    when :blank_question
      "Please send a question (message cannot be empty)."
    when :config_error
      "The query service is not properly configured."
    when :service_error
      "Error querying knowledge base. Please try again later."
    when :unexpected_error
      "Sorry, an error occurred: #{error_message}"
    else
      "An unexpected error occurred."
    end
  end

  # Renders JSON error response for API endpoints
  # @param result [RagResult] The failed result from execute_rag_query
  def render_rag_json_error(result)
    error_config = json_error_config(result.error_type)

    render json: {
      message: error_config[:message],
      status: 'error'
    }, status: error_config[:http_status]
  end

  # Maps error types to JSON API error responses
  def json_error_config(error_type)
    case error_type
    when :blank_question
      { message: 'Question cannot be empty', http_status: :bad_request }
    when :config_error
      { message: 'RAG service is not properly configured', http_status: :internal_server_error }
    when :service_error
      { message: 'Error querying knowledge base', http_status: :bad_gateway }
    when :unexpected_error
      { message: 'Unexpected error processing request', http_status: :internal_server_error }
    else
      { message: 'Unknown error', http_status: :internal_server_error }
    end
  end

  # Centralized error logging for RAG operations
  def log_rag_error(prefix, error, include_backtrace: false)
    message = "#{prefix}: #{error.message}"
    message += "\n#{error.backtrace.first(5).join("\n")}" if include_backtrace

    if include_backtrace
      Rails.logger.fatal(message)
    else
      Rails.logger.error(message)
    end
  end
end
