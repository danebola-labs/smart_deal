# app/services/bedrock_client.rb

require "aws-sdk-bedrockruntime"
require "json"

class BedrockClient
  def initialize(region: nil)
    region ||= ENV.fetch("AWS_REGION", "us-east-1")
    
    # Get credentials from Rails credentials or environment variables
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    
    # If no credentials, AWS SDK will try to use the default profile
    client_options = { region: region }
    if access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end
    
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: "anthropic.claude-3-5-haiku-20241022-v1:0", max_tokens: 2000, temperature: 0.7)
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

