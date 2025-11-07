# app/services/geia_client.rb

# GEIA Client - Integration with Globant internal service
# Base URL: https://api.clients.geai.globant.com
class GeiaClient
  def initialize
    @api_url = ENV.fetch("GEIA_API_URL", "https://api.clients.geai.globant.com")
    @api_key = Rails.application.credentials.dig(:geia, :api_key) || ENV["GEIA_API_KEY"]
  end

  def query(prompt, **options)
    raise NotImplementedError, "GEIA integration not yet implemented. API key required." unless @api_key.present?

    # Placeholder for future implementation
    # Here would go the logic to connect to the GEIA API
    # require "net/http"
    # require "json"
    #
    # uri = URI("#{@api_url}/v1/chat/completions")
    # http = Net::HTTP.new(uri.host, uri.port)
    # http.use_ssl = true
    #
    # request = Net::HTTP::Post.new(uri)
    # request["Content-Type"] = "application/json"
    # request["Authorization"] = "Bearer #{@api_key}"
    # request.body = {
    #   prompt: prompt,
    #   max_tokens: options[:max_tokens] || 2000
    # }.to_json
    #
    # response = http.request(request)
    # JSON.parse(response.body)["result"]

    raise NotImplementedError, "GEIA integration implementation pending"
  end
end

