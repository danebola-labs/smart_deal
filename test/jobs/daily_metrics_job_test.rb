# frozen_string_literal: true

require 'test_helper'

class DailyMetricsJobTest < ActiveJob::TestCase
  # Disable parallelization for this test class because it manipulates
  # global constants (SimpleMetricsService) which can cause race conditions when running in parallel
  parallelize(workers: 1)

  TEST_DATE = Date.new(2024, 1, 15)

  setup do
    @test_date = TEST_DATE
    # Clean up test data for isolation
    CostMetric.destroy_all
    BedrockQuery.destroy_all
  end

  # Helper method to stub SimpleMetricsService.new at the class level.
  # This approach avoids introducing dependency injection prematurely while
  # allowing tests to isolate the job from the actual SimpleMetricsService.
  # The original method is always restored in the ensure block to prevent test pollution.
  #
  # @param mock_service [Object] The mock service instance to return from SimpleMetricsService.new
  # @param capture_date [Boolean] If true, captures the date argument passed to SimpleMetricsService.new
  def with_mock_simple_metrics_service(mock_service, capture_date: false)
    original_new = SimpleMetricsService.method(:new)

    if capture_date
      SimpleMetricsService.define_singleton_method(:new) do |date = Date.current|
        mock_service.capture_date(date)
        mock_service
      end
    else
      SimpleMetricsService.define_singleton_method(:new) { |*_args| mock_service }
    end

    yield
  ensure
    # Always restore original method to prevent test pollution
    SimpleMetricsService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to create a mock SimpleMetricsService that simulates the contract of
  # SimpleMetricsService#save_daily_metrics. The mock tracks calls and can simulate
  # errors when should_raise is true. It also tracks the date passed to new for verification.
  def create_mock_service(should_raise: false, error_message: nil)
    captured_date = nil
    call_count = 0

    mock_service = Object.new
    mock_service.define_singleton_method(:save_daily_metrics) do
      call_count += 1
      raise StandardError, error_message || 'Service error' if should_raise
    end
    mock_service.define_singleton_method(:call_count) { call_count }
    mock_service.define_singleton_method(:captured_date) { captured_date }
    mock_service.define_singleton_method(:capture_date) { |date| captured_date = date }

    mock_service
  end

  test 'enqueues correctly' do
    assert_enqueued_with(job: DailyMetricsJob) do
      DailyMetricsJob.perform_later(@test_date)
    end
  end

  test 'calls SimpleMetricsService with correct date' do
    mock_service = create_mock_service
    with_mock_simple_metrics_service(mock_service, capture_date: true) do
      DailyMetricsJob.perform_now(@test_date)
      assert_equal @test_date, mock_service.captured_date
    end
  end

  test 'calls SimpleMetricsService with Date.current when no date provided' do
    mock_service = create_mock_service
    frozen_date = Date.new(2024, 1, 15)

    travel_to frozen_date do
      with_mock_simple_metrics_service(mock_service, capture_date: true) do
        DailyMetricsJob.perform_now
        assert_equal Date.current, mock_service.captured_date
      end
    end
  end

  test 'calls save_daily_metrics on SimpleMetricsService' do
    mock_service = create_mock_service
    with_mock_simple_metrics_service(mock_service) do
      DailyMetricsJob.perform_now(@test_date)
      assert_equal 1, mock_service.call_count, 'save_daily_metrics should be called exactly once'
    end
  end

  test 're-raises errors from SimpleMetricsService to allow retries' do
    # The job must propagate errors to allow ActiveJob's retry mechanism to work.
    # This test verifies that errors from SimpleMetricsService are not swallowed.
    error_message = 'Failed to save metrics'
    mock_service = create_mock_service(should_raise: true, error_message: error_message)

    with_mock_simple_metrics_service(mock_service) do
      assert_raises(StandardError) do
        DailyMetricsJob.perform_now(@test_date)
      end
    end
  end

  test 'is idempotent - can be executed multiple times for same date' do
    # Create a mock service that tracks how many times save_daily_metrics is called
    mock_service = create_mock_service

    with_mock_simple_metrics_service(mock_service) do
      # Execute job twice for the same date
      DailyMetricsJob.perform_now(@test_date)
      DailyMetricsJob.perform_now(@test_date)

      # Both executions should succeed and call save_daily_metrics
      assert_equal 2, mock_service.call_count, 'save_daily_metrics should be called for each execution'
    end
  end

  test 'performs without crashing with real service' do
    # This test uses the real SimpleMetricsService but with mocked AWS clients
    # to verify the job doesn't crash in a realistic scenario
    CloudWatchResponse = Struct.new(:datapoints, keyword_init: true)
    S3ListResponse = Struct.new(:contents, keyword_init: true)
    RDSDescribeResponse = Struct.new(:db_clusters, keyword_init: true)

    fake_cloudwatch = Object.new
    fake_cloudwatch.define_singleton_method(:get_metric_statistics) { |*| CloudWatchResponse.new(datapoints: []) }

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:list_objects_v2) { |*| [S3ListResponse.new(contents: [])].to_enum }

    fake_rds = Object.new
    fake_rds.define_singleton_method(:describe_db_clusters) { |*| RDSDescribeResponse.new(db_clusters: []) }

    original_cloudwatch_new = Aws::CloudWatch::Client.method(:new)
    original_s3_new = Aws::S3::Client.method(:new)
    original_rds_new = Aws::RDS::Client.method(:new)

    Aws::CloudWatch::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_cloudwatch }
    Aws::S3::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_s3 }
    Aws::RDS::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake_rds }

    begin
      ENV['KNOWLEDGE_BASE_S3_BUCKET'] = 'test-bucket'
      ENV['AURORA_DB_CLUSTER_IDENTIFIER'] = 'test-cluster'

      assert_nothing_raised do
        DailyMetricsJob.perform_now(@test_date)
      end
    ensure
      Aws::CloudWatch::Client.define_singleton_method(:new) { |*args, **kwargs| original_cloudwatch_new.call(*args, **kwargs) }
      Aws::S3::Client.define_singleton_method(:new) { |*args, **kwargs| original_s3_new.call(*args, **kwargs) }
      Aws::RDS::Client.define_singleton_method(:new) { |*args, **kwargs| original_rds_new.call(*args, **kwargs) }
      ENV.delete('KNOWLEDGE_BASE_S3_BUCKET')
      ENV.delete('AURORA_DB_CLUSTER_IDENTIFIER')
    end
  end
end
