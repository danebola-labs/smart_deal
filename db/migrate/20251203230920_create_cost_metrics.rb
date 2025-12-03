class CreateCostMetrics < ActiveRecord::Migration[7.1]
  def change
    create_table :cost_metrics do |t|
      t.date :date, null: false
      t.integer :metric_type, null: false
      t.decimal :value, precision: 12, scale: 6, null: false
      t.text :metadata, default: "{}"  # Compatible SQLite + PostgreSQL

      t.timestamps
    end

    add_index :cost_metrics, [:date, :metric_type], unique: true
    add_index :cost_metrics, :date
  end
end
