# Configuración de AWS Bedrock

## Requisitos

1. **Credenciales AWS**: Necesitas `access_key_id` y `secret_access_key` de AWS
2. **Region**: `us-east-1` (configurada por defecto)
3. **Modelo**: `anthropic.claude-3-5-haiku-20241022-v1:0`

## Configuración de Credenciales

### Opción 1: Rails Credentials (Recomendado)

1. Ejecuta:
   ```bash
   bin/rails credentials:edit
   ```

2. Agrega la siguiente configuración:
   ```yaml
   aws:
     access_key_id: YOUR_AWS_ACCESS_KEY_ID
     secret_access_key: YOUR_AWS_SECRET_ACCESS_KEY
     region: us-east-1
   ```

3. Guarda el archivo (en vim/nano: `:wq` o `Ctrl+X` luego `Y`)

### Opción 2: Variables de Entorno

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
```

## Configuración del Proveedor de IA

### Variable de Entorno AI_PROVIDER

Cambia entre proveedores usando la variable de entorno `AI_PROVIDER`:

```bash
# AWS Bedrock (por defecto)
export AI_PROVIDER=bedrock

# OpenAI
export AI_PROVIDER=openai

# Anthropic (directo - no implementado aún)
export AI_PROVIDER=anthropic

# GEIA (servicio interno de Globant)
export AI_PROVIDER=geia
```

### En Rails Credentials

También puedes configurarlo en `bin/rails credentials:edit`:

```yaml
aws:
  access_key_id: YOUR_ACCESS_KEY
  secret_access_key: YOUR_SECRET_KEY
  region: us-east-1

# Configuración del proveedor de IA
ai_provider: bedrock  # o openai, anthropic, geia
```

## Probar la Integración

### 1. Subir un Documento PDF

Ve a `http://localhost:3000` y sube un PDF. El sistema procesará el documento con Bedrock automáticamente.

### 2. Endpoint REST API

También puedes probar directamente el endpoint:

```bash
curl -X POST http://localhost:3000/ai/ask \
  -H "Content-Type: application/json" \
  -H "Cookie: [tu_cookie_de_sesion]" \
  -d '{
    "prompt": "Resume este contrato en 3 puntos",
    "max_tokens": 500,
    "temperature": 0.7
  }'
```

## Estructura de Servicios

La aplicación usa una arquitectura flexible con servicios separados:

- `app/services/bedrock_client.rb` - Cliente de AWS Bedrock
- `app/services/open_ai_client.rb` - Cliente de OpenAI
- `app/services/anthropic_client.rb` - Cliente de Anthropic (placeholder)
- `app/services/geia_client.rb` - Cliente de GEIA (placeholder)
- `app/services/ai_provider.rb` - Facade que despacha al proveedor activo

## Verificación

1. Verifica que las credenciales estén configuradas:
   ```bash
   bin/rails runner "puts Rails.application.credentials.dig(:aws, :access_key_id) ? 'OK' : 'NOT CONFIGURED'"
   ```

2. Verifica el proveedor activo:
   ```bash
   bin/rails runner "puts ENV.fetch('AI_PROVIDER', 'bedrock')"
   ```

3. Reinicia el servidor Rails después de cambiar las credenciales:
   ```bash
   bin/dev
   ```

## Troubleshooting

### Error: "Unknown AI provider"
- Verifica que `AI_PROVIDER` tenga un valor válido: `bedrock`, `openai`, `anthropic`, `geia`

### Error: "Bedrock error: AccessDeniedException"
- Verifica que tus credenciales AWS tengan permisos para Bedrock
- Verifica que el modelo esté habilitado en tu región AWS

### Error: "API key not configured"
- Verifica que las credenciales estén en Rails credentials o variables de entorno
- Reinicia el servidor después de configurar las credenciales

