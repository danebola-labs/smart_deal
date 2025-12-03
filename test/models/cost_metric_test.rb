require "test_helper"

class CostMetricTest < ActiveSupport::TestCase
  # No fixtures for this model - tests create their own specific data
  # This avoids conflicts and makes tests more explicit and controllable
  
  test "requires date, metric_type, and value" do
    metric = CostMetric.new

    assert_not metric.valid?
    assert_includes metric.errors[:date], "can't be blank"
    assert_includes metric.errors[:metric_type], "can't be blank"
    assert_includes metric.errors[:value], "can't be blank"
  end

  test "enforces uniqueness of date + metric_type" do
    CostMetric.create!(
      date: Date.today,
      metric_type: :daily_tokens,
      value: 100
    )

    duplicate = CostMetric.new(
      date: Date.today,
      metric_type: :daily_tokens,
      value: 50
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:date], "has already been taken"
  end

  test ".total_for_month sums values correctly" do
    CostMetric.create!(
      date: Date.current.beginning_of_month,
      metric_type: :daily_tokens,
      value: 100
    )
    CostMetric.create!(
      date: Date.current,
      metric_type: :daily_tokens,
      value: 200
    )

    assert_equal 300, CostMetric.total_for_month(:daily_tokens)
  end

  test ".avg_for_month returns correct average" do
    CostMetric.create!(
      date: Date.current.beginning_of_month,
      metric_type: :aurora_acu_avg,
      value: 1.0
    )
    CostMetric.create!(
      date: Date.current,
      metric_type: :aurora_acu_avg,
      value: 3.0
    )

    assert_equal 2.0, CostMetric.avg_for_month(:aurora_acu_avg)
  end

  test ".avg_for_month returns 0 when no records exist" do
    assert_equal 0, CostMetric.avg_for_month(:daily_cost)
  end
end
