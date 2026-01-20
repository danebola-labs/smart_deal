# frozen_string_literal: true

require 'test_helper'

class BedrockQueryTest < ActiveSupport::TestCase
  test 'requires model_id and tokens' do
    q = BedrockQuery.new
    assert_not q.valid?
    assert_includes q.errors[:model_id], "can't be blank"
    assert_includes q.errors[:input_tokens], "can't be blank"
    assert_includes q.errors[:output_tokens], "can't be blank"
  end

  test 'cost calculation works for known model' do
    q = BedrockQuery.new(
      model_id: 'anthropic.claude-3-haiku-20240307-v1:0',
      input_tokens: 1000,
      output_tokens: 2000
    )

    # input: 1000 → 1 * 0.00025 = 0.00025
    # output: 2000 → 2 * 0.00125 = 0.0025
    expected_cost = 0.00025 + 0.0025

    assert_equal expected_cost.round(6), q.cost
  end

  test 'cost calculation falls back to default model' do
    q = BedrockQuery.new(
      model_id: 'unknown-model',
      input_tokens: 1000,
      output_tokens: 1000
    )

    # default pricing: input=0.00025, output=0.00125 (Haiku pricing)
    expected_cost = (1 * 0.00025) + (1 * 0.00125)

    assert_equal expected_cost.round(6), q.cost
  end
end
