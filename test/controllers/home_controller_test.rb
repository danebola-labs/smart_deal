# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  TURBO_STREAM_CONTENT_TYPE = 'text/vnd.turbo-stream.html; charset=utf-8'

  setup do
    CostMetric.destroy_all
    BedrockQuery.destroy_all
  end

  def with_mock_s3_documents_service(mock_documents)
    original_new = S3DocumentsService.method(:new)
    mock_service = Object.new
    mock_service.define_singleton_method(:list_documents) { mock_documents }
    S3DocumentsService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  test 'should get index' do
    get root_path
    assert_response :success
  end

  test 'should render index with metrics' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 1000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 10)

    get root_path
    assert_response :success
    assert_select '.metrics-group', minimum: 1
  end

  test 'should render index without metrics' do
    get root_path
    assert_response :success
  end

  test 'should render metrics as turbo_stream' do
    get '/home/metrics'
    assert_response :success
    assert_equal TURBO_STREAM_CONTENT_TYPE, response.content_type
    assert_match(/turbo-stream/, response.body)
    assert_match(/action="update"/, response.body)
    assert_match(/target="metrics-container"/, response.body)
  end

  test 'metrics turbo_stream should include metrics partial' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 5000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 25)

    get '/home/metrics'
    assert_response :success
    assert_match(/metrics-group/, response.body)
  end
end
