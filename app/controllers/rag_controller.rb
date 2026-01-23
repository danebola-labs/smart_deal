# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern

  def ask
    question = params[:question]&.strip

    if question.blank?
      render json: {
        message: 'Question cannot be empty',
        status: 'error'
      }, status: :bad_request
      return
    end

    rag_service = BedrockRagService.new
    result = rag_service.query(question)

    render json: {
      answer: result[:answer],
      citations: result[:citations],
      session_id: result[:session_id],
      status: 'success'
    }

  rescue BedrockRagService::MissingKnowledgeBaseError => e
    Rails.logger.error("RAG config error: #{e.message}")

    render json: {
      message: 'RAG service is not properly configured',
      status: 'error'
    }, status: :internal_server_error

  rescue BedrockRagService::BedrockServiceError => e
    Rails.logger.error("RAG AWS error: #{e.message}")

    render json: {
      message: 'Error querying knowledge base',
      status: 'error'
    }, status: :bad_gateway

  rescue StandardError => e
    Rails.logger.fatal("Unexpected RAG error: #{e.message}")
    Rails.logger.fatal(e.backtrace.join("\n"))

    render json: {
      message: 'Unexpected error processing request',
      status: 'error'
    }, status: :internal_server_error
  end
end
