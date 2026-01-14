# app/services/bedrock_rag_service.rb

require "aws-sdk-bedrockagentruntime"
require "aws-sdk-core/static_token_provider"
require "json"

class BedrockRagService
  include AwsClientInitializer

  def initialize
    client_options = build_aws_client_options
    region = client_options[:region]
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @knowledge_base_id = Rails.application.credentials.dig(:bedrock, :knowledge_base_id) ||
                         ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    
    # Use Claude 3 Haiku by default for cost optimization (12x cheaper than Sonnet)
    # Alternative: Can use Claude 3 Sonnet, Opus, or other models that support foundation-model ARN
    # Set BEDROCK_MODEL_ID env var or configure in Rails credentials to override
    default_model_id = ENV.fetch("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
    model_id = Rails.application.credentials.dig(:bedrock, :model_id) || default_model_id
    
    # Remove 'us.' prefix if present (not needed for foundation-model ARN)
    model_id = model_id.gsub(/^us\./, '') if model_id.start_with?('us.')
    
    # Build foundation-model ARN for Knowledge Base
    # Format: arn:aws:bedrock:{region}::foundation-model/{model_id}
    # Example: arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0
    @model_arn = "arn:aws:bedrock:#{region}::foundation-model/#{model_id}"
    
    # Debug logging
    Rails.logger.info("BedrockRagService initialized - Knowledge Base ID: #{@knowledge_base_id.present? ? @knowledge_base_id : 'NOT SET'}")
    Rails.logger.info("BedrockRagService initialized - Model ARN: #{@model_arn}")
  end

  # Query the Knowledge Base using RAG
  def query(question, model_arn: nil, max_tokens: 2000, temperature: 0.7)
    unless @knowledge_base_id
      error_msg = "Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials."
      Rails.logger.error(error_msg)
      raise error_msg
    end

    # Use provided ARN or default from initialization
    model_arn ||= @model_arn

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current
    response = @client.retrieve_and_generate({
      input: {
        text: question
      },
      retrieve_and_generate_configuration: {
        type: "KNOWLEDGE_BASE",
        knowledge_base_configuration: {
          knowledge_base_id: @knowledge_base_id,
          model_arn: model_arn  # Use foundation-model ARN (e.g., Claude 3 Sonnet)
        }
      }
    })
    latency_ms = ((Time.current - start_time) * 1000).to_i

    Rails.logger.info("Knowledge Base response received successfully")
    
    # Extract model ID from ARN (e.g., "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0" -> "anthropic.claude-3-haiku-20240307-v1:0")
    model_id = model_arn.split("/").last
    
    # Extract tokens from response - prioritize actual usage data from response
    input_tokens = nil
    output_tokens = nil
    
    # Try to get actual token usage from response if available
    if response.respond_to?(:usage) && response.usage
      input_tokens = response.usage.input_tokens if response.usage.respond_to?(:input_tokens) && response.usage.input_tokens
      output_tokens = response.usage.output_tokens if response.usage.respond_to?(:output_tokens) && response.usage.output_tokens
    end
    
    # Fallback to estimation if usage data not available
    input_tokens ||= estimate_tokens(question)
    output_text = response.output&.text || ""
    output_tokens ||= estimate_tokens(output_text)
    
    # Save query to database for metrics tracking
    begin
      BedrockQuery.create!(
        model_id: model_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        user_query: question,
        latency_ms: latency_ms,
        created_at: Time.current
      )
      Rails.logger.info("✓ Bedrock query tracked: #{input_tokens} input + #{output_tokens} output tokens")
    rescue => e
      Rails.logger.error("Failed to track Bedrock query: #{e.message}")
      # Don't fail the request if tracking fails
    end
    
    # Log citations for debugging - first inspect the structure
    if response.citations && response.citations.any?
      Rails.logger.info("Found #{response.citations.length} citation(s):")
      
      # Inspect first citation structure for debugging
      first_citation = response.citations.first
      Rails.logger.debug("First citation structure: #{first_citation.inspect}")
      
      response.citations.each_with_index do |citation, index|
        if citation.retrieved_references && citation.retrieved_references.any?
          citation.retrieved_references.each_with_index do |ref, ref_index|
            # Inspect location structure
            location = ref.location
            Rails.logger.debug("  Citation #{index + 1}, Reference #{ref_index + 1} location: #{location.inspect}")
            
            # Try different ways to access the URI/S3 location
            file_uri = nil
            file_name = 'Unnamed document'
            
            if location.respond_to?(:s3_location)
              s3_loc = location.s3_location
              if s3_loc
                file_uri = s3_loc.uri if s3_loc.respond_to?(:uri)
                file_name = file_uri&.split('/')&.last || s3_loc.to_s
              end
            elsif location.respond_to?(:uri)
              file_uri = location.uri
              file_name = file_uri.split('/').last
            elsif location.is_a?(Hash)
              file_uri = location[:uri] || location['uri'] || location[:s3_location]&.dig(:uri) || location['s3_location']&.dig('uri')
              file_name = file_uri&.split('/')&.last || 'Document'
            else
              # Fallback: use location as string representation
              file_name = location.to_s
            end
            
            Rails.logger.info("  Citation #{index + 1}, Reference #{ref_index + 1}: #{file_name} (URI: #{file_uri || 'N/A'})")
          end
        end
      end
    else
      Rails.logger.warn("No citations found in response")
    end

    # Format citations for easier display
    formatted_citations = []
    if response.citations && response.citations.any?
      response.citations.each do |citation|
        if citation.retrieved_references && citation.retrieved_references.any?
          citation.retrieved_references.each do |ref|
            location = ref.location
            file_uri = nil
            file_name = 'Unnamed document'
            
            # Access URI based on actual structure
            if location.respond_to?(:s3_location)
              s3_loc = location.s3_location
              if s3_loc && s3_loc.respond_to?(:uri)
                file_uri = s3_loc.uri
                file_name = file_uri.split('/').last
              end
            elsif location.respond_to?(:uri)
              file_uri = location.uri
              file_name = file_uri.split('/').last
            elsif location.is_a?(Hash)
              file_uri = location[:uri] || location['uri'] || location[:s3_location]&.dig(:uri) || location['s3_location']&.dig('uri')
              file_name = file_uri&.split('/')&.last || 'Document'
            else
              file_name = location.to_s
            end
            
            # Safely extract content text, handling potential errors
            content_text = begin
              ref.content&.text&.truncate(200) if ref.content&.text
            rescue
              nil
            end
            
            formatted_citations << {
              file_name: file_name,
              uri: file_uri,
              content: content_text # First 200 characters of content
            }
          end
        end
      end
    end

    {
      answer: response.output.text,
      citations: formatted_citations,
      session_id: response.session_id
    }
  rescue => e
    Rails.logger.error("Bedrock RAG error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise "Failed to query Knowledge Base: #{e.message}"
  end

  private

  def estimate_tokens(text)
    return 0 if text.nil? || text.empty?
    # Rough estimation: ~4 characters per token for English text
    # This is a simple heuristic, actual tokenization varies by model
    (text.length / 4.0).ceil
  end

end

