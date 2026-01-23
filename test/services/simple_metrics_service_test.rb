# frozen_string_literal: true

require 'test_helper'
require 'ostruct'

class SimpleMetricsServiceTest < ActiveSupport::TestCase
  # Disable parallelization because this test class stubs AWS client classes
  parallelize(workers: 1)

  TEST_DATE = Date.new(2024, 1, 15)
  TEST_BUCKET_NAME = 'test-bucket'
  TEST_CLUSTER_ID = 'test-cluster-123'

  setup do
    @test_date = TEST_DATE
    BedrockQuery.destroy_all
    CostMetric.destroy_all
    ENV['KNOWLEDGE_BASE_S3_BUCKET'] = TEST_BUCKET_NAME
    ENV['AURORA_DB_CLUSTER_IDENTIFIER'] = TEST_CLUSTER_ID
  end

  teardown do
    ENV.delete('KNOWLEDGE_BASE_S3_BUCKET')
    ENV.delete('AURORA_DB_CLUSTER_IDENTIFIER')
  end

  # Fake AWS clients for testing
  CloudWatchResponse = Struct.new(:datapoints, keyword_init: true)
  CloudWatchDatapoint = Struct.new(:average, :timestamp, keyword_init: true)
  S3ListResponse = Struct.new(:contents, keyword_init: true)
  S3Object = Struct.new(:key, :size, keyword_init: true)
  RDSCluster = Struct.new(:status, :capacity, keyword_init: true)
  RDSDescribeResponse = Struct.new(:db_clusters, keyword_init: true)

  class FakeCloudWatch
    attr_accessor :datapoints, :should_raise_error, :error_class

    def initialize(*_args, **_kwargs)
      @datapoints = []
      @should_raise_error = false
      @error_class = Aws::CloudWatch::Errors::ServiceError
    end

    def get_metric_statistics(*_args, **_kwargs)
      raise @error_class.new(nil, 'CloudWatch error') if @should_raise_error
      CloudWatchResponse.new(datapoints: @datapoints)
    end
  end

  class FakeS3
    attr_accessor :objects, :should_raise_error, :error_class

    def initialize(*_args, **_kwargs)
      @objects = []
      @should_raise_error = false
      @error_class = Aws::S3::Errors::ServiceError
    end

    def list_objects_v2(bucket:, **_kwargs)
      raise @error_class.new(nil, 'S3 error') if @should_raise_error
      [S3ListResponse.new(contents: @objects)].to_enum
    end
  end

  class FakeRDS
    attr_accessor :cluster_status, :cluster_capacity, :should_raise_error, :error_class

    def initialize(*_args, **_kwargs)
      @cluster_status = 'available'
      @cluster_capacity = 2.0
      @should_raise_error = false
      @error_class = Aws::RDS::Errors::ServiceError
    end

    def describe_db_clusters(db_cluster_identifier:, **_kwargs)
      raise @error_class.new(nil, 'RDS error') if @should_raise_error
      RDSDescribeResponse.new(
        db_clusters: [RDSCluster.new(status: @cluster_status, capacity: @cluster_capacity)]
      )
    end
  end

  def with_mock_aws_clients
    fake_cloudwatch = FakeCloudWatch.new
    fake_s3 = FakeS3.new
    fake_rds = FakeRDS.new

    original_cloudwatch_new = Aws::CloudWatch::Client.method(:new)
    original_s3_new = Aws::S3::Client.method(:new)
    original_rds_new = Aws::RDS::Client.method(:new)

    Aws::CloudWatch::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_cloudwatch }
    Aws::S3::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_s3 }
    Aws::RDS::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_rds }

    yield fake_cloudwatch, fake_s3, fake_rds
  ensure
    Aws::CloudWatch::Client.define_singleton_method(:new) { |*args, **kwargs| original_cloudwatch_new.call(*args, **kwargs) }
    Aws::S3::Client.define_singleton_method(:new) { |*args, **kwargs| original_s3_new.call(*args, **kwargs) }
    Aws::RDS::Client.define_singleton_method(:new) { |*args, **kwargs| original_rds_new.call(*args, **kwargs) }
  end

  test 'calculates database metrics correctly and filters by date' do
    # Create queries for test date
    create_bedrock_query(input_tokens: 1000, output_tokens: 500, created_at: @test_date.beginning_of_day)
    create_bedrock_query(input_tokens: 2000, output_tokens: 1000, created_at: @test_date.beginning_of_day + 2.hours)
    # Query from different date should be excluded
    create_bedrock_query(input_tokens: 500, output_tokens: 250, created_at: (@test_date - 1.day).beginning_of_day)

    with_mock_aws_clients do
      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Tokens: (1000 + 500) + (2000 + 1000) = 4500
      assert_equal 4500, metrics[:daily_tokens]
      # Queries: only 2 from test date
      assert_equal 2, metrics[:daily_queries]
      # Cost: calculated using model pricing (Haiku default)
      assert metrics[:daily_cost].positive?
      assert_kind_of Numeric, metrics[:daily_cost]
    end
  end

  test 'aurora_acu_average returns CloudWatch average when data available' do
    with_mock_aws_clients do |fake_cloudwatch, _fake_s3, fake_rds|
      fake_cloudwatch.datapoints = [
        CloudWatchDatapoint.new(average: 2.0, timestamp: Time.utc(2024, 1, 15, 10)),
        CloudWatchDatapoint.new(average: 4.0, timestamp: Time.utc(2024, 1, 15, 14)),
        CloudWatchDatapoint.new(average: 3.0, timestamp: Time.utc(2024, 1, 15, 18))
      ]
      fake_rds.cluster_status = 'available'
      fake_rds.cluster_capacity = 2.0

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Average: (2.0 + 4.0 + 3.0) / 3 = 3.0
      assert_in_delta 3.0, metrics[:aurora_acu_avg], 0.01
    end
  end

  test 'aurora_acu_average falls back to current capacity when CloudWatch has no data' do
    with_mock_aws_clients do |fake_cloudwatch, _fake_s3, fake_rds|
      fake_cloudwatch.datapoints = []
      fake_rds.cluster_status = 'available'
      fake_rds.cluster_capacity = 2.5

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_in_delta 2.5, metrics[:aurora_acu_avg], 0.01
    end
  end

  test 'aurora_acu_average returns 0 when cluster is paused or not found' do
    with_mock_aws_clients do |_fake_cloudwatch, _fake_s3, fake_rds|
      # Test paused cluster
      fake_rds.cluster_status = 'paused'
      fake_rds.cluster_capacity = 0

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0.0, metrics[:aurora_acu_avg]

      # Test cluster not found
      fake_rds.should_raise_error = true
      fake_rds.error_class = Aws::RDS::Errors::DBClusterNotFoundFault

      service2 = SimpleMetricsService.new(@test_date)
      metrics2 = service2.collect_daily_metrics

      assert_equal 0.0, metrics2[:aurora_acu_avg]
    end
  end

  test 's3 metrics count only valid documents and calculate total size' do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      fake_s3.objects = [
        S3Object.new(key: 'document1.pdf', size: 1_000_000), # Valid
        S3Object.new(key: 'document2.pdf', size: 2_000_000), # Valid
        S3Object.new(key: '.hidden.pdf', size: 10_000), # Excluded: hidden
        S3Object.new(key: 'folder/', size: 0), # Excluded: directory
        S3Object.new(key: 'metadata$folder$', size: 500), # Excluded: metadata
        S3Object.new(key: 'small.txt', size: 500) # Excluded: too small
      ]

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      # Should only count valid documents: document1.pdf and document2.pdf
      assert_equal 2, metrics[:s3_documents_count]
      # Total size: only valid documents (1MB + 2MB = 3MB)
      assert_equal 3_000_000, metrics[:s3_total_size]
    end
  end

  test 's3 metrics return 0 on bucket errors' do
    with_mock_aws_clients do |_fake_cloudwatch, fake_s3, _fake_rds|
      # Test NoSuchBucket
      fake_s3.should_raise_error = true
      fake_s3.error_class = Aws::S3::Errors::NoSuchBucket

      service = SimpleMetricsService.new(@test_date)
      metrics = service.collect_daily_metrics

      assert_equal 0, metrics[:s3_documents_count]
      assert_equal 0, metrics[:s3_total_size]

      # Test AccessDenied (same outcome)
      fake_s3.error_class = Aws::S3::Errors::AccessDenied

      service2 = SimpleMetricsService.new(@test_date)
      metrics2 = service2.collect_daily_metrics

      assert_equal 0, metrics2[:s3_documents_count]
      assert_equal 0, metrics2[:s3_total_size]
    end
  end

  test 'save_daily_metrics persists all metrics and is idempotent' do
    create_bedrock_query(input_tokens: 1000, output_tokens: 500, created_at: @test_date.beginning_of_day)

    with_mock_aws_clients do |fake_cloudwatch, fake_s3, fake_rds|
      fake_cloudwatch.datapoints = [CloudWatchDatapoint.new(average: 2.0, timestamp: Time.utc(2024, 1, 15, 12))]
      fake_s3.objects = [S3Object.new(key: 'doc.pdf', size: 1_000_000)]
      fake_rds.cluster_status = 'available'
      fake_rds.cluster_capacity = 2.0

      service = SimpleMetricsService.new(@test_date)

      # First save
      assert_difference 'CostMetric.count', 6 do
        service.save_daily_metrics
      end

      # Verify all metrics saved
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :daily_tokens)
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :daily_cost)
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :daily_queries)
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :aurora_acu_avg)
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :s3_documents_count)
      assert_not_nil CostMetric.find_by(date: @test_date, metric_type: :s3_total_size)

      # Second save (idempotent)
      first_count = CostMetric.where(date: @test_date).count
      service.save_daily_metrics
      second_count = CostMetric.where(date: @test_date).count

      assert_equal first_count, second_count, 'Should not create duplicate metrics'
    end
  end

  test 'returns 0 for all metrics when no data exists' do
    with_mock_aws_clients do |fake_cloudwatch, fake_s3, fake_rds|
      fake_cloudwatch.datapoints = []
      fake_s3.objects = []
      fake_rds.cluster_status = 'paused'
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

  private

  def create_bedrock_query(
    input_tokens:, output_tokens:, model_id: 'anthropic.claude-3-haiku-20240307-v1:0',
    user_query: 'Test query',
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
end
