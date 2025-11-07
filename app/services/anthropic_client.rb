# app/services/anthropic_client.rb

# Placeholder – will be completed when migrating away from Bedrock
class AnthropicClient
  def generate_text(prompt, model: "claude-3-haiku-20240307", max_tokens: 2000)
    raise NotImplementedError, "Anthropic direct integration not yet implemented. Use 'bedrock' provider instead."
  end

  # Compatibility method for AiProvider
  def query(prompt, **options)
    generate_text(prompt, **options)
  end
end

