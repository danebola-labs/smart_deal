class HomeController < ApplicationController
  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @s3_documents_list = s3_documents_list
  end

  private

  def current_metrics
    today = Date.current
    s3_size_bytes = CostMetric.find_by(date: today, metric_type: :s3_total_size)&.value || 0

    {
      today_tokens: CostMetric.find_by(date: today, metric_type: :daily_tokens)&.value || 0,
      today_cost: CostMetric.find_by(date: today, metric_type: :daily_cost)&.value || 0,
      today_queries: CostMetric.find_by(date: today, metric_type: :daily_queries)&.value || 0,
      aurora_acu: CostMetric.find_by(date: today, metric_type: :aurora_acu_avg)&.value || 0,
      s3_documents: CostMetric.find_by(date: today, metric_type: :s3_documents_count)&.value || 0,
      s3_size_mb: (s3_size_bytes / 1.megabyte.to_f).round(2),
      s3_size_gb: (s3_size_bytes / 1.gigabyte.to_f).round(2)
    }
  end

  def monthly_totals
    {
      total_tokens: CostMetric.total_for_month(:daily_tokens),
      total_cost: CostMetric.total_for_month(:daily_cost),
      total_queries: CostMetric.total_for_month(:daily_queries),
      avg_acu: CostMetric.avg_for_month(:aurora_acu_avg).round(2)
    }
  end

  def s3_documents_list
    begin
      require "aws-sdk-s3"
      require "aws-sdk-core/static_token_provider"
      
      # Use same AWS configuration pattern as SimpleMetricsService
      region = Rails.application.credentials.dig(:aws, :region) || 
               ENV.fetch("AWS_REGION", "us-east-1")
      
      access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
      secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
      bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                     Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                     ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                     ENV["AWS_BEDROCK_BEARER_TOKEN"]
      
      client_options = { region: region }
      if bearer_token.present?
        client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
      elsif access_key_id.present? && secret_access_key.present?
        client_options[:access_key_id] = access_key_id
        client_options[:secret_access_key] = secret_access_key
      end
      
      s3 = Aws::S3::Client.new(client_options)
      
      # Get bucket name (same logic as SimpleMetricsService)
      bucket_name = ENV['KNOWLEDGE_BASE_S3_BUCKET'] ||
                    Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
                    Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
                    'document-chatbot-generic-tech-info'
      
      return [] unless bucket_name

      all_objects = []
      s3.list_objects_v2(bucket: bucket_name).each do |response|
        all_objects.concat(response.contents || [])
      end

      # Filter only real documents (exclude metadata, hidden files, directories)
      real_documents = all_objects.select do |obj|
        !obj.key.start_with?('.') && 
        !obj.key.include?('$folder$') &&
        !obj.key.end_with?('/') &&
        obj.size > 1024 # At least 1KB
      end

      # Return array of document info
      real_documents.map do |obj|
        {
          name: obj.key.split('/').last, # Just filename
          full_path: obj.key,
          size_mb: (obj.size / 1.megabyte.to_f).round(2),
          size_bytes: obj.size,
          modified: obj.last_modified
        }
      end.sort_by { |doc| -doc[:size_bytes] } # Sort by size, largest first
    rescue => e
      Rails.logger.error("Error fetching S3 documents list: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      []
    end
  end
end

