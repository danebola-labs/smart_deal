# app/services/anthropic_client.rb

# Placeholder – se completará al migrar fuera de Bedrock
class AnthropicClient
  def generate_text(prompt, model: "claude-3-haiku-20240307", max_tokens: 2000)
    raise NotImplementedError, "Anthropic direct integration not yet implemented. Use 'bedrock' provider instead."
  end

  # Método de compatibilidad con AiProvider
  def query(prompt, **options)
    generate_text(prompt, **options)
  end
end

