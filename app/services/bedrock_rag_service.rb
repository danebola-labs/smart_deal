# app/services/bedrock_rag_service.rb

require "aws-sdk-bedrockagentruntime"
require "aws-sdk-bedrockruntime"
require "aws-sdk-core/static_token_provider"
require "json"

class BedrockRagService
  include AwsClientInitializer

  MAX_CONTEXT_CHARS = 50_000

  def initialize
    client_options = build_aws_client_options
    region = client_options[:region]
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @runtime_client = Aws::BedrockRuntime::Client.new(client_options)
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
    
    # Step 1: Retrieve documents with metadata
    retrieval_response = @client.retrieve({
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: { text: question },
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: 5,
          override_search_type: "HYBRID"
        }
      }
    })
    
    Rails.logger.info("Retrieval completed: #{retrieval_response.retrieval_results.length} results")
    
    # Step 2: Process retrieval results to extract chunk, similarity_score, file_name, rank
    sources_with_scores = retrieval_response.retrieval_results.filter_map do |result|
      next unless result.location&.s3_location&.uri
      
      s3_uri = result.location.s3_location.uri
      file_name = File.basename(s3_uri)
      
      # Extract chunk text for citations (no truncation - handled in UI with CSS)
      chunk_text = result.content&.text
      
      {
        file_name: file_name,
        chunk: chunk_text,
        similarity_score: result.score.to_f
      }
    end.sort_by { |source| -source[:similarity_score] }.map.with_index do |source, index|
      source[:rank] = index + 1
      source
    end
    
    # Step 3: Build context from chunks (only non-nil chunks)
    # Use full chunks for LLM context (truncation happens in UI with CSS)
    full_chunks = retrieval_response.retrieval_results.filter_map do |result|
      result.content&.text
    end
    context = full_chunks.join("\n\n")
    context = context[0, MAX_CONTEXT_CHARS] if context.length > MAX_CONTEXT_CHARS
    
    # Step 4: Generate response using LLM
    model_id = model_arn.split("/").last
    prompt = build_rag_prompt(question, context)
    
    llm_response = @runtime_client.invoke_model({
      model_id: model_id,
      content_type: "application/json",
      body: {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [{ "role": "user", "content": prompt }]
      }.to_json
    })
    
    llm_result = JSON.parse(llm_response.body.read)
    output_text = llm_result.dig("content", 0, "text") || llm_result.to_s
    
    latency_ms = ((Time.current - start_time) * 1000).to_i
    
    Rails.logger.info("LLM response generated successfully")
    
    # Extract tokens - estimate from input and output
    input_tokens = estimate_tokens(question + context)
    output_tokens = estimate_tokens(output_text)
    
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
      
      # Update metrics automatically after each query
      begin
        SimpleMetricsService.new.update_database_metrics_only
        Rails.logger.info("✓ Metrics updated after query")
      rescue StandardError => e
        Rails.logger.error("Failed to update metrics after query: #{e.message}")
        # Don't fail the request if metrics update fails
      end
    rescue StandardError => e
      Rails.logger.error("Failed to track Bedrock query: #{e.message}")
      # Don't fail the request if tracking fails
    end
    
    # Log citations for debugging
    Rails.logger.info("Found #{sources_with_scores.length} citation(s):")
    sources_with_scores.each do |source|
      Rails.logger.info("  Citation #{source[:rank]}: #{source[:file_name]} (score: #{source[:similarity_score]})")
    end

    # Format citations with new structure
    formatted_citations = sources_with_scores.map do |source|
      {
        file_name: source[:file_name],
        chunk: source[:chunk],
        similarity_score: source[:similarity_score],
        rank: source[:rank]
      }
    end

    {
      answer: output_text,
      citations: formatted_citations,
      session_id: nil  # retrieve API doesn't return session_id
    }
  rescue StandardError => e
    Rails.logger.error("Bedrock RAG error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise "Failed to query Knowledge Base: #{e.message}"
  end

  private

  def build_rag_prompt(question, context)
    <<~PROMPT
      Contexto de documentos relevantes:
      #{context}
      
      Pregunta del usuario: #{question}
      
      Instrucciones:
      - Responde basándote únicamente en el contexto proporcionado
      - Si no encuentras información relevante, indica que no tienes suficiente información
      - Sé preciso y conciso
      
      Respuesta:
    PROMPT
  end

  def estimate_tokens(text)
    return 0 if text.nil? || text.empty?
    # Rough estimation: ~4 characters per token for English text
    # This is a simple heuristic, actual tokenization varies by model
    (text.length / 4.0).ceil
  end

end

