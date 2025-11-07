# app/services/ai_provider.rb

class AiProvider
  def initialize(provider: nil)
    @provider = provider || ENV.fetch("AI_PROVIDER", "bedrock").downcase
  end

  def query(prompt, **options)
    client = case @provider
             when "bedrock"
               BedrockClient.new
             when "anthropic"
               AnthropicClient.new
             when "geia"
               GeiaClient.new
             when "openai"
               OpenAiClient.new
             else
               raise "Unknown AI provider: #{@provider}. Supported: bedrock, anthropic, geia, openai"
             end

    client.query(prompt, **options)
  rescue => e
    Rails.logger.error("AiProvider error with #{@provider}: #{e.message}")
    raise e
  end
end

