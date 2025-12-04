class BedrockQuery < ApplicationRecord
    validates :model_id, :input_tokens, :output_tokens, presence: true
    validates :input_tokens, numericality: { greater_than: 0 }
    validates :output_tokens, numericality: { greater_than_or_equal_to: 0 }
  
  BEDROCK_PRICING = {
    "anthropic.claude-3-5-sonnet-20241022-v2:0" => { input: 0.003,   output: 0.015 },
    "anthropic.claude-3-sonnet-20240229-v1:0"   => { input: 0.003,   output: 0.015 },
    "anthropic.claude-3-haiku-20240307-v1:0"    => { input: 0.00025, output: 0.00125 },
    "amazon.titan-embed-text-v1"                 => { input: 0.0001,  output: 0.0 },
    "default"                                    => { input: 0.00025, output: 0.00125 } # Default to Haiku for cost optimization
  }.freeze
  
    def cost
      pricing = BEDROCK_PRICING[model_id] || BEDROCK_PRICING["default"]
      input_cost  = (input_tokens  / 1000.0) * pricing[:input]
      output_cost = (output_tokens / 1000.0) * pricing[:output]
      (input_cost + output_cost).round(6)
    end
  end
  