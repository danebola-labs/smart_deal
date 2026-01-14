class CostMetric < ApplicationRecord
    enum :metric_type, {
      daily_tokens: 0,
      daily_cost: 1,
      daily_queries: 2,
      aurora_acu_avg: 3,
      s3_documents_count: 4,
      s3_total_size: 5
    }
  
    # Ensure metric_type always returns a symbol
    def metric_type
      value = read_attribute(:metric_type)
      value.to_sym if value
    end
  
    validates :date, presence: true, uniqueness: { scope: :metric_type }
    validates :metric_type, presence: true
    validates :value, presence: true, numericality: true
  
    scope :current_month, -> { where(date: Date.current.beginning_of_month..Date.current) }
    scope :last_month, -> { 
      last_month_start = 1.month.ago.beginning_of_month
      last_month_end = 1.month.ago.end_of_month
      where(date: last_month_start..last_month_end)
    }
    scope :last_30_days, -> { where(date: 30.days.ago..Date.current) }
  
    def self.total_for_month(metric_type)
      current_month.where(metric_type: metric_type).sum(:value)
    end
  
    def self.avg_for_month(metric_type)
      current_month.where(metric_type: metric_type).average(:value) || 0
    end

    def self.total_for_last_month(metric_type)
      last_month.where(metric_type: metric_type).sum(:value)
    end

    def self.avg_for_last_month(metric_type)
      last_month.where(metric_type: metric_type).average(:value) || 0
    end
  end
  