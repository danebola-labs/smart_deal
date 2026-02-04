# frozen_string_literal: true

class TwilioController < ApplicationController
  include RagQueryConcern

  skip_before_action :verify_authenticity_token

  def webhook
    message_body = params['Body']
    # from_number = params['From'] # Available for future use (logging, user tracking, etc.)

    result = execute_rag_query(message_body)
    rag_response = format_rag_response_for_whatsapp(result)

    response = Twilio::TwiML::MessagingResponse.new
    response.message { |m| m.body(rag_response) }

    render xml: response.to_s
  end
end
