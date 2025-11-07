# app/controllers/ai_controller.rb

class AiController < ApplicationController
  before_action :authenticate_user!

  def ask
    prompt = params[:prompt]
    
    if prompt.blank?
      render json: { error: "Prompt is required" }, status: :bad_request
      return
    end

    begin
      ai_provider = AiProvider.new
      result = ai_provider.query(
        prompt,
        max_tokens: params[:max_tokens]&.to_i || 2000,
        temperature: params[:temperature]&.to_f || 0.7
      )

      if result.present?
        render json: { result: result }
      else
        render json: { error: "AI service returned empty response" }, status: :service_unavailable
      end
    rescue => e
      Rails.logger.error("AI error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { error: "AI service unavailable: #{e.message}" }, status: :internal_server_error
    end
  end
end

