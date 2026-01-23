# frozen_string_literal: true

# app/services/bedrock_rag_service.rb

require 'aws-sdk-bedrockagentruntime'
require 'aws-sdk-core/static_token_provider'
require 'json'
require_relative 's3_documents_service'

class BedrockRagService
  include AwsClientInitializer

  # Build complete optimized configuration for retrieve_and_generate API
  # This method constructs the config dynamically to include prompt templates
  def build_complete_optimized_config(region: 'us-east-1')
    {
      # ===== RETRIEVAL CONFIGURATION =====
      retrieval_configuration: {
        vector_search_configuration: {
          # Source chunks optimized
          number_of_results: 20,              # Was 5 by default
          
          # Search type optimized
          override_search_type: "HYBRID",     # HYBRID vs SEMANTIC
          
          # Reranking configuration
          # Note: The reranking will use the number_of_results from vector_search_configuration above
          reranking_configuration: {
            type: "BEDROCK_RERANKING_MODEL",
            bedrock_reranking_configuration: {
              model_configuration: {
                model_arn: "arn:aws:bedrock:#{region}::foundation-model/cohere.rerank-v3-5:0"
              }
            }
          }
          
          # Metadata filtering (optional) - removed empty filter as API requires at least one filter type
          # To add filtering, uncomment and configure:
          # filter: {
          #   and_all: [
          #     {
          #       equals: {
          #         key: "document_type",
          #         value: "manual"
          #       }
          #     }
          #   ]
          # }
        }
      },
      
      # ===== GENERATION CONFIGURATION =====
      generation_configuration: {
        # Optimized inference parameters
        inference_config: {
          text_inference_config: {
            temperature: 0.3,                 # Creativity control
            top_p: 0.9,                      # Token diversity
            max_tokens: 3000,                # Maximum output tokens (was 2048)
            stop_sequences: []               # Stop sequences (empty, without "observation")
          }
        },
        
        # Custom prompt template for generation
        prompt_template: {
          text_prompt_template: self.class.build_generation_prompt_template
        },
        
        # Additional model request fields (model-specific parameters)
        additional_model_request_fields: {
          # Specific parameters for Claude
          # "top_k" => 250,
          # "anthropic_version" => "bedrock-2023-05-31"
        },
        
        # Guardrails (optional)
        # guardrail_configuration: {
        #   guardrail_identifier: "your-guardrail-id",
        #   guardrail_version: "DRAFT"
        # },
        
        # Performance configuration
        performance_config: {
          latency: "standard"  # "standard" | "optimized"
        }
      },
      
      # ===== ORCHESTRATION CONFIGURATION =====
      orchestration_configuration: {
        # Query transformation (Query decomposition - Break down queries)
        query_transformation_configuration: {
          type: "QUERY_DECOMPOSITION"        # ENABLE break down queries
        },
        
        # Inference config for orchestration
        inference_config: {
          text_inference_config: {
            temperature: 0.1,                # More deterministic for query processing
            top_p: 0.8,
            max_tokens: 2048
          }
        },
        
        # Custom prompt template for orchestration
        prompt_template: {
          text_prompt_template: self.class.build_orchestration_prompt_template
        },
        
        # Additional model request fields for orchestration
        additional_model_request_fields: {},
        
        # Performance config for orchestration
        performance_config: {
          latency: "optimized"  # Faster for query processing
        }
      }
    }
  end

  def initialize
    client_options = build_aws_client_options
    region = client_options[:region]
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @knowledge_base_id = Rails.application.credentials.dig(:bedrock, :knowledge_base_id) ||
                         ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil)

    # Use Claude 3 Haiku by default for cost optimization (12x cheaper than Sonnet)
    # Alternative: Can use Claude 3 Sonnet, Opus, or other models that support foundation-model ARN
    # Set BEDROCK_MODEL_ID env var or configure in Rails credentials to override
    default_model_id = ENV.fetch('BEDROCK_MODEL_ID', 'anthropic.claude-3-haiku-20240307-v1:0')
    model_id = Rails.application.credentials.dig(:bedrock, :model_id) || default_model_id

    # Remove 'us.' prefix if present (not needed for foundation-model ARN)
    model_id = model_id.gsub(/^us\./, '') if model_id.start_with?('us.')

    # Build foundation-model ARN for Knowledge Base
    # Format: arn:aws:bedrock:{region}::foundation-model/{model_id}
    # Example: arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0
    @model_arn = "arn:aws:bedrock:#{region}::foundation-model/#{model_id}"

    # Debug logging
    Rails.logger.info("BedrockRagService initialized - Knowledge Base ID: #{@knowledge_base_id.presence || 'NOT SET'}")
    Rails.logger.info("BedrockRagService initialized - Model ARN: #{@model_arn}")
  end

  # Query the Knowledge Base using RAG with retrieve_and_generate API
  def query(question, session_id: nil, custom_config: {})
    unless @knowledge_base_id
      error_msg = 'Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials.'
      Rails.logger.error(error_msg)
      raise error_msg
    end

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current

    begin
      # Get region from client options
      client_options = build_aws_client_options
      region = client_options[:region] || 'us-east-1'
      
      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: region)
      config = deep_merge_configs(base_config, custom_config)
      
      # Use retrieve_and_generate API - combines retrieval and generation in one call
      # Apply all optimized configuration (retrieval, generation, orchestration)
      response = @client.retrieve_and_generate({
        input: {
          text: question
        },
        retrieve_and_generate_configuration: {
          type: 'KNOWLEDGE_BASE',
          knowledge_base_configuration: {
            knowledge_base_id: @knowledge_base_id,
            model_arn: @model_arn,
            **config  # All optimized configuration
          }
        },
        session_id: session_id
      })

      # Process response
      answer_text = response.output.text
      citations = extract_citations(response.citations)
      session_id = response.session_id

      # Get S3 documents list to map citations to document numbers in Data Source
      s3_documents = S3DocumentsService.new.list_documents
      
      # Build mapping from Bedrock citation numbers to Data Source numbers
      citation_to_datasource_map = build_citation_mapping(citations, s3_documents)
      
      # Replace Bedrock citation numbers [1], [2] with Data Source numbers in answer text
      answer_text = replace_citation_numbers(answer_text, citation_to_datasource_map)
      
      # If answer doesn't contain citations but we have citations from Bedrock,
      # add them automatically at the end of sentences/phrases
      if citations.any? && !answer_text.match(/\[\d+\]/)
        answer_text = add_citations_to_answer(answer_text, citations, citation_to_datasource_map)
        Rails.logger.info("Added citations automatically to answer text")
      end

      latency_ms = ((Time.current - start_time) * 1000).to_i
      model_id = @model_arn.split('/').last

      # Extract tokens - estimate from input and output
      input_tokens = estimate_tokens(question)
      output_tokens = estimate_tokens(answer_text)

      # Save query to database for metrics tracking
      # Metrics tracking failure should not fail the request
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
        SimpleMetricsService.update_database_metrics_only
        Rails.logger.info("✓ Metrics updated after query")
      rescue StandardError => e
        Rails.logger.error("Failed to track query or update metrics: #{e.message}")
      end

      # Extract numbered citations from answer text and map to documents
      numbered_references = build_numbered_references(citations, answer_text, s3_documents)

      Rails.logger.info("Found #{citations.length} citation(s)")
      numbered_references.each do |ref|
        Rails.logger.info("  Citation #{ref[:number]}: #{ref[:title]} (#{ref[:filename]}) -> Data Source doc #{ref[:data_source_number]}")
      end

      {
        answer: answer_text,
        citations: numbered_references,
        session_id: session_id
      }
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      Rails.logger.error("Bedrock RAG error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise "Failed to query Knowledge Base: #{e.message}"
    end
  end

  private

  # ===== CUSTOM PROMPT TEMPLATES =====
  
  def self.build_generation_prompt_template
    """
    You are an expert assistant in artificial intelligence and AI agents. Your task is to provide accurate, complete, and well-structured answers based on the provided context.

    SPECIFIC INSTRUCTIONS:
    1. Carefully analyze all the context provided in $search_results$
    2. LANGUAGE REQUIREMENT - CRITICAL: You MUST respond in the EXACT SAME LANGUAGE as the user's question ($query$). If the question is in Spanish, you MUST respond entirely in Spanish. If the question is in English, you MUST respond entirely in English. Never mix languages. Always match the user's language exactly.
    3. Respond in a clear, organized, and professional manner
    4. Use bullets, numbering, or structure when appropriate
    5. Include specific examples from the context when relevant
    6. If information is not complete in the context, indicate it clearly
    7. Maintain a professional but accessible tone
    8. Prioritize accuracy over brevity
    9. Include relevant technical details when appropriate
    10. CRITICAL: You MUST include numbered citations in square brackets [1], [2], [3], etc. whenever you use information from the search results. Place citations immediately after the relevant information. You can use multiple citations like [1][2] if information comes from multiple sources. Number citations sequentially based on the order of sources in the search results (first source is [1], second is [2], etc.).

    SEARCH CONTEXT:
    $search_results$

    USER QUESTION:
    $query$

    IMPORTANT: Respond in the same language as the question above. If the question is in Spanish, write your entire answer in Spanish. If the question is in English, write your entire answer in English.

    DETAILED AND STRUCTURED ANSWER (remember to include numbered citations [1], [2], etc.):
    """
  end

  def self.build_orchestration_prompt_template
    """
    Your task is to analyze the user's query and optimize it for effective search in the knowledge base about artificial intelligence and AI agents.

    QUERY PROCESSING INSTRUCTIONS:
    1. Identify key concepts in the query
    2. Break down complex queries into more specific sub-queries
    3. Identify synonyms and relevant related terms
    4. Consider the context of AI and intelligent agents
    5. Optimize for both semantic and keyword search

    ORIGINAL QUERY: $query$

    CONVERSATION HISTORY: $conversation_history$

    FORMAT INSTRUCTIONS: $output_format_instructions$

    OPTIMIZED QUERY FOR SEARCH:
    """
  end

  # Extract citations from Bedrock response
  def extract_citations(citations)
    return [] unless citations

    citations.flat_map do |citation|
      citation.retrieved_references.map do |ref|
        location = extract_location_info(ref.location)
        {
          content: ref.content&.text,
          location: location,
          metadata: ref.metadata || {}
        }
      end
    end
  end

  # Extract location information from citation
  def extract_location_info(location)
    return nil unless location&.s3_location&.uri

    uri = location.s3_location.uri
    uri_parts = uri.split('/')
    {
      bucket: uri_parts[2],
      key: uri_parts[3..-1].join('/'),
      uri: uri,
      type: 's3'
    }
  end

  # Build mapping from Bedrock citation numbers to Data Source numbers
  def build_citation_mapping(citations, s3_documents)
    return {} if citations.empty? || s3_documents.empty?

    # Build a map of S3 documents by filename for quick lookup
    s3_doc_map = {}
    s3_documents.each_with_index do |doc, index|
      doc_name = doc[:name] || doc['name']
      s3_doc_map[doc_name] = index + 1 if doc_name
    end

    # Map Bedrock citation index to Data Source number
    mapping = {}
    citations.each_with_index do |citation, index|
      bedrock_num = index + 1
      location = citation[:location]
      metadata = citation[:metadata] || {}

      # Extract filename from S3 URI
      filename = if location && location[:key]
                   File.basename(location[:key])
                 elsif location && location[:uri]
                   File.basename(location[:uri])
                 else
                   nil
                 end

      # Use title from metadata if available, otherwise use filename
      title = metadata['title'] || metadata[:title] || filename

      # Find matching document in Data Source by filename or title
      data_source_num = s3_doc_map[filename] || s3_doc_map[title] || bedrock_num
      mapping[bedrock_num] = data_source_num
    end

    mapping
  end

  # Replace Bedrock citation numbers with Data Source numbers in answer text
  def replace_citation_numbers(answer_text, citation_map)
    return answer_text if citation_map.empty?

    # Replace all citation numbers [1], [2], [1][3] with Data Source numbers
    answer_text.gsub(/\[(\d+)\]/) do |match|
      bedrock_num = $1.to_i
      data_source_num = citation_map[bedrock_num] || bedrock_num
      "[#{data_source_num}]"
    end
  end

  # Add citations to answer text if they're missing
  # This adds [1], [2], etc. at the end of sentences when citations are available
  def add_citations_to_answer(answer_text, citations, citation_map = {})
    return answer_text if citations.empty?

    # Split answer into sentences
    sentences = answer_text.split(/([.!?]\s+)/)
    result = []
    citation_index = 0

    sentences.each_with_index do |sentence, index|
      result << sentence
      
      # Add citation after every 2-3 sentences, or at the end
      if citation_index < citations.length && (index % 3 == 2 || index == sentences.length - 1)
        bedrock_num = citation_index + 1
        # Use Data Source number if mapping exists, otherwise use Bedrock number
        citation_num = citation_map[bedrock_num] || bedrock_num
        result << "[#{citation_num}]"
        citation_index += 1
      end
    end

    result.join
  end

  # Build numbered references by extracting citation numbers from answer text
  # and mapping them to documents from Data Source
  # Note: citation numbers in answer_text are now Data Source numbers (already replaced)
  def build_numbered_references(citations, answer_text, s3_documents = [])
    # Extract all citation numbers from answer text (e.g., [1], [2], [1][3])
    # These are now Data Source numbers, not Bedrock numbers
    citation_numbers = answer_text.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq.sort

    # Build a map of S3 documents by filename for quick lookup
    s3_doc_map = {}
    s3_documents.each_with_index do |doc, index|
      doc_name = doc[:name] || doc['name']
      s3_doc_map[doc_name] = index + 1 if doc_name
    end

    # Build reverse map: Data Source number -> citation data
    # We need to find which Bedrock citation corresponds to each Data Source number
    references = {}
    
    citations.each_with_index do |citation, index|
      location = citation[:location]
      metadata = citation[:metadata] || {}

      # Extract filename from S3 URI
      filename = if location && location[:key]
                   File.basename(location[:key])
                 elsif location && location[:uri]
                   File.basename(location[:uri])
                 else
                   'Document'
                 end

      # Use title from metadata if available, otherwise use filename
      title = metadata['title'] || metadata[:title] || filename

      # Find matching document in Data Source by filename
      data_source_number = s3_doc_map[filename] || s3_doc_map[title]
      
      if data_source_number
        references[data_source_number] = {
          number: data_source_number, # Data Source number (used in answer text)
          title: title,
          filename: filename,
          content: citation[:content],
          location: location,
          metadata: metadata
        }
      end
    end

    # Return references in order of appearance in answer text (by Data Source number)
    citation_numbers.filter_map { |num| references[num] }.uniq
  end

  def estimate_tokens(text)
    return 0 if text.blank?

    # Rough estimation: ~4 characters per token for English text
    # This is a simple heuristic, actual tokenization varies by model
    (text.length / 4.0).ceil
  end

  # Deep merge configurations (supports nested hashes)
  def deep_merge_configs(base_config, custom_config)
    return base_config if custom_config.empty?
    
    base_config.merge(custom_config) do |key, old_val, new_val|
      if old_val.is_a?(Hash) && new_val.is_a?(Hash)
        deep_merge_configs(old_val, new_val)
      else
        new_val
      end
    end
  end
end
