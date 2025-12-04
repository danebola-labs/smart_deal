require "aws-sdk-cloudwatch"
require "aws-sdk-s3"
require "aws-sdk-core/static_token_provider"

class SimpleMetricsService
    def initialize(date = Date.current)
      @date = date
      
      # Use same AWS configuration pattern as BedrockClient and BedrockRagService
      region = Rails.application.credentials.dig(:aws, :region) || 
               ENV.fetch("AWS_REGION", "us-east-1")
      
      # Get credentials from Rails credentials or environment variables
      access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
      secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
      bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                     Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                     ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                     ENV["AWS_BEDROCK_BEARER_TOKEN"]
      
      # Build client options following the same pattern
      client_options = { region: region }
      if bearer_token.present?
        client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
      elsif access_key_id.present? && secret_access_key.present?
        client_options[:access_key_id] = access_key_id
        client_options[:secret_access_key] = secret_access_key
      end
      
      @cloudwatch = Aws::CloudWatch::Client.new(client_options)
      @s3 = Aws::S3::Client.new(client_options)
      
      # Get configuration from Rails credentials or environment variables (same pattern as BedrockRagService)
      @knowledge_base_bucket = Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
                               Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
                               ENV["KNOWLEDGE_BASE_S3_BUCKET"]
      @aurora_cluster_identifier = Rails.application.credentials.dig(:aws, :aurora_db_cluster_identifier) ||
                                   ENV["AURORA_DB_CLUSTER_IDENTIFIER"]
    end
  
    def save_daily_metrics
      metrics = collect_daily_metrics
  
      metrics.each do |metric_type, value|
        CostMetric.find_or_initialize_by(date: @date, metric_type: metric_type).tap do |m|
          m.value = value
          m.save!
        end
      end
    end
  
    def collect_daily_metrics
      {
        daily_tokens: calculate_daily_tokens,
        daily_cost: calculate_daily_cost,
        daily_queries: calculate_daily_queries,
        aurora_acu_avg: get_aurora_acu_average,
        s3_documents_count: get_s3_document_count,
        s3_total_size: get_s3_total_size
      }
    end
  
    private
  
    #
    # METRICS FROM DATABASE
    #
  
    def calculate_daily_tokens
      BedrockQuery.where(created_at: @date.all_day)
                  .sum("input_tokens + output_tokens")
    end
  
    def calculate_daily_cost
      BedrockQuery.where(created_at: @date.all_day)
                  .sum { |query| query.cost }
    end
  
    def calculate_daily_queries
      BedrockQuery.where(created_at: @date.all_day).count
    end
  
    #
    # METRICS FROM CLOUDWATCH
    #
  
    def get_aurora_acu_average
      return 0 unless @aurora_cluster_identifier.present?

      begin
        resp = @cloudwatch.get_metric_statistics(
          namespace: "AWS/RDS",
          metric_name: "ServerlessDatabaseCapacity",
          dimensions: [
            { name: "DBClusterIdentifier", value: @aurora_cluster_identifier }
          ],
          start_time: @date.beginning_of_day,
          end_time: @date.end_of_day,
          period: 3600,
          statistics: ["Average"]
        )
  
        return 0 if resp.datapoints.empty?
  
        averages = resp.datapoints.map(&:average)
        averages.sum / averages.count
      rescue => e
        Rails.logger.error("Error fetching Aurora ACU metrics: #{e.message}")
        0
      end
    end
  
    #
    # S3 METRICS
    #
  
    def get_s3_document_count
      return 0 unless @knowledge_base_bucket.present?

      begin
        resp = @s3.list_objects_v2(bucket: @knowledge_base_bucket)
        resp.contents.count
      rescue
        0
      end
    end
  
    def get_s3_total_size
      return 0 unless @knowledge_base_bucket.present?

      begin
        resp = @s3.list_objects_v2(bucket: @knowledge_base_bucket)
        resp.contents.sum(&:size)
      rescue
        0
      end
    end
  end
  