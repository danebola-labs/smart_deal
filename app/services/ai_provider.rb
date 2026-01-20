# frozen_string_literal: true

# app/services/ai_provider.rb

class AiProvider
  def initialize(provider: nil)
    # Only Bedrock is supported. Other providers were removed as they were never used.
    @provider = (provider || ENV.fetch('AI_PROVIDER', 'bedrock')).downcase

    return if @provider == 'bedrock'

    raise "Unknown AI provider: #{@provider}. Only 'bedrock' is supported."
  end

  def query(prompt, **)
    BedrockClient.new.query(prompt, **)
  rescue StandardError => e
    Rails.logger.error("AiProvider error with #{@provider}: #{e.message}")
    raise e
  end
end
