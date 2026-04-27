#!/usr/bin/env bash
# =============================================================================
# Hermes Client Edition v1 — bootstrap.sh
# =============================================================================
# Runs as PID 1 (under tini) on every container start. Idempotent: safe to
# re-run after a redeploy, won't clobber existing profile state on /data.
#
# Two HTTP servers run side-by-side:
#   • Dashboard   (FastAPI, port 9119)  — read-only UI + /api/* + OAuth
#   • Gateway     (aiohttp, port 8642)  — OpenAI-compatible /v1/chat/completions
#
# Steps:
#   1. Render config templates with envsubst -> /data/config/
#   2. Initialize the per-client Hermes profile (first boot only)
#   3. Activate channels that have non-empty credentials
#   4. Activate skills listed in $ENABLED_SKILLS
#   5. Start dashboard (bg) + gateway (bg)
#   6. Apply default model (best-effort, idempotent)
#   7. Wait for either child to die — propagate exit code
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

# Confirmed via `docker run nousresearch/hermes-agent:v2026.4.16 dashboard --help`:
#   - Binary at /opt/hermes/.venv/bin/hermes
#   - HTTP/dashboard server: `hermes dashboard --host 0.0.0.0 --port 9119 --no-open --insecure`
#   - Gateway aiohttp server: `hermes gateway run --replace`
#       (host/port via env: API_SERVER_HOST, API_SERVER_PORT, API_SERVER_KEY)
HERMES_BIN="/opt/hermes/.venv/bin/hermes"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
GATEWAY_HOST="${GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-8642}"

# ---------- Required env ----------
: "${CLIENT_SLUG:?CLIENT_SLUG must be set}"
: "${CLIENT_NAME:?CLIENT_NAME must be set}"
: "${HERMES_API_TOKEN:?HERMES_API_TOKEN must be set (must match instances.api_token in Supabase platform DB)}"

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
# Default LLM model — applied once at first boot if no model is set yet.
# Stepfun via Nous Portal is free and a sane default for new tenants.
export HERMES_DEFAULT_MODEL="${HERMES_DEFAULT_MODEL:-stepfun/step-3.5-flash}"

# Boot in root: chown the volumes (created root-owned by Docker) to hermes (10000),
# then re-exec ourselves as hermes via gosu. Once we're hermes, this block is skipped.
if [[ "$(id -u)" == "0" ]]; then
  for d in "${DATA_DIR}" "${PROFILES_DIR}" "${SKILLS_DIR}"; do
    [[ -d "$d" ]] && chown -R 10000:10000 "$d" 2>/dev/null || true
  done
  exec gosu hermes "$0" "$@"
fi

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
  if [[ -x "${HERMES_BIN}" ]]; then
    "${HERMES_BIN}" profile init "${CLIENT_SLUG}" --path "${PROFILE_PATH}" \
      --display-name "${CLIENT_NAME}" \
      --vertical "${CLIENT_VERTICAL}" \
      --tone "${CLIENT_TONE}" \
      || warn "hermes profile init returned non-zero (continuing — may already exist)"
  else
    warn "Hermes binary not found at ${HERMES_BIN} — skipping profile init"
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
  if [[ -x "${HERMES_BIN}" ]]; then
    "${HERMES_BIN}" channel enable "${name}" --profile "${CLIENT_SLUG}" \
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
  if [[ -x "${HERMES_BIN}" ]]; then
    "${HERMES_BIN}" skill enable "${skill}" --profile "${CLIENT_SLUG}" \
      || warn "    failed to enable skill ${skill} (continuing)"
  fi
done

# =============================================================================
# 5. Start dashboard + gateway side-by-side
# =============================================================================
touch "${INIT_MARKER}"
touch "${READY_FILE}"

# Trap so SIGTERM from Docker shuts down both children cleanly.
GW_PID=""
DASH_PID=""
shutdown() {
  log "Received signal — stopping children"
  [[ -n "${GW_PID}"   ]] && kill "${GW_PID}"   2>/dev/null || true
  [[ -n "${DASH_PID}" ]] && kill "${DASH_PID}" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

log "Starting Hermes gateway (port ${GATEWAY_PORT})"
API_SERVER_HOST="${GATEWAY_HOST}" \
  API_SERVER_PORT="${GATEWAY_PORT}" \
  API_SERVER_KEY="${HERMES_API_TOKEN}" \
  "${HERMES_BIN}" gateway run --replace \
  > "${DATA_DIR}/gateway.log" 2>&1 &
GW_PID=$!
log "  gateway PID=${GW_PID}"

log "Starting Hermes dashboard (port ${DASHBOARD_PORT})"
"${HERMES_BIN}" dashboard \
  --host "${DASHBOARD_HOST}" \
  --port "${DASHBOARD_PORT}" \
  --no-open \
  --insecure \
  > "${DATA_DIR}/dashboard.log" 2>&1 &
DASH_PID=$!
log "  dashboard PID=${DASH_PID}"

# =============================================================================
# 6. Apply default model (best-effort, runs once dashboard is ready)
# =============================================================================
apply_default_model() {
  # Wait for dashboard's index.html to be served (max 30s)
  local max=30
  for i in $(seq 1 "${max}"); do
    if curl -fs -m 2 "http://127.0.0.1:${DASHBOARD_PORT}/" > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # Check current model. If empty AND HERMES_DEFAULT_MODEL is set, apply it.
  local session_token
  session_token=$(curl -s -m 5 "http://127.0.0.1:${DASHBOARD_PORT}/" \
    | grep -oP '__HERMES_SESSION_TOKEN__\s*=\s*"\K[^"]+' \
    | head -1)
  if [[ -z "${session_token}" ]]; then
    warn "Could not scrape SESSION_TOKEN from dashboard — skipping default model setup"
    return 0
  fi

  local current_model
  current_model=$(curl -fs -m 5 \
    -H "Authorization: Bearer ${session_token}" \
    "http://127.0.0.1:${DASHBOARD_PORT}/api/config" \
    | grep -oP '"model"\s*:\s*"\K[^"]*' \
    | head -1)

  if [[ -n "${current_model}" ]]; then
    log "Default model already set (${current_model}) — leaving as-is"
    return 0
  fi

  if [[ -z "${HERMES_DEFAULT_MODEL}" ]]; then
    log "No HERMES_DEFAULT_MODEL configured — skipping"
    return 0
  fi

  log "Applying default model: ${HERMES_DEFAULT_MODEL}"
  if curl -fs -m 5 -X PUT \
       -H "Authorization: Bearer ${session_token}" \
       -H "Content-Type: application/json" \
       -d "{\"config\":{\"model\":\"${HERMES_DEFAULT_MODEL}\"}}" \
       "http://127.0.0.1:${DASHBOARD_PORT}/api/config" > /dev/null 2>&1; then
    log "  → model applied"
  else
    warn "  → PUT /api/config failed (admin can set it manually via UI)"
  fi
}
( apply_default_model ) &

log "Bootstrap complete — dashboard + gateway running"

# =============================================================================
# 7. Wait for either child to die — propagate exit code
# =============================================================================
# `wait -n` returns when the FIRST child exits, with that child's exit code.
# We then trigger shutdown() to stop the surviving sibling and exit cleanly.
set +e
wait -n
EXIT_CODE=$?
set -e
warn "A child process exited with code ${EXIT_CODE} — shutting down sibling"
shutdown
