# app/services/bedrock_client.rb

require "aws-sdk-bedrockruntime"
require "aws-sdk-core/token_provider"
require "aws-sdk-core/static_token_provider"
require "json"

class BedrockClient
  include AwsClientInitializer

  DEFAULT_MODEL_ID = ENV.fetch("BEDROCK_MODEL_ID", BedrockProfiles::CLAUDE_35_HAIKU)

  def initialize(region: nil)
    client_options = build_aws_client_options(region: region)
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7)
    body = {
      "anthropic_version": "bedrock-2023-05-31",
      "max_tokens": max_tokens,
      "temperature": temperature,
      "messages": [{ "role": "user", "content": prompt }]
    }

    response = @client.invoke_model(
      model_id: model_id,
      content_type: "application/json",
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    result.dig("content", 0, "text") || result.to_s
  rescue => e
    Rails.logger.error("Bedrock error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  # Compatibility method for AiProvider
  def query(prompt, **options)
    generate_text(prompt, **options)
  end
end

