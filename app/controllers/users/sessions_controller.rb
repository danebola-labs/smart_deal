# frozen_string_literal: true

module Users
  class SessionsController < Devise::SessionsController
    respond_to :html, :turbo_stream

    def new
      # If this is a Turbo Stream request, redirect to HTML version
      # Turbo will handle the redirect automatically
      if request.format.turbo_stream?
        redirect_to new_user_session_path(format: :html), status: :see_other
        return
      end

      # For HTML requests, use the default behavior
      super
    end

    protected

    def auth_options
      { scope: resource_name, recall: "#{controller_path}#new" }
    end
  end
end
