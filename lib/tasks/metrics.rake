namespace :metrics do
  desc "Create sample BedrockQuery for testing"
  task :create_sample_query, [:model_id, :input_tokens, :output_tokens] => :environment do |_t, args|
    model_id = args[:model_id] || "anthropic.claude-3-5-sonnet-20241022-v2:0"
    input_tokens = (args[:input_tokens] || 100).to_i
    output_tokens = (args[:output_tokens] || 50).to_i
    
    query = BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: "Sample query for testing",
      created_at: Time.current
    )
    
    puts "✓ Created BedrockQuery:"
    puts "  ID: #{query.id}"
    puts "  Model: #{query.model_id}"
    puts "  Input tokens: #{query.input_tokens}"
    puts "  Output tokens: #{query.output_tokens}"
    puts "  Cost: $#{query.cost}"
    puts "  Created at: #{query.created_at}"
  end

  desc "Collect metrics for last month (all days)"
  task collect_last_month: :environment do
    last_month_start = 1.month.ago.beginning_of_month
    last_month_end = 1.month.ago.end_of_month
    
    puts "Collecting metrics from #{last_month_start} to #{last_month_end}"
    
    (last_month_start..last_month_end).each do |date|
      puts "Processing #{date}..."
      begin
        SimpleMetricsService.new(date).save_daily_metrics
        puts "  ✓ Metrics saved for #{date}"
      rescue => e
        puts "  ✗ Error for #{date}: #{e.message}"
      end
    end
    
    puts "Done! Collected metrics for last month."
  end

  desc "Collect metrics for a specific date (defaults to today)"
  task :collect, [:date] => :environment do |_t, args|
    date = args[:date] ? Date.parse(args[:date]) : Date.current
    puts "Collecting metrics for #{date}..."
    
    begin
      SimpleMetricsService.new(date).save_daily_metrics
      puts "✓ Metrics saved for #{date}"
    rescue => e
      puts "✗ Error: #{e.message}"
      raise
    end
  end

  desc "Collect metrics for a date range"
  task :collect_range, [:start_date, :end_date] => :environment do |_t, args|
    start_date = Date.parse(args[:start_date])
    end_date = Date.parse(args[:end_date])
    
    puts "Collecting metrics from #{start_date} to #{end_date}"
    
    (start_date..end_date).each do |date|
      puts "Processing #{date}..."
      begin
        SimpleMetricsService.new(date).save_daily_metrics
        puts "  ✓ Metrics saved for #{date}"
      rescue => e
        puts "  ✗ Error for #{date}: #{e.message}"
      end
    end
    
    puts "Done! Collected metrics for the specified range."
  end
end

namespace :debug do
  desc "Verify a specific S3 bucket"
  task :verify_bucket, [:bucket_name] => :environment do |_t, args|
    require "aws-sdk-s3"
    require "aws-sdk-core/static_token_provider"
    
    bucket_name = args[:bucket_name]
    unless bucket_name
      puts "❌ Please provide a bucket name: rails debug:verify_bucket[BUCKET_NAME]"
      exit 1
    end
    
    # Use same AWS configuration pattern as SimpleMetricsService
    region = Rails.application.credentials.dig(:aws, :region) || 
             ENV.fetch("AWS_REGION", "us-east-1")
    
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                   ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                   ENV["AWS_BEDROCK_BEARER_TOKEN"]
    
    client_options = { region: region }
    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end
    
    s3 = Aws::S3::Client.new(client_options)
    
    puts "🔍 Verifying bucket: #{bucket_name}"
    puts "=" * 50
    
    begin
      # Check if bucket exists and is accessible
      s3.head_bucket(bucket: bucket_name)
      puts "✅ Bucket exists and is accessible"
      
      # Get bucket details
      puts "\n📊 Bucket Details:"
      
      # Count objects (with pagination)
      total_count = 0
      total_size = 0
      continuation_token = nil
      sample_objects = []
      
      loop do
        params = { bucket: bucket_name, max_keys: 1000 }
        params[:continuation_token] = continuation_token if continuation_token
        
        resp = s3.list_objects_v2(params)
        batch_count = resp.contents&.count || 0
        batch_size = resp.contents&.sum(&:size) || 0
        
        total_count += batch_count
        total_size += batch_size
        
        # Collect sample objects (first 10)
        if sample_objects.count < 10 && resp.contents&.any?
          sample_objects.concat(resp.contents.first(10 - sample_objects.count))
        end
        
        continuation_token = resp.next_continuation_token
        break unless continuation_token
      end
      
      puts "  Total objects: #{total_count}"
      puts "  Total size: #{number_to_human_size(total_size)}"
      
      if sample_objects.any?
        puts "\n📄 Sample objects (first #{sample_objects.count}):"
        sample_objects.each do |obj|
          size_str = number_to_human_size(obj.size)
          modified = obj.last_modified ? obj.last_modified.strftime("%Y-%m-%d %H:%M:%S") : "N/A"
          puts "  - #{obj.key} (#{size_str}, modified: #{modified})"
        end
      end
      
      # Check if it looks like a Knowledge Base bucket
      puts "\n🔍 Knowledge Base Analysis:"
      kb_indicators = []
      
      if bucket_name.downcase.include?('bedrock') || 
         bucket_name.downcase.include?('knowledge') || 
         bucket_name.downcase.include?('kb') ||
         bucket_name.downcase.include?('document') ||
         bucket_name.downcase.include?('chatbot')
        kb_indicators << "✅ Bucket name suggests Knowledge Base"
      end
      
      if total_count > 0
        kb_indicators << "✅ Contains #{total_count} objects"
      else
        kb_indicators << "⚠️  Empty bucket"
      end
      
      if total_size > 0
        kb_indicators << "✅ Contains #{number_to_human_size(total_size)} of data"
      end
      
      kb_indicators.each { |indicator| puts "  #{indicator}" }
      
      puts "\n💡 Recommendation:"
      if kb_indicators.count { |i| i.start_with?('✅') } >= 2
        puts "  ✅ This looks like a valid Knowledge Base bucket!"
        puts "  Add to your environment:"
        puts "  KNOWLEDGE_BASE_S3_BUCKET=#{bucket_name}"
      else
        puts "  ⚠️  This might not be the Knowledge Base bucket"
        puts "  Run 'rails debug:find_kb_bucket' to search for other options"
      end
      
    rescue Aws::S3::Errors::NotFound
      puts "❌ Bucket does not exist: #{bucket_name}"
    rescue Aws::S3::Errors::AccessDenied => e
      puts "❌ Access denied to bucket: #{bucket_name}"
      puts "   Error: #{e.message}"
      puts "   Check your IAM permissions"
    rescue => e
      puts "❌ Error accessing bucket: #{e.message}"
      puts e.backtrace.first(5).join("\n")
    end
    
    puts "=" * 50
  end

  desc "Find Knowledge Base S3 bucket"
  task find_kb_bucket: :environment do
    require "aws-sdk-s3"
    require "aws-sdk-core/static_token_provider"
    
    # Use same AWS configuration pattern as SimpleMetricsService
    region = Rails.application.credentials.dig(:aws, :region) || 
             ENV.fetch("AWS_REGION", "us-east-1")
    
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                   ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                   ENV["AWS_BEDROCK_BEARER_TOKEN"]
    
    client_options = { region: region }
    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end
    
    s3 = Aws::S3::Client.new(client_options)
    
    puts "🔍 Searching for Knowledge Base buckets..."
    
    begin
      buckets = s3.list_buckets.buckets
      kb_buckets = []
      
      buckets.each do |bucket|
        bucket_name = bucket.name
        
        # Search for buckets related to Knowledge Base
        if bucket_name.downcase.include?('bedrock') || 
           bucket_name.downcase.include?('knowledge') || 
           bucket_name.downcase.include?('kb') ||
           bucket_name.downcase.include?('amfskkpezn')
          
          puts "📁 Found potential KB bucket: #{bucket_name}"
          
          begin
            # Check content
            objects = s3.list_objects_v2(bucket: bucket_name, max_keys: 10)
            object_count = objects.contents&.count || 0
            puts "   📄 Objects: #{object_count}"
            
            if objects.contents&.any?
              objects.contents.first(5).each do |obj|
                size_str = number_to_human_size(obj.size)
                puts "     - #{obj.key} (#{size_str})"
              end
              puts "     ..." if object_count > 5
            end
            
            # Get total count and size (with pagination)
            total_count = 0
            total_size = 0
            continuation_token = nil
            
            loop do
              params = { bucket: bucket_name }
              params[:continuation_token] = continuation_token if continuation_token
              
              resp = s3.list_objects_v2(params)
              batch_count = resp.contents&.count || 0
              batch_size = resp.contents&.sum(&:size) || 0
              
              total_count += batch_count
              total_size += batch_size
              
              continuation_token = resp.next_continuation_token
              break unless continuation_token
            end
            
            kb_buckets << {
              name: bucket_name,
              object_count: total_count,
              total_size: total_size
            }
            
          rescue Aws::S3::Errors::AccessDenied
            puts "   ❌ Access denied to #{bucket_name}"
          rescue => e
            puts "   ❌ Error accessing #{bucket_name}: #{e.message}"
          end
          
          puts ""
        end
      end
      
      if kb_buckets.any?
        puts "✅ Knowledge Base buckets found:"
        kb_buckets.each do |bucket|
          size_str = number_to_human_size(bucket[:total_size])
          puts "   #{bucket[:name]}: #{bucket[:object_count]} objects, #{size_str}"
        end
        
        # Suggest the bucket with most objects
        best_bucket = kb_buckets.max_by { |b| b[:object_count] }
        puts "\n💡 Suggested bucket: #{best_bucket[:name]}"
        puts "Add this to your environment variables:"
        puts "KNOWLEDGE_BASE_S3_BUCKET=#{best_bucket[:name]}"
      else
        puts "❌ No Knowledge Base buckets found"
        puts "Make sure your AWS credentials have permission to list buckets"
      end
    rescue => e
      puts "❌ Error listing buckets: #{e.message}"
      puts e.backtrace.first(5).join("\n")
    end
  end
  
  def number_to_human_size(size)
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    unit = 0
    while size >= 1024 && unit < units.length - 1
      size /= 1024.0
      unit += 1
    end
    "#{size.round(2)} #{units[unit]}"
  end

  desc "Complete debug of all services"
  task complete: :environment do
    puts "🔍 COMPLETE DEBUG ANALYSIS"
    puts "=" * 50

    # 1. Bedrock Queries
    puts "\n📊 BEDROCK QUERIES:"
    today_queries = BedrockQuery.where(created_at: Date.current.all_day)
    puts "Today's queries: #{today_queries.count}"

    if today_queries.any?
      puts "Models used:"
      today_queries.group(:model_id).count.each do |model, count|
        is_haiku = model.include?('haiku')
        icon = is_haiku ? '✅' : '🤖'
        puts "  #{icon} #{model}: #{count} queries"
      end

      total_tokens = today_queries.sum('input_tokens + output_tokens')
      total_cost = today_queries.sum(&:cost)
      puts "Total tokens: #{total_tokens}"
      puts "Total cost: $#{total_cost.round(6)}"
      
      # Show cost breakdown
      puts "\nCost breakdown by model:"
      today_queries.group(:model_id).each do |model, queries|
        model_cost = queries.sum(&:cost)
        puts "  #{model}: $#{model_cost.round(6)}"
      end
    else
      puts "⚠️  No queries today"
    end

    # 2. Aurora Debug
    puts "\n🏥 AURORA DEBUG:"
    begin
      service = SimpleMetricsService.new(Date.current)
      aurora_acu = service.send(:get_aurora_acu_average)
      puts "Aurora ACU: #{aurora_acu}"
      
      cluster_id = ENV["AURORA_DB_CLUSTER_IDENTIFIER"] || 
                   Rails.application.credentials.dig(:aws, :aurora_db_cluster_identifier)
      if cluster_id
        puts "Cluster ID: #{cluster_id}"
      else
        puts "⚠️  No Aurora cluster ID configured"
      end
    rescue => e
      puts "❌ Error checking Aurora: #{e.message}"
    end

    # 3. S3 Debug
    puts "\n📁 S3 DEBUG:"
    begin
      service = SimpleMetricsService.new(Date.current)
      s3_docs = service.send(:get_s3_document_count)
      s3_size = service.send(:get_s3_total_size)
      puts "S3 Documents: #{s3_docs}"
      puts "S3 Size: #{number_to_human_size(s3_size)}"
      
      bucket_name = ENV["KNOWLEDGE_BASE_S3_BUCKET"] ||
                    Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
                    Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket)
      if bucket_name
        puts "Bucket: #{bucket_name}"
      else
        puts "⚠️  No S3 bucket configured (auto-detection attempted)"
      end
    rescue => e
      puts "❌ Error checking S3: #{e.message}"
    end

    # 4. Cost Metrics
    puts "\n💰 COST METRICS (Today):"
    today_metrics = CostMetric.where(date: Date.current)
    if today_metrics.any?
      today_metrics.each do |metric|
        case metric.metric_type
        when 'daily_tokens'
          puts "  Tokens: #{metric.value.to_i}"
        when 'daily_cost'
          puts "  Cost: $#{metric.value.round(6)}"
        when 'daily_queries'
          puts "  Queries: #{metric.value.to_i}"
        when 'aurora_acu_avg'
          puts "  Aurora ACU: #{metric.value.round(2)}"
        when 's3_documents_count'
          puts "  S3 Documents: #{metric.value.to_i}"
        when 's3_total_size'
          puts "  S3 Size: #{number_to_human_size(metric.value.to_i)}"
        else
          puts "  #{metric.metric_type}: #{metric.value}"
        end
      end
    else
      puts "⚠️  No metrics collected for today"
      puts "   Run: rails metrics:collect"
    end

    # 5. Configuration Check
    puts "\n⚙️  CONFIGURATION:"
    region = Rails.application.credentials.dig(:aws, :region) || ENV.fetch("AWS_REGION", "us-east-1")
    puts "AWS Region: #{region}"
    
    has_credentials = Rails.application.credentials.dig(:aws, :access_key_id).present? ||
                      ENV["AWS_ACCESS_KEY_ID"].present? ||
                      Rails.application.credentials.dig(:aws, :bedrock_bearer_token).present? ||
                      ENV["AWS_BEARER_TOKEN_BEDROCK"].present?
    puts "AWS Credentials: #{has_credentials ? '✅ Configured' : '❌ Missing'}"
    
    kb_id = Rails.application.credentials.dig(:bedrock, :knowledge_base_id) || ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    puts "Knowledge Base ID: #{kb_id || '❌ Not configured'}"
    
    model_id = Rails.application.credentials.dig(:bedrock, :model_id) || ENV["BEDROCK_MODEL_ID"] || "anthropic.claude-3-haiku-20240307-v1:0"
    is_haiku = model_id.include?('haiku')
    icon = is_haiku ? '✅' : '🤖'
    puts "Default Model: #{icon} #{model_id}"

    puts "\n✅ Debug complete!"
    puts "=" * 50
  end
end

