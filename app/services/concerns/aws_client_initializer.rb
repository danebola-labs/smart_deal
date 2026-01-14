# app/services/concerns/aws_client_initializer.rb
module AwsClientInitializer
  extend ActiveSupport::Concern

  private

  # Builds AWS client options with credentials from Rails credentials or ENV
  # Supports both bearer token and access_key/secret_key authentication
  #
  # @param region [String, nil] AWS region (defaults to us-east-1)
  # @return [Hash] Options hash for AWS client initialization
  def build_aws_client_options(region: nil)
    region ||= ENV.fetch("AWS_REGION", "us-east-1")
    
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                   ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                   ENV["AWS_BEDROCK_BEARER_TOKEN"]
    
    ca_bundle_path = ENV["AWS_CA_BUNDLE"].presence || ENV["SSL_CERT_FILE"].presence
    
    client_options = { region: region }
    
    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end
    
    client_options[:ssl_ca_bundle] = ca_bundle_path if ca_bundle_path.present? && File.exist?(ca_bundle_path)
    
    client_options
  end
end

