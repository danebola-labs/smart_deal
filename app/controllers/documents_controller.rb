# frozen_string_literal: true

class DocumentsController < ApplicationController
  include AuthenticationConcern

  def create
    uploaded_file = params[:file]

    if uploaded_file.nil?
      render turbo_stream: turbo_stream.update('document_info', partial: 'documents/error',
                                                                locals: { message: 'No file provided' })
      return
    end

    # Validate that it's a PDF
    unless uploaded_file.content_type == 'application/pdf' || uploaded_file.original_filename&.downcase&.end_with?('.pdf')
      render turbo_stream: turbo_stream.update('document_info', partial: 'documents/error',
                                                                locals: { message: 'File must be a PDF' })
      return
    end

    begin
      # Extract text from PDF
      text = extract_text_from_pdf(uploaded_file)

      if text.strip.empty?
        render turbo_stream: turbo_stream.update('document_info', partial: 'documents/error',
                                                                  locals: { message: 'Could not extract text from PDF. The file might be empty or corrupted.' })
        return
      end

      # Process with AI
      summary = analyze_text(text)

      # Update both sections with Turbo Streams
      # Use 'update' instead of 'replace' to preserve turbo-frames
      render turbo_stream: [
        turbo_stream.update('document_info', partial: 'documents/info', locals: {
                              filename: uploaded_file.original_filename,
                              file_size: uploaded_file.size
                            }),
        turbo_stream.update('ai_summary', partial: 'documents/summary', locals: {
                              summary: summary
                            })
      ]
    rescue PDF::Reader::MalformedPDFError => e
      render turbo_stream: turbo_stream.update('document_info', partial: 'documents/error',
                                                                locals: { message: "Invalid PDF file: #{e.message}" })
    rescue StandardError => e
      Rails.logger.error "Error processing PDF: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render turbo_stream: turbo_stream.update('document_info', partial: 'documents/error',
                                                                locals: { message: "Error processing file: #{e.message}" })
    end
  end

  private

  def extract_text_from_pdf(file)
    require 'pdf-reader'

    # Create a temporary file
    temp_file = Tempfile.new(['document', '.pdf'])
    temp_file.binmode
    temp_file.write(file.read)
    temp_file.rewind

    # Read the PDF
    reader = PDF::Reader.new(temp_file.path)
    text = reader.pages.map(&:text).join(' ')

    # Clean up temporary file
    temp_file.close
    temp_file.unlink

    text
  rescue StandardError => e
    raise "Error reading PDF: #{e.message}"
  end

  def analyze_text(text)
    # Limit text to maximum characters to avoid token limits
    max_chars = 100_000
    truncated_text = text.length > max_chars ? "#{text[0..max_chars]}\n\n[... document truncated due to length ...]" : text

    # Create the prompt for document analysis
    prompt = "You are an expert document analyst. Analyze and summarize the document clearly and concisely in Spanish. Identify the main points, important topics, and any required actions.\n\nAnalyze this document and provide a detailed summary with the main points:\n\n#{truncated_text}"

    begin
      # Use AiProvider to get the summary according to the configured provider
      ai_provider = AiProvider.new
      summary = ai_provider.query(prompt, max_tokens: 2000, temperature: 0.7)

      summary.presence || 'Error: Could not generate summary. Please verify your AI provider configuration.'
    rescue StandardError => e
      Rails.logger.error "Error processing with AI: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      # User-friendly error message based on error type
      case e.message
      when /Unknown AI provider/
        'Error: Invalid AI provider. Configure AI_PROVIDER with: bedrock, anthropic, geia or openai'
      when /not configured|not implemented/
        "⚠️ #{e.message}. Please configure the required credentials in Rails credentials."
      else
        "Error processing with AI: #{e.message}. Please verify your configuration."
      end
    end
  end
end
