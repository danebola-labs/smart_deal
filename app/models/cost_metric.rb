class CostMetric < ApplicationRecord
    enum :metric_type, {
      daily_tokens: 0,
      daily_cost: 1,
      daily_queries: 2,
      aurora_acu_avg: 3,
      s3_documents_count: 4,
      s3_total_size: 5
    }
  
    validates :date, presence: true, uniqueness: { scope: :metric_type }
    validates :metric_type, presence: true
    validates :value, presence: true, numericality: true
  
    scope :current_month, -> { where(date: Date.current.beginning_of_month..Date.current) }
    scope :last_30_days, -> { where(date: 30.days.ago..Date.current) }
  
    def self.total_for_month(metric_type)
      current_month.where(metric_type: metric_type).sum(:value)
    end
  
    def self.avg_for_month(metric_type)
      current_month.where(metric_type: metric_type).average(:value) || 0
    end
  end
  