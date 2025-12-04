class DashboardController < ApplicationController
  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @chart_data = chart_data
  end

  def metrics
    render json: {
      current: current_metrics,
      monthly: monthly_totals,
      chart: chart_data,
      updated_at: Time.current.iso8601
    }
  end

  def refresh
    DailyMetricsJob.perform_later(Date.current)
    redirect_to dashboard_path, notice: "Métricas actualizándose..."
  end

  private

  def current_metrics
    today = Date.current

    {
      today_tokens: CostMetric.find_by(date: today, metric_type: :daily_tokens)&.value || 0,
      today_cost: CostMetric.find_by(date: today, metric_type: :daily_cost)&.value || 0,
      today_queries: CostMetric.find_by(date: today, metric_type: :daily_queries)&.value || 0,
      aurora_acu: CostMetric.find_by(date: today, metric_type: :aurora_acu_avg)&.value || 0,
      s3_documents: CostMetric.find_by(date: today, metric_type: :s3_documents_count)&.value || 0,
      s3_size_gb: (CostMetric.find_by(date: today, metric_type: :s3_total_size)&.value || 0) / 1.gigabyte
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

  def chart_data
    last_30 = CostMetric.last_30_days
                        .where(metric_type: :daily_cost)
                        .order(:date)
                        .pluck(:date, :value)

    {
      labels: last_30.map { |d, _| d.strftime("%m/%d") },
      values: last_30.map { |_, v| v.to_f }
    }
  end
end
