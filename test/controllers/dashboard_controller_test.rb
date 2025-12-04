require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest

  test "should get index" do
    get dashboard_url
    assert_response :success
  end

  test "should return metrics as JSON" do
    get dashboard_metrics_url, as: :json
    assert_response :success

    json = JSON.parse(@response.body)
    assert json.key?("current")
    assert json.key?("monthly")
    assert json.key?("chart")
  end

  test "should enqueue refresh job" do
    assert_enqueued_with(job: DailyMetricsJob) do
      post dashboard_refresh_url
    end
  end
end
