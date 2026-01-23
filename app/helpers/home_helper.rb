# frozen_string_literal: true

module HomeHelper
  def total_storage_mb(documents)
    return 0 if documents.empty?

    total_bytes = documents.sum { |doc| doc[:size_bytes] || 0 }
    (total_bytes / 1.megabyte.to_f).round(2)
  end

  def format_document_date(modified)
    return "N/A" unless modified

    modified.strftime("%Y-%m-%d %H:%M")
  end
end
