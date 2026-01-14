require "test_helper"

class DailyMetricsJobTest < ActiveJob::TestCase
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

  # Helper method to stub AWS clients (following pattern from other tests)
  def with_mock_aws_clients
    fake_cloudwatch = FakeCloudWatch.new
    fake_s3 = FakeS3.new
    fake_rds = FakeRDS.new
    
    # Save original .new methods
    original_cloudwatch_new = Aws::CloudWatch::Client.method(:new)
    original_s3_new = Aws::S3::Client.method(:new)
    original_rds_new = Aws::RDS::Client.method(:new)
    
    # Stub the .new methods to return our fake clients
    Aws::CloudWatch::Client.define_singleton_method(:new) { |*args| fake_cloudwatch }
    Aws::S3::Client.define_singleton_method(:new) { |*args| fake_s3 }
    Aws::RDS::Client.define_singleton_method(:new) { |*args| fake_rds }
    
    yield
  ensure
    # Restore original methods
    if original_cloudwatch_new
      Aws::CloudWatch::Client.define_singleton_method(:new) { |*args| original_cloudwatch_new.call(*args) }
    end
    if original_s3_new
      Aws::S3::Client.define_singleton_method(:new) { |*args| original_s3_new.call(*args) }
    end
    if original_rds_new
      Aws::RDS::Client.define_singleton_method(:new) { |*args| original_rds_new.call(*args) }
    end
  end

  test "enqueues correctly" do
    with_mock_aws_clients do
      assert_enqueued_with(job: DailyMetricsJob) do
        DailyMetricsJob.perform_later(Date.today)
      end
    end
  end

  test "performs without crashing" do
    with_mock_aws_clients do
      assert_nothing_raised do
        DailyMetricsJob.perform_now(Date.today)
      end
    end
  end
end
