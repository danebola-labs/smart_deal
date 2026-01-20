# frozen_string_literal: true

class DailyMetricsJob < ApplicationJob
  queue_as :default

  def perform(date = Date.current)
    # Observabilidad temporal: rastrear ejecuciones para análisis de uso
    execution_context = caller_locations(1, 3).map(&:to_s).join(' <- ')
    Rails.logger.info("[DailyMetricsJob] Starting execution for #{date}")
    Rails.logger.info("[DailyMetricsJob] Execution context: #{execution_context}")
    Rails.logger.info("[DailyMetricsJob] Job ID: #{job_id}, Queue: #{queue_name}")

    start_time = Time.current
    SimpleMetricsService.new(date).save_daily_metrics
    duration = Time.current - start_time

    Rails.logger.info("[DailyMetricsJob] Completed successfully for #{date} in #{duration.round(2)}s")
  end
end
