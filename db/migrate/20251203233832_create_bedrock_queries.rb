# frozen_string_literal: true

class CreateBedrockQueries < ActiveRecord::Migration[8.1]
  def change
    create_table :bedrock_queries do |t|
      t.string :model_id
      t.integer :input_tokens
      t.integer :output_tokens
      t.text :user_query
      t.integer :latency_ms

      t.timestamps
    end
  end
end
