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

    begin
      rag_service = BedrockRagService.new

      # Query using retrieve + explicit LLM call for detailed citations
      result = rag_service.query(question)

      render json: {
        answer: result[:answer],
        citations: result[:citations],
        session_id: result[:session_id],
        status: 'success'
      }
    rescue StandardError => e
      Rails.logger.error("RAG query error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))

      render json: {
        message: "Error processing question: #{e.message}",
        status: 'error'
      }, status: :unprocessable_entity
    end
  end
end
