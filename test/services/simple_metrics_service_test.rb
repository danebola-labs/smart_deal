require "test_helper"

class SimpleMetricsServiceTest < ActiveSupport::TestCase
  # Disable parallelization for this test class because it manipulates
  # global constants (Aws) which can cause race conditions when running in parallel
  parallelize(workers: 1)
  class FakeCloudWatch
    def initialize(*); end

    def get_metric_statistics(*)
      OpenStruct.new(datapoints: [])
    end
  end

  class FakeS3
    def initialize(*); end

    def list_objects_v2(*)
      OpenStruct.new(contents: [])
    end
  end

  class FakeRDS
    def initialize(*); end

    def describe_db_clusters(*)
      OpenStruct.new(db_clusters: [])
    end
  end

  test "collect_daily_metrics returns all keys" do
    # Create mock AWS modules and classes
    aws_module = Module.new
    cloudwatch_module = Module.new
    s3_module = Module.new
    rds_module = Module.new
    cloudwatch_errors_module = Module.new
    rds_errors_module = Module.new
    s3_errors_module = Module.new
    static_token_provider_module = Module.new

    cloudwatch_module.const_set(:Client, FakeCloudWatch)
    s3_module.const_set(:Client, FakeS3)
    rds_module.const_set(:Client, FakeRDS)
    
    # Mock error classes
    cloudwatch_errors_module.const_set(:ServiceError, Class.new(StandardError))
    rds_errors_module.const_set(:DBClusterNotFoundFault, Class.new(StandardError))
    s3_errors_module.const_set(:ServiceError, Class.new(StandardError))
    s3_errors_module.const_set(:NoSuchBucket, Class.new(StandardError))
    s3_errors_module.const_set(:AccessDenied, Class.new(StandardError))
    
    cloudwatch_module.const_set(:Errors, cloudwatch_errors_module)
    rds_module.const_set(:Errors, rds_errors_module)
    s3_module.const_set(:Errors, s3_errors_module)
    
    # Mock StaticTokenProvider (needed for require "aws-sdk-core/static_token_provider")
    static_token_provider_class = Class.new do
      def initialize(token); end
    end
    static_token_provider_module.const_set(:StaticTokenProvider, static_token_provider_class)
    static_token_provider_module.const_set(:TokenProvider, Module.new) # For the require
    
    aws_module.const_set(:CloudWatch, cloudwatch_module)
    aws_module.const_set(:S3, s3_module)
    aws_module.const_set(:RDS, rds_module)
    aws_module.const_set(:StaticTokenProvider, static_token_provider_module)

    # Temporarily replace Aws constant to use our mocks
    original_aws = Object.const_get(:Aws) if Object.const_defined?(:Aws)
    Object.send(:remove_const, :Aws) if Object.const_defined?(:Aws)
    Object.const_set(:Aws, aws_module)

    begin
      service = SimpleMetricsService.new(Date.today)

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
    ensure
      # Restore original Aws constant
      Object.send(:remove_const, :Aws)
      Object.const_set(:Aws, original_aws) if original_aws
    end
  end
end
