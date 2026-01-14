class HomeController < ApplicationController
  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @s3_documents_list = S3DocumentsService.new.list_documents
  end

  private

  def current_metrics
    today = Date.current
    s3_size_bytes = CostMetric.find_by(date: today, metric_type: :s3_total_size)&.value || 0

    {
      today_tokens: CostMetric.find_by(date: today, metric_type: :daily_tokens)&.value || 0,
      today_cost: CostMetric.find_by(date: today, metric_type: :daily_cost)&.value || 0,
      today_queries: CostMetric.find_by(date: today, metric_type: :daily_queries)&.value || 0,
      aurora_acu: CostMetric.find_by(date: today, metric_type: :aurora_acu_avg)&.value || 0,
      s3_documents: CostMetric.find_by(date: today, metric_type: :s3_documents_count)&.value || 0,
      s3_size_mb: (s3_size_bytes / 1.megabyte.to_f).round(2),
      s3_size_gb: (s3_size_bytes / 1.gigabyte.to_f).round(2)
    }
  end

  def monthly_totals
    {
      total_tokens: CostMetric.total_for_month(:daily_tokens),
      total_cost: CostMetric.total_for_month(:daily_cost),
      total_queries: CostMetric.total_for_month(:daily_queries),
      avg_acu: CostMetric.avg_for_month(:aurora_acu_avg).round(2)
    }
  end

end

