# frozen_string_literal: true

require 'aws-sdk-cloudwatch'
require 'aws-sdk-s3'
require 'aws-sdk-rds'
require 'aws-sdk-core/static_token_provider'

class SimpleMetricsService
  include AwsClientInitializer
  include ActionView::Helpers::NumberHelper

  def initialize(date = Date.current, cloudwatch: nil, s3: nil, rds: nil)
    @date = date

    # Allow optional injection of AWS clients for testing
    client_options = build_aws_client_options

    @cloudwatch = cloudwatch || Aws::CloudWatch::Client.new(client_options)
    @s3 = s3 || Aws::S3::Client.new(client_options)
    @rds = rds || Aws::RDS::Client.new(client_options)

    # Get configuration from Rails credentials or environment variables
    @knowledge_base_bucket = resolve_knowledge_base_bucket
    @aurora_cluster_identifier = Rails.application.credentials.dig(:aws, :aurora_db_cluster_identifier) ||
                                 ENV.fetch('AURORA_DB_CLUSTER_IDENTIFIER', nil)
  end

  # Update only database-based metrics (tokens, cost, queries) without calling CloudWatch
  # This is faster and should be called after each query
  def self.update_database_metrics_only
    today = Date.current
    queries = BedrockQuery.where(created_at: today.all_day)

    # Calculate tokens and count using SQL (efficient)
    tokens = queries.sum("input_tokens + output_tokens")
    query_count = queries.count

    # Calculate cost using pluck to avoid loading full objects (cost depends on model_id)
    cost = queries.pluck(:model_id, :input_tokens, :output_tokens).sum do |model_id, input, output|
      BedrockQuery.new(model_id: model_id, input_tokens: input, output_tokens: output).cost
    end

    # Use upsert_all for atomic, efficient updates
    # rubocop:disable Rails/SkipsModelValidations
    CostMetric.upsert_all(
      [
        { date: today, metric_type: :daily_tokens, value: tokens, created_at: Time.current, updated_at: Time.current },
        { date: today, metric_type: :daily_cost, value: cost, created_at: Time.current, updated_at: Time.current },
        { date: today, metric_type: :daily_queries, value: query_count, created_at: Time.current, updated_at: Time.current }
      ],
      unique_by: [:date, :metric_type]
    )
    # rubocop:enable Rails/SkipsModelValidations
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

  def save_daily_metrics
    metrics = collect_daily_metrics

    # Use upsert_all for atomic, efficient updates
    # rubocop:disable Rails/SkipsModelValidations
    CostMetric.upsert_all(
      [
        { date: @date, metric_type: :daily_tokens, value: metrics[:daily_tokens], created_at: Time.current, updated_at: Time.current },
        { date: @date, metric_type: :daily_cost, value: metrics[:daily_cost], created_at: Time.current, updated_at: Time.current },
        { date: @date, metric_type: :daily_queries, value: metrics[:daily_queries], created_at: Time.current, updated_at: Time.current },
        { date: @date, metric_type: :aurora_acu_avg, value: metrics[:aurora_acu_avg], created_at: Time.current, updated_at: Time.current },
        { date: @date, metric_type: :s3_documents_count, value: metrics[:s3_documents_count], created_at: Time.current, updated_at: Time.current },
        { date: @date, metric_type: :s3_total_size, value: metrics[:s3_total_size], created_at: Time.current, updated_at: Time.current }
      ],
      unique_by: [:date, :metric_type]
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  private

  #
  # DATABASE METRICS
  #

  # Calculate all DB metrics efficiently - reuse the same query scope
  def calculate_daily_db_metrics
    queries = BedrockQuery.where(created_at: @date.all_day)
    {
      tokens: queries.sum("input_tokens + output_tokens"),
      # Cost calculation uses pluck to avoid loading full objects (cost depends on model_id)
      cost: queries.pluck(:model_id, :input_tokens, :output_tokens).sum do |model_id, input, output|
        BedrockQuery.new(model_id: model_id, input_tokens: input, output_tokens: output).cost
      end,
      count: queries.count
    }
  end

  def calculate_daily_tokens
    calculate_daily_db_metrics[:tokens]
  end

  def calculate_daily_cost
    calculate_daily_db_metrics[:cost]
  end

  def calculate_daily_queries
    calculate_daily_db_metrics[:count]
  end

  #
  # CLOUDWATCH METRICS
  #

  def get_aurora_acu_average
    cluster_id = @aurora_cluster_identifier ||
                 Rails.application.credentials.dig(:aws, :aurora_db_cluster_identifier) ||
                 ENV["AURORA_DB_CLUSTER_IDENTIFIER"] ||
                 (Rails.env.development? ? 'knowledgebasequickcreateaurora-407-auroradbcluster-bb0lvonokgdy' : nil)

    return 0.0 if cluster_id.blank?

    Rails.logger.info("🔍 Checking Aurora cluster: #{cluster_id}")

    begin
      cluster = fetch_aurora_cluster(cluster_id)
      return 0.0 unless cluster_available?(cluster)

      acu = calculate_acu_from_cloudwatch(cluster_id) || fallback_to_current_capacity(cluster)
      Rails.logger.info("✅ Aurora ACU average: #{acu.round(2)}") if acu > 0
      acu.round(2)

    rescue Aws::RDS::Errors::DBClusterNotFoundFault => e
      Rails.logger.error("❌ Aurora cluster not found: #{cluster_id}")
      0.0
    rescue Aws::CloudWatch::Errors::ServiceError => e
      Rails.logger.error("❌ Aurora CloudWatch error: #{e.message}")
      fallback_acu_on_cloudwatch_error(cluster_id)
    rescue => e
      Rails.logger.error("Error fetching Aurora ACU metrics: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      0.0
    end
  end

  def fetch_aurora_cluster(cluster_id)
    cluster = @rds.describe_db_clusters(db_cluster_identifier: cluster_id).db_clusters.first
    Rails.logger.info("🏥 Aurora Status: #{cluster.status}, Capacity: #{cluster.capacity || 'paused'}")
    cluster
  end

  def cluster_available?(cluster)
    cluster.status == 'available' && cluster.capacity && cluster.capacity > 0
  end

  def calculate_acu_from_cloudwatch(cluster_id)
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

    return nil unless resp.datapoints.any?

    averages = resp.datapoints.map(&:average).compact
    return nil unless averages.any?

    averages.sum / averages.count
  end

  def fallback_to_current_capacity(cluster)
    if cluster.capacity && cluster.capacity > 0
      Rails.logger.info("📊 No CloudWatch data for #{@date}, using current capacity: #{cluster.capacity}")
      cluster.capacity.to_f
    else
      Rails.logger.warn("⚠️  No Aurora metrics available")
      0.0
    end
  end

  def fallback_acu_on_cloudwatch_error(cluster_id)
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
  end

  #
  # S3 METRICS
  #

  # Calculate both S3 metrics in a single iteration to avoid multiple API calls
  def calculate_s3_metrics
    bucket_name = @knowledge_base_bucket
    return { count: 0, total_size: 0 } unless bucket_name

    Rails.logger.info("📁 Checking S3 bucket: #{bucket_name}")

    begin
      valid_documents = []
      total_size = 0

      @s3.list_objects_v2(bucket: bucket_name).each do |response|
        (response.contents || []).each do |obj|
          if valid_document?(obj)
            valid_documents << obj
            total_size += obj.size
          end
        end
      end

      Rails.logger.info("📄 Found #{valid_documents.count} documents, #{number_to_human_size(total_size)} total")

      # Only log individual documents in development
      if Rails.env.development? && valid_documents.any?
        Rails.logger.info("   Sample documents (first 5):")
        valid_documents.first(5).each do |obj|
          Rails.logger.info("     - #{obj.key} (#{number_to_human_size(obj.size)})")
        end
      end

      { count: valid_documents.count, total_size: total_size }

    rescue Aws::S3::Errors::NoSuchBucket => e
      Rails.logger.error("❌ Bucket '#{bucket_name}' does not exist: #{e.message}")
      { count: 0, total_size: 0 }
    rescue Aws::S3::Errors::AccessDenied => e
      Rails.logger.error("❌ Access denied to bucket '#{bucket_name}': #{e.message}")
      { count: 0, total_size: 0 }
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("❌ S3 Error: #{e.message}")
      { count: 0, total_size: 0 }
    rescue => e
      Rails.logger.error("Error fetching S3 metrics: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      { count: 0, total_size: 0 }
    end
  end

  def get_s3_document_count
    calculate_s3_metrics[:count]
  end

  def get_s3_total_size
    calculate_s3_metrics[:total_size]
  end

  def valid_document?(obj)
    # Exclude hidden files, system metadata, directories, and very small files
    !obj.key.start_with?('.') &&
      obj.key.exclude?('$folder$') &&
      !obj.key.end_with?('/') &&
      obj.size > 1024 # At least 1KB
  end

  #
  # CONFIGURATION
  #

  def resolve_knowledge_base_bucket
    # Priority: ENV > Rails credentials > hardcoded (development only)
    bucket = Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
             Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
             ENV['KNOWLEDGE_BASE_S3_BUCKET']

    # Only allow hardcoded bucket in development
    if bucket.blank? && Rails.env.development?
      bucket = 'document-chatbot-generic-tech-info'
      Rails.logger.info("🔍 Using hardcoded S3 bucket (development only): #{bucket}")
    elsif bucket.blank?
      Rails.logger.warn("⚠️  No S3 bucket configured - S3 metrics will be unavailable")
    end

    bucket
  end
end
