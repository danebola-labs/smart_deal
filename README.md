# Smart Deal

Plataforma API para automatizar contratos (ventas, arrendamientos, servicios) con smart contracts integrados a pasarelas de pago y cumplimiento legal por país.

## Características

- 🔐 Autenticación de usuarios con Devise
- 📄 Procesamiento de documentos PDF
- 🤖 Análisis de documentos con IA (AWS Bedrock, OpenAI, Anthropic, GEIA)
- 🎨 Interfaz moderna con efectos de partículas
- ⚡ Hotwire (Turbo + Stimulus) para interactividad
- 🔄 Arquitectura flexible para cambiar entre proveedores de IA

## Configuración de la API de IA

La aplicación soporta múltiples proveedores de IA que se pueden cambiar con una sola variable de entorno `AI_PROVIDER`.

### Proveedores Soportados

- **AWS Bedrock** (por defecto) - Claude 3.5 Haiku
- **OpenAI** - GPT-4o-mini, GPT-4o, etc.
- **Anthropic** - Integración directa (próximamente)
- **GEIA** - Servicio interno de Globant (próximamente)

### Configuración de AWS Bedrock (Recomendado)

#### Opción 1: Rails Credentials

1. Ejecuta:
   ```bash
   bin/rails credentials:edit
   ```

2. Agrega:
   ```yaml
   aws:
     access_key_id: YOUR_AWS_ACCESS_KEY_ID
     secret_access_key: YOUR_AWS_SECRET_ACCESS_KEY
     region: us-east-1
   ```

3. Guarda el archivo

#### Opción 2: Variables de Entorno

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
export AI_PROVIDER=bedrock
```

### Configuración de OpenAI

1. En Rails credentials:
   ```yaml
   openai:
     api_key: your-openai-api-key
   ```

2. O variable de entorno:
   ```bash
   export OPENAI_API_KEY=your-api-key
   export AI_PROVIDER=openai
   ```

### Cambiar el Proveedor

Solo necesitas cambiar la variable de entorno `AI_PROVIDER`:

```bash
export AI_PROVIDER=bedrock    # AWS Bedrock (por defecto)
export AI_PROVIDER=openai     # OpenAI
export AI_PROVIDER=anthropic  # Anthropic (próximamente)
export AI_PROVIDER=geia       # GEIA (próximamente)
```

**Ver documentación detallada**: [BEDROCK_SETUP.md](BEDROCK_SETUP.md)

## Instalación

1. Instala las dependencias:
   ```bash
   bundle install
   ```

2. Configura la base de datos:
   ```bash
   rails db:create
   rails db:migrate
   ```

3. Configura la API key de IA (ver sección anterior)

4. Inicia el servidor:
   ```bash
   bin/dev
   ```

5. Abre tu navegador en `http://localhost:3000`

## Uso

1. Registra un nuevo usuario o inicia sesión
2. Sube un documento PDF
3. La IA analizará el documento y generará un resumen automáticamente

## Desarrollo

- Ruby version: Ver `.ruby-version`
- Rails version: 8.1.1
- Database: SQLite3 (desarrollo)
