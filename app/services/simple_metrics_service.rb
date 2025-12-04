require "aws-sdk-cloudwatch"
require "aws-sdk-s3"
require "aws-sdk-rds"
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
      @rds = Aws::RDS::Client.new(client_options)
      
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
      cluster_id = @aurora_cluster_identifier || 
                   Rails.application.credentials.dig(:aws, :aurora_db_cluster_identifier) ||
                   ENV["AURORA_DB_CLUSTER_IDENTIFIER"]
      
      return 0.0 unless cluster_id.present?

      Rails.logger.info("🔍 Checking Aurora cluster: #{cluster_id}")

      begin
        # Aurora Serverless v2 uses ServerlessDatabaseCapacity metric
        # For Aurora Serverless v1, use ACUUtilization
        resp = @cloudwatch.get_metric_statistics(
          namespace: "AWS/RDS",
          metric_name: "ServerlessDatabaseCapacity",
          dimensions: [
            { name: "DBClusterIdentifier", value: cluster_id }
          ],
          start_time: @date.beginning_of_day.utc,
          end_time: @date.end_of_day.utc,
          period: 3600, # 1 hour periods
          statistics: ["Average", "Maximum"]
        )

        Rails.logger.info("📊 Aurora datapoints: #{resp.datapoints.count}")

        if resp.datapoints.empty?
          Rails.logger.warn("⚠️  No Aurora datapoints - cluster might be paused, checking status directly...")
          return check_aurora_status(cluster_id)
        end

        # Calculate average of all datapoints for the day
        averages = resp.datapoints.map(&:average).compact
        if averages.empty?
          Rails.logger.warn("⚠️  No valid averages in Aurora datapoints")
          return check_aurora_status(cluster_id)
        end

        avg_acu = averages.sum / averages.count
        Rails.logger.info("✅ Aurora ACU average: #{avg_acu.round(2)}")
        avg_acu.round(2)
      rescue Aws::CloudWatch::Errors::ServiceError => e
        Rails.logger.error("❌ Aurora CloudWatch error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        # Try to get cluster status directly as fallback
        check_aurora_status(cluster_id)
      rescue => e
        Rails.logger.error("Error fetching Aurora ACU metrics: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        0.0
      end
    end

    def check_aurora_status(cluster_id)
      begin
        cluster = @rds.describe_db_clusters(
          db_cluster_identifier: cluster_id
        ).db_clusters.first

        Rails.logger.info("🏥 Aurora Status: #{cluster.status}")
        Rails.logger.info("🏥 Aurora Engine Mode: #{cluster.engine_mode}")
        Rails.logger.info("🏥 Aurora Capacity: #{cluster.capacity}") if cluster.respond_to?(:capacity) && cluster.capacity

        # If cluster is available but paused, return 0
        # If available and has capacity, return capacity
        if cluster.status == 'available'
          capacity = cluster.respond_to?(:capacity) ? cluster.capacity : nil
          return capacity || 0.5 # Default to 0.5 ACU if available but no capacity info
        else
          Rails.logger.warn("⚠️  Aurora cluster status: #{cluster.status} - returning 0.0")
          return 0.0
        end
      rescue Aws::RDS::Errors::ServiceError => e
        Rails.logger.error("❌ Aurora RDS error: #{e.message}")
        0.0
      rescue => e
        Rails.logger.error("Error checking Aurora status: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        0.0
      end
    end
  
    #
    # S3 METRICS
    #
  
    def get_s3_document_count
      bucket_name = find_knowledge_base_bucket
      return 0 unless bucket_name

      Rails.logger.info("📁 Checking S3 bucket: #{bucket_name}")

      begin
        # Use paginator to count all objects efficiently
        total_count = 0
        
        @s3.list_objects_v2(bucket: bucket_name).each do |response|
          total_count += response.contents&.count || 0
        end
        
        Rails.logger.info("📄 Found #{total_count} objects in S3")
        total_count
      rescue Aws::S3::Errors::NoSuchBucket => e
        Rails.logger.error("❌ Bucket '#{bucket_name}' does not exist: #{e.message}")
        0
      rescue Aws::S3::Errors::AccessDenied => e
        Rails.logger.error("❌ Access denied to bucket '#{bucket_name}': #{e.message}")
        0
      rescue Aws::S3::Errors::ServiceError => e
        Rails.logger.error("❌ S3 Error: #{e.message}")
        0
      rescue => e
        Rails.logger.error("Error fetching S3 document count: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        0
      end
    end

    def get_s3_total_size
      bucket_name = find_knowledge_base_bucket
      return 0 unless bucket_name

      begin
        total_size = 0
        
        # Use paginator to sum all object sizes efficiently
        @s3.list_objects_v2(bucket: bucket_name).each do |response|
          total_size += response.contents&.sum(&:size) || 0
        end
        
        size_gb = (total_size / 1.gigabyte.to_f).round(2)
        Rails.logger.info("💾 Total S3 size: #{number_to_human_size(total_size)} (#{size_gb} GB)")
        total_size
      rescue Aws::S3::Errors::NoSuchBucket => e
        Rails.logger.error("❌ Bucket '#{bucket_name}' does not exist: #{e.message}")
        0
      rescue Aws::S3::Errors::AccessDenied => e
        Rails.logger.error("❌ Access denied to bucket '#{bucket_name}': #{e.message}")
        0
      rescue Aws::S3::Errors::ServiceError => e
        Rails.logger.error("❌ S3 Size Error: #{e.message}")
        0
      rescue => e
        Rails.logger.error("Error fetching S3 total size: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        0
      end
    end

    def find_knowledge_base_bucket
      # Priority order:
      # 1. Explicitly configured bucket name (hardcoded for now)
      # 2. Environment variable
      # 3. Rails credentials
      # 4. Auto-detection
      
      # Hardcoded bucket name (verified and working)
      hardcoded_bucket = 'document-chatbot-generic-tech-info'
      
      # Try environment variable
      bucket_from_env = ENV['KNOWLEDGE_BASE_S3_BUCKET'] ||
                        Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
                        Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket)
      
      # Use configured bucket if available, otherwise use hardcoded
      bucket_name = bucket_from_env.present? ? bucket_from_env : hardcoded_bucket
      
      Rails.logger.info("🔍 Using S3 bucket: #{bucket_name}") if Rails.env.development?
      bucket_name
    end

    def number_to_human_size(size)
      units = ['B', 'KB', 'MB', 'GB', 'TB']
      unit = 0
      while size >= 1024 && unit < units.length - 1
        size /= 1024.0
        unit += 1
      end
      "#{size.round(2)} #{units[unit]}"
    end
  end
  