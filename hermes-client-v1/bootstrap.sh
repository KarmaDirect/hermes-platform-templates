#!/usr/bin/env bash
# =============================================================================
# Hermes Client Edition v1 — bootstrap.sh
# =============================================================================
# Runs as PID 1 (under tini) on every container start. Idempotent: safe to
# re-run after a redeploy, won't clobber existing profile state on /data.
#
# Steps:
#   1. Render config templates with envsubst -> /data/config/
#   2. Initialize the per-client Hermes profile (first boot only)
#   3. Activate channels that have non-empty credentials
#   4. Activate skills listed in $ENABLED_SKILLS
#   5. Touch /data/.ready  +  exec the Hermes server in foreground
# =============================================================================

set -euo pipefail

# ---------- Logging helpers ----------
log()  { printf '[bootstrap] %s\n' "$*" >&2; }
warn() { printf '[bootstrap][WARN] %s\n' "$*" >&2; }
die()  { printf '[bootstrap][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------- Paths ----------
TEMPLATE_DIR="/opt/hermes-template"
DATA_DIR="/data"
CONFIG_DIR="${DATA_DIR}/config"
SKILLS_DIR="/skills"
PROFILES_DIR="/profiles"
READY_FILE="${DATA_DIR}/.ready"
INIT_MARKER="${DATA_DIR}/.bootstrapped"

# Server command — adjust here if the upstream binary path changes.
# Common alternatives observed:
#   hermes serve --host 0.0.0.0 --port 8642
#   hermes-agent --listen 0.0.0.0:8642
#   python -m hermes.server
SERVER_CMD=( hermes serve --host 0.0.0.0 --port 8642 )

# ---------- Required env ----------
: "${CLIENT_SLUG:?CLIENT_SLUG must be set}"
: "${CLIENT_NAME:?CLIENT_NAME must be set}"
: "${HERMES_API_TOKEN:?HERMES_API_TOKEN must be set}"

# Default optional vars so envsubst doesn't leave unbound holes
export CLIENT_VERTICAL="${CLIENT_VERTICAL:-generic}"
export CLIENT_BRAND_COLOR="${CLIENT_BRAND_COLOR:-#3b82f6}"
export CLIENT_TONE="${CLIENT_TONE:-pro}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export VAPI_API_KEY="${VAPI_API_KEY:-}"
export WHATSAPP_TOKEN="${WHATSAPP_TOKEN:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export RESEND_API_KEY="${RESEND_API_KEY:-}"
export INSTAGRAM_ACCESS_TOKEN="${INSTAGRAM_ACCESS_TOKEN:-}"
export SUPABASE_URL="${SUPABASE_URL:-}"
export SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
export ENABLED_SKILLS="${ENABLED_SKILLS:-reception-call,briefing-quotidien}"

mkdir -p "${CONFIG_DIR}" "${PROFILES_DIR}" "${SKILLS_DIR}"
rm -f "${READY_FILE}"

# =============================================================================
# 1. Render config templates
# =============================================================================
log "Rendering config templates for client=${CLIENT_SLUG}"

render_tpl() {
  local src="$1" dst="$2"
  if [[ ! -f "${src}" ]]; then
    warn "Template missing: ${src} (skipping)"
    return 0
  fi
  envsubst < "${src}" > "${dst}"
  log "  -> ${dst}"
}

render_tpl "${TEMPLATE_DIR}/config/hermes.yaml.tpl"   "${CONFIG_DIR}/hermes.yaml"
render_tpl "${TEMPLATE_DIR}/config/channels.yaml.tpl" "${CONFIG_DIR}/channels.yaml"

# =============================================================================
# 2. Initialize Hermes profile (first boot only)
# =============================================================================
PROFILE_PATH="${PROFILES_DIR}/${CLIENT_SLUG}"
if [[ ! -d "${PROFILE_PATH}" ]]; then
  log "Initializing Hermes profile: ${CLIENT_SLUG}"
  if command -v hermes >/dev/null 2>&1; then
    hermes profile init "${CLIENT_SLUG}" --path "${PROFILE_PATH}" \
      --display-name "${CLIENT_NAME}" \
      --vertical "${CLIENT_VERTICAL}" \
      --tone "${CLIENT_TONE}" \
      || warn "hermes profile init returned non-zero (continuing — may already exist)"
  else
    warn "'hermes' CLI not found in PATH — skipping profile init (TODO: confirm binary name)"
    mkdir -p "${PROFILE_PATH}"
  fi
else
  log "Profile already exists at ${PROFILE_PATH} (skip init)"
fi

# =============================================================================
# 3. Activate channels (only those with non-empty credentials)
# =============================================================================
log "Activating channels"

activate_channel() {
  local name="$1" cred="$2"
  if [[ -z "${cred}" ]]; then
    log "  - ${name}: SKIP (no credential)"
    return 0
  fi
  log "  - ${name}: ENABLE"
  if command -v hermes >/dev/null 2>&1; then
    hermes channel enable "${name}" --profile "${CLIENT_SLUG}" \
      || warn "    failed to enable ${name} (continuing)"
  fi
}

activate_channel "vapi"      "${VAPI_API_KEY}"
activate_channel "whatsapp"  "${WHATSAPP_TOKEN}"
activate_channel "telegram"  "${TELEGRAM_BOT_TOKEN}"
activate_channel "email"     "${RESEND_API_KEY}"
activate_channel "instagram" "${INSTAGRAM_ACCESS_TOKEN}"

# =============================================================================
# 4. Activate skills
# =============================================================================
log "Activating skills: ${ENABLED_SKILLS}"

# Copy skill manifests from the read-only template into the writable /skills
# volume so the operator can override per-client without rebuilding the image.
if [[ -d "${TEMPLATE_DIR}/skills" ]]; then
  cp -rn "${TEMPLATE_DIR}/skills/." "${SKILLS_DIR}/" 2>/dev/null || true
fi

IFS=',' read -ra SKILL_LIST <<< "${ENABLED_SKILLS}"
for raw in "${SKILL_LIST[@]}"; do
  skill="$(echo "${raw}" | tr -d '[:space:]')"
  [[ -z "${skill}" ]] && continue

  if [[ ! -d "${SKILLS_DIR}/${skill}" ]]; then
    warn "  - ${skill}: NOT FOUND in /skills (skip)"
    continue
  fi
  log "  - ${skill}: ENABLE"
  if command -v hermes >/dev/null 2>&1; then
    hermes skill enable "${skill}" --profile "${CLIENT_SLUG}" \
      || warn "    failed to enable skill ${skill} (continuing)"
  fi
done

# =============================================================================
# 5. Mark ready & exec server
# =============================================================================
touch "${INIT_MARKER}"
touch "${READY_FILE}"
log "Bootstrap complete — handing off to Hermes server"

# If the upstream image has its own entrypoint we want to bypass, exec'ing
# replaces this script as PID 1 (still under tini).
exec "${SERVER_CMD[@]}"
