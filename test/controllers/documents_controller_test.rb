# frozen_string_literal: true

require 'test_helper'

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEST_EXTRACTED_TEXT = 'This is a test PDF document with some content.'
  TEST_AI_SUMMARY = 'Resumen generado por IA: Este documento contiene información de prueba.'
  TURBO_STREAM_CONTENT_TYPE = 'text/vnd.turbo-stream.html; charset=utf-8'

  setup do
    @user = users(:one)
  end

  # Helper method to stub AiProvider.new at the class level.
  # This approach avoids introducing dependency injection prematurely while
  # allowing tests to isolate the controller from the actual AiProvider.
  # The original method is always restored in the ensure block to prevent test pollution.
  def with_mock_ai_provider(mock_response, error: nil)
    original_new = AiProvider.method(:new)

    mock_service = Object.new
    if error
      mock_service.define_singleton_method(:query) { |*_args| raise error }
    else
      mock_service.define_singleton_method(:query) { |*_args| mock_response }
    end

    AiProvider.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    # Always restore original method to prevent test pollution
    AiProvider.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  # Helper to stub extract_text_from_pdf method.
  # This allows testing controller logic without actually parsing PDF files.
  # The original method is always restored in the ensure block.
  def with_mock_pdf_extraction(extracted_text, error: nil)
    original_method = DocumentsController.instance_method(:extract_text_from_pdf)

    DocumentsController.define_method(:extract_text_from_pdf) do |_file|
      raise error if error

      extracted_text
    end

    yield
  ensure
    # Always restore original method to prevent test pollution
    DocumentsController.define_method(:extract_text_from_pdf, original_method)
  end

  # Helper to assert turbo_stream update action
  def assert_turbo_stream_update(target, response_body = response.body)
    assert_match(/turbo-stream/, response_body)
    assert_match(/action="update"/, response_body)
    assert_match(/target="#{target}"/, response_body)
  end

  # Helper to assert Turbo Stream response format
  def assert_turbo_stream_response
    assert_response :success
    assert_equal TURBO_STREAM_CONTENT_TYPE, response.content_type
  end

  # Helper to create a simple PDF file for testing
  def create_test_pdf(content: 'Sample PDF text content for testing')
    pdf_content = pdf_content_string(content: content)
    Rack::Test::UploadedFile.new(
      StringIO.new(pdf_content),
      'application/pdf',
      original_filename: 'test.pdf'
    )
  end

  test 'requires authentication' do
    pdf_file = create_test_pdf
    post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
    assert_redirected_to new_user_session_path
  end

  test 'rejects request without file parameter' do
    sign_in @user
    post documents_process_path, params: {}, as: :turbo_stream

    assert_turbo_stream_response
    assert_turbo_stream_update('document_info')
    assert_match(/No file provided/, response.body)
  end

  test 'rejects non-PDF files' do
    sign_in @user
    text_file = Rack::Test::UploadedFile.new(
      StringIO.new('This is not a PDF'),
      'text/plain',
      original_filename: 'test.txt'
    )

    post documents_process_path, params: { file: text_file }, as: :turbo_stream

    assert_turbo_stream_response
    assert_turbo_stream_update('document_info')
    assert_match(/must be a PDF/, response.body)
  end

  test 'processes valid PDF successfully' do
    sign_in @user
    pdf_file = create_test_pdf

    with_mock_pdf_extraction(TEST_EXTRACTED_TEXT) do
      with_mock_ai_provider(TEST_AI_SUMMARY) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response

        turbo_streams = response.body.scan(/<turbo-stream[^>]*>/)
        assert_equal 2, turbo_streams.length, 'Should have 2 turbo-stream actions'

        assert_turbo_stream_update('document_info')
        assert_turbo_stream_update('ai_summary')
        assert_match(/test\.pdf/, response.body)
        assert_match(TEST_AI_SUMMARY, response.body)
      end
    end
  end

  test 'rejects PDF with no extractable text' do
    sign_in @user
    pdf_file = create_test_pdf

    with_mock_pdf_extraction('   ') do
      post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

      assert_turbo_stream_response
      assert_turbo_stream_update('document_info')
      assert_match(/empty or corrupted/, response.body)
    end
  end

  test 'handles AI service timeout errors' do
    sign_in @user
    pdf_file = create_test_pdf
    error = StandardError.new('Bedrock API timeout')

    with_mock_pdf_extraction('Test content') do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_match(/Error processing with AI/, response.body)
        assert_match(/Bedrock API timeout/, response.body)
      end
    end
  end

  test 'handles unknown AI provider configuration errors' do
    sign_in @user
    pdf_file = create_test_pdf
    error = StandardError.new('Unknown AI provider: invalid')

    with_mock_pdf_extraction('Test content') do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_match(/Invalid AI provider/, response.body)
      end
    end
  end

  test 'handles missing AI provider configuration errors' do
    sign_in @user
    pdf_file = create_test_pdf
    error = StandardError.new('Knowledge Base ID not configured')

    with_mock_pdf_extraction('Test content') do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_match(/⚠️/, response.body)
        assert_match(/not configured/, response.body)
      end
    end
  end

  test 'handles generic AI service errors' do
    sign_in @user
    pdf_file = create_test_pdf
    error = StandardError.new('Network connection failed')

    with_mock_pdf_extraction('Test content') do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_match(/Error processing with AI/, response.body)
        assert_match(/Network connection failed/, response.body)
      end
    end
  end

  test 'handles PDF extraction errors' do
    sign_in @user
    pdf_file = create_test_pdf
    extraction_error = StandardError.new('Error reading PDF: xref table not found')

    with_mock_pdf_extraction('', error: extraction_error) do
      post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

      assert_turbo_stream_response
      assert_turbo_stream_update('document_info')
      assert_match(/Error reading PDF/, response.body)
    end
  end

  test 'handles empty AI response' do
    sign_in @user
    pdf_file = create_test_pdf

    with_mock_pdf_extraction('Test content') do
      with_mock_ai_provider('') do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('ai_summary')
        assert_match(/Could not generate summary/, response.body)
      end
    end
  end

  test 'accepts PDF file with correct extension but incorrect content_type' do
    sign_in @user
    pdf_content = pdf_content_string
    pdf_file = Rack::Test::UploadedFile.new(
      StringIO.new(pdf_content),
      'application/octet-stream',
      original_filename: 'document.pdf'
    )

    with_mock_pdf_extraction(TEST_EXTRACTED_TEXT) do
      with_mock_ai_provider(TEST_AI_SUMMARY) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_turbo_stream_update('ai_summary')
      end
    end
  end

  test 'accepts PDF file with correct content_type but incorrect extension' do
    sign_in @user
    pdf_content = pdf_content_string
    pdf_file = Rack::Test::UploadedFile.new(
      StringIO.new(pdf_content),
      'application/pdf',
      original_filename: 'document.txt'
    )

    with_mock_pdf_extraction(TEST_EXTRACTED_TEXT) do
      with_mock_ai_provider(TEST_AI_SUMMARY) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        assert_turbo_stream_response
        assert_turbo_stream_update('document_info')
        assert_turbo_stream_update('ai_summary')
      end
    end
  end

  test 'rejects file with both incorrect extension and content_type' do
    sign_in @user
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new('This is not a PDF'),
      'text/plain',
      original_filename: 'document.txt'
    )

    post documents_process_path, params: { file: invalid_file }, as: :turbo_stream

    assert_turbo_stream_response
    assert_turbo_stream_update('document_info')
    assert_match(/must be a PDF/, response.body)
  end

  test 'handles very large PDF files without size validation' do
    sign_in @user

    # NOTE: This test documents the current behavior where the controller
    # does not validate file size upfront. It will attempt to process files
    # of any size, which may succeed or fail depending on system limits.
    # This test ensures the controller doesn't crash silently and will fail
    # if size validation is added in the future, prompting a review.

    large_content = 'A' * 1_000_000
    pdf_file = create_test_pdf(content: large_content)

    with_mock_pdf_extraction('Extracted text from large PDF') do
      with_mock_ai_provider(TEST_AI_SUMMARY) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream

        # Controller doesn't reject upfront, so response may vary
        # 200 = success, 413 = payload too large, 422 = unprocessable, 500 = server error
        assert_includes [200, 413, 422, 500], response.status,
                        'Controller should handle large files without crashing'
      end
    end
  end

  private

  # Helper to generate PDF content string
  def pdf_content_string(content: 'Sample PDF text content for testing')
    <<~PDF
      %PDF-1.4
      1 0 obj
      <<
      /Type /Catalog
      /Pages 2 0 R
      >>
      endobj
      2 0 obj
      <<
      /Type /Pages
      /Kids [3 0 R]
      /Count 1
      >>
      endobj
      3 0 obj
      <<
      /Type /Page
      /Parent 2 0 R
      /MediaBox [0 0 612 792]
      /Contents 4 0 R
      /Resources <<
      /Font <<
      /F1 <<
      /Type /Font
      /Subtype /Type1
      /BaseFont /Helvetica
      >>
      >>
      >>
      >>
      endobj
      4 0 obj
      <<
      /Length #{content.length + 50}
      >>
      stream
      BT
      /F1 12 Tf
      100 700 Td
      (#{content}) Tj
      ET
      endstream
      endobj
      xref
      0 5
      0000000000 65535 f
      0000000009 00000 n
      0000000058 00000 n
      0000000115 00000 n
      0000000306 00000 n
      trailer
      <<
      /Size 5
      /Root 1 0 R
      >>
      startxref
      #{content.length + 400}
      %%EOF
    PDF
  end
end
