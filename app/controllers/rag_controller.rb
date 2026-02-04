# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    result = execute_rag_query(params[:question])

    unless result.success?
      render_rag_json_error(result)
      return
    end

    render json: {
      answer: result.answer,
      citations: result.citations,
      session_id: result.session_id,
      status: 'success'
    }
  end
end
