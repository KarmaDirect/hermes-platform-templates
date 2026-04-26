# =============================================================================
# Hermes — main config (templated)
# =============================================================================
# Rendered at container start by bootstrap.sh via envsubst.
# Variables of the form ${VAR} are replaced; variables of the form {{VAR}}
# are left in place for downstream skill rendering.
# =============================================================================

profile:
  slug: "${CLIENT_SLUG}"
  display_name: "${CLIENT_NAME}"
  vertical: "${CLIENT_VERTICAL}"
  tone: "${CLIENT_TONE}"
  brand_color: "${CLIENT_BRAND_COLOR}"
  locale: "fr-FR"
  timezone: "${TZ}"

server:
  host: "0.0.0.0"
  port: 8642
  admin_port: 9119
  base_url: "https://hermes-${CLIENT_SLUG}.webstate.fr"

auth:
  api_token_env: "HERMES_API_TOKEN"

llm:
  default_provider: "anthropic"
  routing:
    reasoning:    { provider: "anthropic", model: "claude-sonnet-4-5" }
    vision:       { provider: "gemini",    model: "gemini-2.0-flash" }
    cheap:        { provider: "anthropic", model: "claude-haiku-4-5" }
  budgets:
    daily_eur: 5.00
    monthly_eur: 100.00

storage:
  data_dir: "/data"
  skills_dir: "/skills"
  profiles_dir: "/profiles"
  shared_memory_dir: "/data/shared-memory"

writeback:
  enabled: true
  supabase:
    url_env: "SUPABASE_URL"
    service_role_key_env: "SUPABASE_SERVICE_ROLE_KEY"
    schema: "hermes"
    tables:
      events:   "hermes_events"
      runs:     "hermes_runs"
      outputs:  "hermes_outputs"

observability:
  log_level: "${LOG_LEVEL}"
  metrics_enabled: true
  tracing_enabled: false

human_in_the_loop:
  default_required: true
  confirmation_channel: "telegram"   # falls back to email if telegram not enabled
  timeout_seconds: 600
