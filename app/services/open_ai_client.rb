# app/services/open_ai_client.rb

class OpenAiClient
  def initialize
    @api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]
    raise ArgumentError, "OpenAI API key not configured" unless @api_key.present?

    @client = OpenAI::Client.new(access_token: @api_key)
  end

  def query(prompt, model: "gpt-4o-mini", max_tokens: 2000, temperature: 0.7, **options)
    response = @client.chat(
      parameters: {
        model: model,
        messages: [
          { role: "user", content: prompt }
        ],
        temperature: temperature,
        max_tokens: max_tokens
      }
    )

    response.dig("choices", 0, "message", "content")
  rescue => e
    Rails.logger.error("OpenAI error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end
end

