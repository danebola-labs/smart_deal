# frozen_string_literal: true

require 'aws-sdk-bedrockruntime'

DEFAULT_BEDROCK_REGION = ENV.fetch('AWS_REGION', 'us-east-1')
Aws.use_bundled_cert!

if ENV['AWS_ACCESS_KEY_ID'].present? && ENV['AWS_SECRET_ACCESS_KEY'].present?
  Aws.config.update(
    region: DEFAULT_BEDROCK_REGION,
    credentials: Aws::Credentials.new(
      ENV.fetch('AWS_ACCESS_KEY_ID', nil),
      ENV.fetch('AWS_SECRET_ACCESS_KEY', nil)
    )
  )
else
  Aws.config.update(region: DEFAULT_BEDROCK_REGION)
end

module BedrockProfiles
  CLAUDE_35_HAIKU = ENV.fetch('BEDROCK_PROFILE_CLAUDE35_HAIKU', 'us.anthropic.claude-3-5-haiku-20241022-v1:0')
end
