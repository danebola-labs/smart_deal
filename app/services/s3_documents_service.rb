# app/services/s3_documents_service.rb
require "aws-sdk-s3"
require "aws-sdk-core/static_token_provider"

class S3DocumentsService
  include AwsClientInitializer

  def initialize
    client_options = build_aws_client_options
    @s3 = Aws::S3::Client.new(client_options)
    @bucket_name = find_bucket_name
  end

  # Returns array of document info hashes
  # @return [Array<Hash>] Array with keys: :name, :full_path, :size_mb, :size_bytes, :modified
  def list_documents
    return [] unless @bucket_name

    begin
      all_objects = []
      @s3.list_objects_v2(bucket: @bucket_name).each do |response|
        all_objects.concat(response.contents || [])
      end

      # Filter only real documents (exclude metadata, hidden files, directories)
      real_documents = all_objects.select do |obj|
        !obj.key.start_with?('.') && 
        !obj.key.include?('$folder$') &&
        !obj.key.end_with?('/') &&
        obj.size > 1024 # At least 1KB
      end

      # Return array of document info
      real_documents.map do |obj|
        {
          name: obj.key.split('/').last, # Just filename
          full_path: obj.key,
          size_mb: (obj.size / 1.megabyte.to_f).round(2),
          size_bytes: obj.size,
          modified: obj.last_modified
        }
      end.sort_by { |doc| -doc[:size_bytes] } # Sort by size, largest first
    rescue => e
      Rails.logger.error("Error fetching S3 documents list: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      []
    end
  end

  private

  def find_bucket_name
    ENV['KNOWLEDGE_BASE_S3_BUCKET'] ||
    Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
    Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
    'document-chatbot-generic-tech-info'
  end
end

