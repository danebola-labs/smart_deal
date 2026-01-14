require "aws-sdk-cloudwatch"
require "aws-sdk-s3"
require "aws-sdk-rds"
require "aws-sdk-core/static_token_provider"

class SimpleMetricsService
  include AwsClientInitializer

  def initialize(date = Date.current)
    @date = date
    
    # Use AWS client initializer concern
    client_options = build_aws_client_options
    
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
                   ENV["AURORA_DB_CLUSTER_IDENTIFIER"] ||
                   'knowledgebasequickcreateaurora-407-auroradbcluster-bb0lvonokgdy'
      
      return 0.0 unless cluster_id.present?

      Rails.logger.info("🔍 Checking Aurora cluster: #{cluster_id}")

      begin
        # 1. First check current cluster status
        cluster = @rds.describe_db_clusters(
          db_cluster_identifier: cluster_id
        ).db_clusters.first

        Rails.logger.info("🏥 Aurora Status: #{cluster.status}")
        Rails.logger.info("🏥 Current Capacity: #{cluster.capacity || 'paused'}")

        # 2. If cluster is paused or inactive, return 0
        if cluster.status != 'available' || !cluster.capacity || cluster.capacity == 0
          Rails.logger.info("😴 Aurora is paused or inactive (normal for Serverless when idle)")
          return 0.0
        end

        # 3. If cluster is active, get CloudWatch metrics
        resp = @cloudwatch.get_metric_statistics(
          namespace: "AWS/RDS",
          metric_name: "ServerlessDatabaseCapacity",
          dimensions: [
            { name: "DBClusterIdentifier", value: cluster_id }
          ],
          start_time: @date.beginning_of_day.utc,
          end_time: @date.end_of_day.utc,
          period: 3600, # 1 hour periods
          statistics: ["Average"]
        )

        Rails.logger.info("📊 Aurora datapoints: #{resp.datapoints.count}")

        if resp.datapoints.any?
          # Calculate average of all datapoints for the day
          averages = resp.datapoints.map(&:average).compact
          if averages.any?
            avg_acu = averages.sum / averages.count
            Rails.logger.info("✅ Aurora ACU average: #{avg_acu.round(2)}")
            return avg_acu.round(2)
          end
        end

        # 4. If no CloudWatch data but cluster is active, use current capacity
        if cluster.capacity && cluster.capacity > 0
          Rails.logger.info("📊 No CloudWatch data for #{@date}, using current capacity: #{cluster.capacity}")
          return cluster.capacity.to_f
        end

        # 5. Fallback: return 0 if no data available
        Rails.logger.warn("⚠️  No Aurora metrics available")
        0.0

      rescue Aws::RDS::Errors::DBClusterNotFoundFault => e
        Rails.logger.error("❌ Aurora cluster not found: #{cluster_id}")
        0.0
      rescue Aws::CloudWatch::Errors::ServiceError => e
        Rails.logger.error("❌ Aurora CloudWatch error: #{e.message}")
        # Try to use current capacity as fallback
        begin
          cluster = @rds.describe_db_clusters(db_cluster_identifier: cluster_id).db_clusters.first
          if cluster.status == 'available' && cluster.capacity && cluster.capacity > 0
            Rails.logger.info("📊 Using current capacity as fallback: #{cluster.capacity}")
            return cluster.capacity.to_f
          end
        rescue
          # Ignore fallback errors
        end
        0.0
      rescue => e
        Rails.logger.error("Error fetching Aurora ACU metrics: #{e.message}")
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
        # Collect all objects
        all_objects = []
        @s3.list_objects_v2(bucket: bucket_name).each do |response|
          all_objects.concat(response.contents || [])
        end
        
        # Filter only real documents (exclude metadata, hidden files, directories)
        real_documents = all_objects.select do |obj|
          # Exclude:
          # - Hidden files (starting with .)
          # - System metadata ($folder$)
          # - Directories (ending with /)
          # - Files smaller than 1KB (likely metadata)
          !obj.key.start_with?('.') && 
          !obj.key.include?('$folder$') &&
          !obj.key.end_with?('/') &&
          obj.size > 1024 # At least 1KB
        end
        
        Rails.logger.info("📄 Found #{all_objects.count} total objects, #{real_documents.count} real documents")
        
        if Rails.env.development? && real_documents.any?
          Rails.logger.info("   Real documents:")
          real_documents.each do |obj|
            Rails.logger.info("     - #{obj.key} (#{number_to_human_size(obj.size)})")
          end
        end
        
        real_documents.count
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
  