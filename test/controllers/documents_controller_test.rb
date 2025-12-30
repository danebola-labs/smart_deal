require "test_helper"

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
  end

  # Helper method to stub AiProvider.new
  def with_mock_ai_provider(mock_response, error: nil)
    original_new = AiProvider.method(:new)
    
    # Capture variables in closure
    response_value = mock_response
    error_value = error
    
    mock_service = Object.new
    if error_value
      mock_service.define_singleton_method(:query) do |*args|
        raise error_value
      end
    else
      mock_service.define_singleton_method(:query) do |*args|
        response_value
      end
    end
    
    AiProvider.define_singleton_method(:new) { |*args| mock_service }
    yield
  ensure
    # Restore original method
    if original_new
      AiProvider.define_singleton_method(:new) { |*args| original_new.call(*args) }
    end
  end

  # Helper to stub extract_text_from_pdf method
  def with_mock_pdf_extraction(extracted_text, error: nil)
    original_method = DocumentsController.instance_method(:extract_text_from_pdf)
    
    DocumentsController.define_method(:extract_text_from_pdf) do |file|
      if error
        raise error
      else
        extracted_text
      end
    end
    
    yield
  ensure
    # Restore original method
    if original_method
      DocumentsController.define_method(:extract_text_from_pdf, original_method)
    end
  end

  # Helper to assert turbo_stream update action
  def assert_turbo_stream_update(target, response_body = response.body)
    assert_match(/turbo-stream/, response_body)
    assert_match(/action="update"/, response_body)
    assert_match(/target="#{target}"/, response_body)
  end

  # Helper to create a simple PDF file for testing
  def create_test_pdf(content: "Sample PDF text content for testing")
    # Create a minimal valid PDF structure
    pdf_content = <<~PDF
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

    # Use Rack::Test::UploadedFile which is the standard way for integration tests
    Rack::Test::UploadedFile.new(
      StringIO.new(pdf_content),
      'application/pdf',
      original_filename: 'test.pdf'
    )
  end

  test "requires authentication" do
    pdf_file = create_test_pdf
    post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
    # Devise redirects to login for HTML/Turbo Stream requests
    assert_redirected_to new_user_session_path
  end

  test "rejects request without file parameter" do
    sign_in @user
    post documents_process_path, params: {}, as: :turbo_stream
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_turbo_stream_update("document_info")
    assert_match(/No file provided/, response.body)
  end

  test "rejects non-PDF files" do
    sign_in @user
    
    # Create a text file using Rack::Test::UploadedFile
    text_file = Rack::Test::UploadedFile.new(
      StringIO.new("This is not a PDF"),
      'text/plain',
      original_filename: 'test.txt'
    )
    
    post documents_process_path, params: { file: text_file }, as: :turbo_stream
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_turbo_stream_update("document_info")
    assert_match(/must be a PDF/, response.body)
  end

  test "processes valid PDF successfully" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "This is a test PDF document with some content."
    mock_summary = "Resumen generado por IA: Este documento contiene información de prueba."
    
    with_mock_pdf_extraction(extracted_text) do
      with_mock_ai_provider(mock_summary) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
        
        # Should have 2 turbo-stream actions
        turbo_streams = response.body.scan(/<turbo-stream[^>]*>/)
        assert_equal 2, turbo_streams.length, "Should have 2 turbo-stream actions"
        
        # Verify both targets are updated
        assert_turbo_stream_update("document_info")
        assert_turbo_stream_update("ai_summary")
        
        # Verify content
        assert_match(/test\.pdf/, response.body)
        assert_match(mock_summary, response.body)
      end
    end
  end

  test "rejects PDF with no extractable text" do
    sign_in @user
    
    pdf_file = create_test_pdf
    # Mock extraction to return only whitespace
    with_mock_pdf_extraction("   ") do
      post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
      
      assert_response :success
      assert_turbo_stream_update("document_info")
      assert_match(/empty or corrupted/, response.body)
    end
  end

  test "handles AI service errors gracefully" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "Test content"
    error = StandardError.new("Bedrock API timeout")
    
    with_mock_pdf_extraction(extracted_text) do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        assert_turbo_stream_update("document_info")
        assert_match(/Error processing with AI/, response.body)
        assert_match(/Bedrock API timeout/, response.body)
      end
    end
  end

  test "handles unknown AI provider error" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "Test content"
    error = StandardError.new("Unknown AI provider: invalid")
    
    with_mock_pdf_extraction(extracted_text) do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        assert_turbo_stream_update("document_info")
        # The analyze_text method should catch this and return a user-friendly message
        assert_match(/Invalid AI provider/, response.body)
      end
    end
  end

  test "handles not configured error" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "Test content"
    error = StandardError.new("Knowledge Base ID not configured")
    
    with_mock_pdf_extraction(extracted_text) do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        assert_turbo_stream_update("document_info")
        # Should show the warning emoji and message
        assert_match(/⚠️/, response.body)
        assert_match(/not configured/, response.body)
      end
    end
  end

  test "handles generic AI errors" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "Test content"
    error = StandardError.new("Network connection failed")
    
    with_mock_pdf_extraction(extracted_text) do
      with_mock_ai_provider(nil, error: error) do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        assert_turbo_stream_update("document_info")
        assert_match(/Error processing with AI/, response.body)
        assert_match(/Network connection failed/, response.body)
      end
    end
  end

  test "handles PDF extraction errors" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extraction_error = StandardError.new("Error reading PDF: xref table not found")
    
    # Mock extraction to raise an error
    with_mock_pdf_extraction("", error: extraction_error) do
      post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
      
      # Should handle the error gracefully
      assert_response :success
      assert_turbo_stream_update("document_info")
      # Should show an error message
      assert_match(/Error/, response.body)
      assert_match(/Error reading PDF/, response.body)
    end
  end

  test "handles empty AI response" do
    sign_in @user
    
    pdf_file = create_test_pdf
    extracted_text = "Test content"
    
    with_mock_pdf_extraction(extracted_text) do
      # Mock AI provider to return empty string
      with_mock_ai_provider("") do
        post documents_process_path, params: { file: pdf_file }, as: :turbo_stream
        
        assert_response :success
        # Should still render the summary partial, but with error message
        assert_turbo_stream_update("ai_summary")
        assert_match(/Could not generate summary/, response.body)
      end
    end
  end
end

