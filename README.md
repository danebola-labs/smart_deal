# Smart Deal

Platform that enables interaction and communication through RAG (Retrieval-Augmented Generation) across different communication channels, facilitating contextualized access to information based on a knowledge base.

## Features

- **User authentication** with Devise
- **Document processing**
- **AI document analysis – RAG** — AWS Bedrock, Knowledge Base, LLMs, embeddings, and prompt templates
- **Hotwire** for DOM updates (Turbo and Stimulus)
- **RAG chat with Knowledge Base integration** — LLMs, embeddings, prompt templates, and custom model configuration, optimized for inference and better results

## AI API Configuration

The application supports multiple AI providers, selectable via the `AI_PROVIDER` environment variable.

### Supported Providers

- **AWS Bedrock** (default) — Claude 3.5 Haiku for summaries, Claude 3 Sonnet for RAG
- **OpenAI** — GPT-4o-mini, GPT-4o, etc.
- **Anthropic** — Direct integration (coming soon)
- **GEIA** — Internal Globant service (coming soon)

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

3. Save the file.

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

2. Or via environment variable:
   ```bash
   export OPENAI_API_KEY=your-api-key
   export AI_PROVIDER=openai
   ```

### Changing the Provider

Set the `AI_PROVIDER` environment variable:

```bash
export AI_PROVIDER=bedrock    # AWS Bedrock (default)
export AI_PROVIDER=openai     # OpenAI
export AI_PROVIDER=anthropic  # Anthropic (coming soon)
export AI_PROVIDER=geia       # GEIA (coming soon)
```

See [BEDROCK_SETUP.md](BEDROCK_SETUP.md) for detailed setup.

## Installation

1. Install dependencies:
   ```bash
   bundle install
   ```

2. Configure the credentials master key (only on a new machine):
   - If you have the project master key (from the original repo or another developer), create `config/master.key` with that key (single line, no spaces). This file is not committed to git.
   - Or set the environment variable: `export RAILS_MASTER_KEY=your_key_here`
   - Without this key, commands such as `rails db:create` will fail with `ActiveSupport::MessageEncryptor::InvalidMessage`.

3. Set up the database:
   ```bash
   rails db:create
   rails db:migrate
   ```

4. Configure the AI API (see AI API Configuration above).

5. Start the server:
   ```bash
   bin/dev
   ```

6. Open http://localhost:3000 in your browser.

## Usage

1. Sign up or sign in.
2. Upload a PDF document; the AI will analyze it and generate a summary.
3. Use the RAG chat to ask questions about documents indexed in the Knowledge Base.

## Development

- Ruby: see `.ruby-version`
- Rails: 8.1.1
- Database: SQLite3 (development)

Run `bin/setup` to install Git hooks. The pre-commit hook runs RuboCop with autocorrect on staged Ruby files; fixes are staged automatically, and the commit is blocked if unfixable offenses remain (use `git commit --no-verify` to skip).

## Architecture

For architecture, design decisions, and patterns, see [ARCHITECTURE.md](ARCHITECTURE.md).
