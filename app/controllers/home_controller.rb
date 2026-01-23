# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @s3_documents_list = S3DocumentsService.new.list_documents
  end

  def metrics
    render turbo_stream: turbo_stream.update("metrics-container", partial: "home/metrics", locals: { current_metrics: current_metrics })
  end
end
