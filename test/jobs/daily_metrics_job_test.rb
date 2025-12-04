require "test_helper"

class DailyMetricsJobTest < ActiveJob::TestCase
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

  def setup_aws_mocks
    # Create mock AWS modules and classes
    aws_module = Module.new
    cloudwatch_module = Module.new
    s3_module = Module.new

    cloudwatch_module.const_set(:Client, FakeCloudWatch)
    s3_module.const_set(:Client, FakeS3)
    aws_module.const_set(:CloudWatch, cloudwatch_module)
    aws_module.const_set(:S3, s3_module)

    # Temporarily replace Aws constant to use our mocks
    @original_aws = Object.const_get(:Aws) if Object.const_defined?(:Aws)
    Object.send(:remove_const, :Aws) if Object.const_defined?(:Aws)
    Object.const_set(:Aws, aws_module)
  end

  def teardown_aws_mocks
    # Restore original Aws constant
    Object.send(:remove_const, :Aws)
    Object.const_set(:Aws, @original_aws) if @original_aws
  end

  test "enqueues correctly" do
    setup_aws_mocks
    begin
      assert_enqueued_with(job: DailyMetricsJob) do
        DailyMetricsJob.perform_later(Date.today)
      end
    ensure
      teardown_aws_mocks
    end
  end

  test "performs without crashing" do
    setup_aws_mocks
    begin
      assert_nothing_raised do
        DailyMetricsJob.perform_now(Date.today)
      end
    ensure
      teardown_aws_mocks
    end
  end
end
