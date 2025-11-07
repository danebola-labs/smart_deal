class DocumentsController < ApplicationController
  before_action :authenticate_user!

  def create
    uploaded_file = params[:file]
    
    if uploaded_file.nil?
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "No file provided" })
      return
    end

    # Validar que sea un PDF
    unless uploaded_file.content_type == 'application/pdf' || uploaded_file.original_filename&.downcase&.end_with?('.pdf')
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "File must be a PDF" })
      return
    end

    begin
      # Extraer texto del PDF
      text = extract_text_from_pdf(uploaded_file)
      
      if text.strip.empty?
        render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Could not extract text from PDF. The file might be empty or corrupted." })
        return
      end
      
      # Procesar con IA (placeholder por ahora)
      summary = analyze_text(text)
      
      # Actualizar ambas secciones con Turbo Streams
      # Usamos 'update' en lugar de 'replace' para preservar los turbo-frames
      render turbo_stream: [
        turbo_stream.update("document_info", partial: "documents/info", locals: { 
          filename: uploaded_file.original_filename,
          file_size: uploaded_file.size
        }),
        turbo_stream.update("ai_summary", partial: "documents/summary", locals: { 
          summary: summary 
        })
      ]
    rescue PDF::Reader::MalformedPDFError => e
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Invalid PDF file: #{e.message}" })
    rescue => e
      Rails.logger.error "Error processing PDF: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render turbo_stream: turbo_stream.update("document_info", partial: "documents/error", locals: { message: "Error processing file: #{e.message}" })
    end
  end

  private

  def extract_text_from_pdf(file)
    require 'pdf-reader'
    
    # Crear un archivo temporal
    temp_file = Tempfile.new(['document', '.pdf'])
    temp_file.binmode
    temp_file.write(file.read)
    temp_file.rewind
    
    # Leer el PDF
    reader = PDF::Reader.new(temp_file.path)
    text = reader.pages.map(&:text).join(" ")
    
    # Limpiar archivo temporal
    temp_file.close
    temp_file.unlink
    
    text
  rescue => e
    raise "Error reading PDF: #{e.message}"
  end

  def analyze_text(text)
    # Limitar el texto a un máximo de caracteres para evitar límites de tokens
    max_chars = 100000
    truncated_text = text.length > max_chars ? text[0..max_chars] + "\n\n[... documento truncado por longitud ...]" : text
    
    # Crear el prompt para el análisis del documento
    prompt = "Eres un experto analista de documentos. Analiza y resume el documento de forma clara y concisa en español. Identifica los puntos principales, temas importantes y cualquier acción requerida.\n\nAnaliza este documento y proporciona un resumen detallado con los puntos principales:\n\n#{truncated_text}"
    
    begin
      # Usar AiProvider para obtener el resumen según el proveedor configurado
      ai_provider = AiProvider.new
      summary = ai_provider.query(prompt, max_tokens: 2000, temperature: 0.7)
      
      if summary.present?
        summary
      else
        "Error: No se pudo generar el resumen. Por favor, verifica la configuración de tu proveedor de IA."
      end
      
    rescue => e
      Rails.logger.error "Error procesando con IA: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Mensaje de error amigable según el tipo de error
      case e.message
      when /Unknown AI provider/
        "Error: Proveedor de IA no válido. Configura AI_PROVIDER con: bedrock, anthropic, geia o openai"
      when /not configured|not implemented/
        "⚠️ #{e.message}. Por favor, configura las credenciales necesarias en Rails credentials."
      else
        "Error al procesar con la IA: #{e.message}. Por favor, verifica tu configuración."
      end
    end
  end
end

