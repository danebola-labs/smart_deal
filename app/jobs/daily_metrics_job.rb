class DailyMetricsJob < ApplicationJob
    queue_as :default
  
    def perform(date = Date.current)
      Rails.logger.info("Running DailyMetricsJob for #{date}")
      SimpleMetricsService.new(date).save_daily_metrics
    end
  end
  