# frozen_string_literal: true

# app/controllers/concerns/authentication_concern.rb
module AuthenticationConcern
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!
  end
end
