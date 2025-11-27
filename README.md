# Smart Deal

API platform to automate contracts (sales, leases, services) with smart contracts integrated to payment gateways and legal compliance by country.

## Features

- 🔐 User authentication with Devise
- 📄 PDF document processing
- 🤖 AI document analysis (AWS Bedrock, OpenAI, Anthropic, GEIA)
- 🎨 Modern interface with particle effects
- ⚡ Hotwire (Turbo + Stimulus) for interactivity
- 🔄 Flexible architecture to switch between AI providers
- 💬 RAG chat with Knowledge Base integration

## AI API Configuration

The application supports multiple AI providers that can be switched with a single environment variable `AI_PROVIDER`.

### Supported Providers

- **AWS Bedrock** (default) - Claude 3.5 Haiku for summaries, Claude 3 Sonnet for RAG
- **OpenAI** - GPT-4o-mini, GPT-4o, etc.
- **Anthropic** - Direct integration (coming soon)
- **GEIA** - Internal Globant service (coming soon)

### AWS Bedrock Configuration (Recommended)

#### Option 1: Rails Credentials

1. Run:
   ```bash
   bin/rails credentials:edit
   ```

2. Add:
   ```yaml
   aws:
     access_key_id: YOUR_AWS_ACCESS_KEY_ID
     secret_access_key: YOUR_AWS_SECRET_ACCESS_KEY
     region: us-east-1
   bedrock:
     knowledge_base_id: YOUR_KNOWLEDGE_BASE_ID
     model_id: anthropic.claude-3-sonnet-20240229-v1:0
   ```

3. Save the file

#### Option 2: Environment Variables

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
export BEDROCK_KNOWLEDGE_BASE_ID=your_knowledge_base_id
export AI_PROVIDER=bedrock
```

### OpenAI Configuration

1. In Rails credentials:
   ```yaml
   openai:
     api_key: your-openai-api-key
   ```

2. Or environment variable:
   ```bash
   export OPENAI_API_KEY=your-api-key
   export AI_PROVIDER=openai
   ```

### Changing the Provider

You only need to change the `AI_PROVIDER` environment variable:

```bash
export AI_PROVIDER=bedrock    # AWS Bedrock (default)
export AI_PROVIDER=openai     # OpenAI
export AI_PROVIDER=anthropic  # Anthropic (coming soon)
export AI_PROVIDER=geia       # GEIA (coming soon)
```

**See detailed documentation**: [BEDROCK_SETUP.md](BEDROCK_SETUP.md)

## Installation

1. Install dependencies:
   ```bash
   bundle install
   ```

2. Set up the database:
   ```bash
   rails db:create
   rails db:migrate
   ```

3. Configure the AI API key (see previous section)

4. Start the server:
   ```bash
   bin/dev
   ```

5. Open your browser at `http://localhost:3000`

## Usage

1. Register a new user or sign in
2. Upload a PDF document
3. The AI will analyze the document and automatically generate a summary
4. Use the RAG chat to ask questions about documents indexed in the Knowledge Base

## Development

- Ruby version: See `.ruby-version`
- Rails version: 8.1.1
- Database: SQLite3 (development)

## Architecture

For detailed information about the application architecture, design decisions, and patterns used, see [ARCHITECTURE.md](ARCHITECTURE.md).
