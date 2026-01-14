require "test_helper"
require "ostruct"

class SimpleMetricsServiceTest < ActiveSupport::TestCase
  # Disable parallelization because this test class stubs AWS client classes
  # (Aws::CloudWatch::Client, Aws::S3::Client, Aws::RDS::Client) at the class level.
  # Running tests in parallel would cause race conditions when multiple workers
  # simultaneously modify these global class methods, leading to unpredictable test failures.
  parallelize(workers: 1)

  TEST_DATE = Date.new(2024, 1, 15)
  TEST_BUCKET_NAME = "test-bucket"
  TEST_CLUSTER_ID = "test-cluster-123"

  setup do
    @test_date = TEST_DATE
    # Clean up test data - using destroy_all to trigger callbacks if any
    BedrockQuery.destroy_all
    CostMetric.destroy_all
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = TEST_BUCKET_NAME
    ENV["AURORA_DB_CLUSTER_IDENTIFIER"] = TEST_CLUSTER_ID
  end

  teardown do
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
    ENV.delete("AURORA_DB_CLUSTER_IDENTIFIER")
  end

  # Fake AWS CloudWatch Client
  # Accepts *args and **kwargs to be compatible with AWS SDK initialization
  CloudWatchResponse = Struct.new(:datapoints, keyword_init: true)
  CloudWatchDatapoint = Struct.new(:average, :timestamp, keyword_init: true)

  class FakeCloudWatch
    attr_accessor :datapoints, :should_raise_error, :error_class

    def initialize(*args, **kwargs)
      @datapoints = []
      @should_raise_error = false
      @error_class = Aws::CloudWatch::Errors::ServiceError
    end

    def get_metric_statistics(*args, **kwargs)
      raise @error_class.new(nil, "CloudWatch error") if @should_raise_error
      CloudWatchResponse.new(datapoints: @datapoints)
    end
  end

  # Fake AWS S3 Client
  # Accepts *args and **kwargs to be compatible with AWS SDK initialization
  S3ListResponse = Struct.new(:contents, keyword_init: true)
  S3Object = Struct.new(:key, :size, keyword_init: true)

  class FakeS3
    attr_accessor :objects, :should_raise_error, :error_class

    def initialize(*args, **kwargs)
      @objects = []
      @should_raise_error = false
      @error_class = Aws::S3::Errors::ServiceError
    end

    def list_objects_v2(bucket:, **kwargs)
      raise @error_class.new(nil, "S3 error") if @should_raise_error
      # Return an enumerable that yields responses
      [S3ListResponse.new(contents: @objects)].to_enum
    end
  end

  # Fake AWS RDS Client
  # Accepts *args and **kwargs to be compatible with AWS SDK initialization
  RDSCluster = Struct.new(:status, :capacity, keyword_init: true)
  RDSDescribeResponse = Struct.new(:db_clusters, keyword_init: true)

  class FakeRDS
    attr_accessor :cluster_status, :cluster_capacity, :should_raise_error, :error_class

    def initialize(*args, **kwargs)
      @cluster_status = "available"
      @cluster_capacity = 2.0
      @should_raise_error = false
      @error_class = Aws::RDS::Errors::ServiceError
    end

    def describe_db_clusters(db_cluster_identifier:, **kwargs)
      raise @error_class.new(nil, "RDS error") if @should_raise_error
      RDSDescribeResponse.new(
        db_clusters: [
          RDSCluster.new(
            status: @cluster_status,
            capacity: @cluster_capacity
          )
        ]
      )
    end
  end

  # Helper method to stub AWS clients at the class level.
  # This approach avoids introducing dependency injection prematurely while
  # allowing tests to isolate the service from actual AWS services.
  # The original methods are always restored in the ensure block to prevent test pollution.
  def with_mock_aws_clients
    fake_cloudwatch = FakeCloudWatch.new
    fake_s3 = FakeS3.new
    fake_rds = FakeRDS.new
    
    original_cloudwatch_new = Aws::CloudWatch::Client.method(:new)
    original_s3_new = Aws::S3::Client.method(:new)
    original_rds_new = Aws::RDS::Client.method(:new)
    
    Aws::CloudWatch::Client.define_singleton_method(:new) { |*args, **kwargs| fake_cloudwatch }
    Aws::S3::Client.define_singleton_method(:new) { |*args, **kwargs| fake_s3 }
    Aws::RDS::Client.define_singleton_method(:new) { |*args, **kwargs| fake_rds }
    
    yield fake_cloudwatch, fake_s3, fake_rds
  ensure
    # Always restore original methods to prevent test pollution
    Aws::CloudWatch::Client.define_singleton_method(:new) { |*args, **kwargs| original_cloudwatch_new.call(*args, **kwargs) }
    Aws::S3::Client.define_singleton_method(:new) { |*args, **kwargs| original_s3_new.call(*args, **kwargs) }
    Aws::RDS::Client.define_singleton_method(:new) { |*args, **kwargs| original_rds_new.call(*args, **kwargs) }
  end

  # Helper to create BedrockQuery records for testing
  # Reduces duplication and ensures consistent test data creation
  private def create_bedrock_query(
    model_id: "anthropic.claude-3-haiku-20240307-v1:0",
    input_tokens:,
    output_tokens:,
    user_query: "Test query",
    latency_ms: 100,
    created_at: @test_date.beginning_of_day
  )
    BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: user_query,
      latency_ms: latency_ms,
      created_at: created_at
    )
  end

  test "collect_daily_metrics returns all expected keys" do
    with_mock_aws_clients do
      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      expected_keys = [
        :daily_tokens,
        :daily_cost,
        :daily_queries,
        :aurora_acu_avg,
        :s3_documents_count,
        :s3_total_size
      ]

      assert_equal expected_keys.sort, metrics.keys.sort
    end
  end

  test "calculates daily_tokens from BedrockQuery records" do
    # Create test queries for the test date
    create_bedrock_query(
      input_tokens: 1000,
      output_tokens: 500,
      user_query: "Test query 1",
      latency_ms: 100,
      created_at: @test_date.beginning_of_day + 1.hour
    )
    create_bedrock_query(
      input_tokens: 2000,
      output_tokens: 1000,
      user_query: "Test query 2",
      latency_ms: 150,
      created_at: @test_date.beginning_of_day + 2.hours
    )
    # Query from different date should not be included
    create_bedrock_query(
      input_tokens: 500,
      output_tokens: 250,
      user_query: "Test query 3",
      latency_ms: 80,
      created_at: (@test_date - 1.day).beginning_of_day
    )

    with_mock_aws_clients do
      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Expected: (1000 + 500) + (2000 + 1000) = 4500 tokens
      assert_equal 4500, metrics[:daily_tokens]
    end
  end

  test "calculates daily_cost from BedrockQuery records" do
    # Create test queries with known costs
    # Haiku pricing: input=0.00025, output=0.00125 per 1000 tokens
    create_bedrock_query(
      input_tokens: 1000,
      output_tokens: 2000,
      created_at: @test_date.beginning_of_day
    )
    # Cost: (1 * 0.00025) + (2 * 0.00125) = 0.00025 + 0.0025 = 0.00275

    with_mock_aws_clients do
      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_in_delta 0.00275, metrics[:daily_cost], 0.00001
    end
  end

  test "calculates daily_queries count" do
    # Create multiple queries for the test date
    3.times do |i|
      create_bedrock_query(
        input_tokens: 100,
        output_tokens: 50,
        user_query: "Test query #{i}",
        created_at: @test_date.beginning_of_day + i.hours
      )
    end
    # Query from different date should not be included
    create_bedrock_query(
      input_tokens: 100,
      output_tokens: 50,
      user_query: "Other date query",
      created_at: (@test_date - 1.day).beginning_of_day
    )

    with_mock_aws_clients do
      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 3, metrics[:daily_queries]
    end
  end

  test "calculates aurora_acu_average from CloudWatch metrics" do
    with_mock_aws_clients do |fake_cloudwatch, _fake_s3, fake_rds|
      # Setup CloudWatch datapoints
      fake_cloudwatch.datapoints = [
        CloudWatchDatapoint.new(average: 2.0, timestamp: Time.utc(2024, 1, 15, 10)),
        CloudWatchDatapoint.new(average: 4.0, timestamp: Time.utc(2024, 1, 15, 14)),
        CloudWatchDatapoint.new(average: 3.0, timestamp: Time.utc(2024, 1, 15, 18))
      ]
      fake_rds.cluster_status = "available"
      fake_rds.cluster_capacity = 2.0

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Average: (2.0 + 4.0 + 3.0) / 3 = 3.0
      assert_in_delta 3.0, metrics[:aurora_acu_avg], 0.01
    end
  end

  test "aurora_acu_average returns 0 when cluster is paused" do
    with_mock_aws_clients do |_fake_cloudwatch, _fake_s3, fake_rds|
      fake_rds.cluster_status = "paused"
      fake_rds.cluster_capacity = 0

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0.0, metrics[:aurora_acu_avg]
    end
  end

  test "aurora_acu_average uses current capacity when CloudWatch has no data" do
    with_mock_aws_clients do |fake_cloudwatch, _fake_s3, fake_rds|
      fake_cloudwatch.datapoints = []
      fake_rds.cluster_status = "available"
      fake_rds.cluster_capacity = 2.5

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_in_delta 2.5, metrics[:aurora_acu_avg], 0.01
    end
  end

  test "calculates s3_document_count correctly" do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      # Create mock S3 objects
      fake_s3.objects = [
        S3Object.new(key: "document1.pdf", size: 50000), # Valid document
        S3Object.new(key: "document2.pdf", size: 200000), # Valid document
        S3Object.new(key: ".hidden.pdf", size: 10000), # Hidden file (excluded)
        S3Object.new(key: "folder/", size: 0), # Directory (excluded)
        S3Object.new(key: "metadata$folder$", size: 500), # Metadata (excluded)
        S3Object.new(key: "small.txt", size: 500) # Too small (excluded)
      ]

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Should only count valid documents: document1.pdf and document2.pdf
      assert_equal 2, metrics[:s3_documents_count]
    end
  end

  test "calculates s3_total_size correctly" do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      fake_s3.objects = [
        S3Object.new(key: "doc1.pdf", size: 1_000_000),
        S3Object.new(key: "doc2.pdf", size: 2_500_000),
        S3Object.new(key: "doc3.pdf", size: 500_000)
      ]

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Total: 1MB + 2.5MB + 0.5MB = 4MB
      assert_equal 4_000_000, metrics[:s3_total_size]
    end
  end

  test "s3_document_count returns 0 when bucket does not exist" do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      fake_s3.should_raise_error = true
      fake_s3.error_class = Aws::S3::Errors::NoSuchBucket

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0, metrics[:s3_documents_count]
    end
  end

  test "s3_document_count returns 0 when access is denied" do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      fake_s3.should_raise_error = true
      fake_s3.error_class = Aws::S3::Errors::AccessDenied

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0, metrics[:s3_documents_count]
    end
  end

  test "s3_total_size returns 0 when bucket does not exist" do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      fake_s3.should_raise_error = true
      fake_s3.error_class = Aws::S3::Errors::NoSuchBucket

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0, metrics[:s3_total_size]
    end
  end

  test "aurora_acu_average returns 0 when cluster is not found" do
    with_mock_aws_clients do |_fake_cloudwatch, _fake_s3, fake_rds|
      fake_rds.should_raise_error = true
      fake_rds.error_class = Aws::RDS::Errors::DBClusterNotFoundFault

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0.0, metrics[:aurora_acu_avg]
    end
  end

  test "aurora_acu_average handles CloudWatch errors gracefully" do
    with_mock_aws_clients do |fake_cloudwatch, _fake_s3, fake_rds|
      fake_cloudwatch.should_raise_error = true
      fake_rds.cluster_status = "available"
      fake_rds.cluster_capacity = 1.5

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Should fallback to current capacity
      assert_in_delta 1.5, metrics[:aurora_acu_avg], 0.01
    end
  end

  test "save_daily_metrics persists metrics to database" do
    create_bedrock_query(
      input_tokens: 1000,
      output_tokens: 500,
      created_at: @test_date.beginning_of_day
    )

    with_mock_aws_clients do |fake_cloudwatch, fake_s3, fake_rds|
      fake_cloudwatch.datapoints = [CloudWatchDatapoint.new(average: 2.0, timestamp: Time.utc(2024, 1, 15, 12))]
      fake_s3.objects = [S3Object.new(key: "doc.pdf", size: 1_000_000)]
      fake_rds.cluster_status = "available"
      fake_rds.cluster_capacity = 2.0

      service = SimpleMetricsService.new(@test_date)
      
      assert_difference "CostMetric.count", 6 do
        service.save_daily_metrics
      end

      # Verify metrics were saved correctly with proper types
      daily_tokens_metric = CostMetric.find_by(date: @test_date, metric_type: :daily_tokens)
      assert_not_nil daily_tokens_metric, "daily_tokens metric should be saved"
      assert_equal :daily_tokens, daily_tokens_metric.metric_type
      assert_equal 1500, daily_tokens_metric.value

      daily_cost_metric = CostMetric.find_by(date: @test_date, metric_type: :daily_cost)
      assert_not_nil daily_cost_metric, "daily_cost metric should be saved"
      assert_equal :daily_cost, daily_cost_metric.metric_type
      assert_kind_of Numeric, daily_cost_metric.value

      s3_count_metric = CostMetric.find_by(date: @test_date, metric_type: :s3_documents_count)
      assert_not_nil s3_count_metric, "s3_documents_count metric should be saved"
      assert_equal :s3_documents_count, s3_count_metric.metric_type
      assert_equal 1, s3_count_metric.value
    end
  end

  test "save_daily_metrics is idempotent" do
    create_bedrock_query(
      input_tokens: 1000,
      output_tokens: 500,
      created_at: @test_date.beginning_of_day
    )

    with_mock_aws_clients do |fake_cloudwatch, fake_s3, fake_rds|
      fake_cloudwatch.datapoints = [CloudWatchDatapoint.new(average: 2.0, timestamp: Time.utc(2024, 1, 15, 12))]
      fake_s3.objects = [S3Object.new(key: "doc.pdf", size: 1_000_000)]
      fake_rds.cluster_status = "available"
      fake_rds.cluster_capacity = 2.0

      service = SimpleMetricsService.new(@test_date)
      
      # Save first time
      service.save_daily_metrics
      first_count = CostMetric.where(date: @test_date).count
      first_value = CostMetric.find_by(date: @test_date, metric_type: :daily_tokens).value

      # Save second time with same date
      service.save_daily_metrics
      second_count = CostMetric.where(date: @test_date).count
      second_value = CostMetric.find_by(date: @test_date, metric_type: :daily_tokens).value

      # Should not create duplicates, should update existing
      assert_equal first_count, second_count, "Should not create duplicate metrics for same date"
      assert_equal first_value, second_value, "Should maintain same values on second save"
    end
  end

  test "returns 0 for all metrics when no data exists" do
    with_mock_aws_clients do |fake_cloudwatch, fake_s3, fake_rds|
      fake_cloudwatch.datapoints = []
      fake_s3.objects = []
      fake_rds.cluster_status = "paused"
      fake_rds.cluster_capacity = 0

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0, metrics[:daily_tokens]
      assert_equal 0.0, metrics[:daily_cost]
      assert_equal 0, metrics[:daily_queries]
      assert_equal 0.0, metrics[:aurora_acu_avg]
      assert_equal 0, metrics[:s3_documents_count]
      assert_equal 0, metrics[:s3_total_size]
    end
  end
end
