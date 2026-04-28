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
export INSTANCE_ID="${INSTANCE_ID:-}"
export ORG_ID="${ORG_ID:-}"
export COMPOSIO_API_KEY="${COMPOSIO_API_KEY:-}"
export ENABLED_SKILLS="${ENABLED_SKILLS:-reception-call,briefing-quotidien}"
# Default LLM model — applied once at first boot if no model is set yet.
# Stepfun via Nous Portal is free and a sane default for new tenants.
export HERMES_DEFAULT_MODEL="${HERMES_DEFAULT_MODEL:-stepfun/step-3.5-flash}"
export CONTACT_EMAIL="${CONTACT_EMAIL:-non-renseigné}"

# Boot in root: chown the volumes (created root-owned by Docker) to hermes (10000),
# clean stale runtime files (PID/lock from a crashed prior boot), then re-exec
# ourselves as hermes via gosu. Once we're hermes, this block is skipped.
#
# Why aggressive cleanup matters:
#   The gateway writes /opt/data/gateway.pid + gateway.lock at boot. If a prior
#   run crashed (or someone shelled into the container as root and ran hermes),
#   these files end up owned by root or contain a stale PID — and the next boot
#   as user hermes can't overwrite them, so gateway crashes with PermissionError
#   and the container is wedged. We aggressively clean before re-exec'ing.
if [[ "$(id -u)" == "0" ]]; then
  for d in "${DATA_DIR}" "${PROFILES_DIR}" "${SKILLS_DIR}"; do
    if [[ -d "$d" ]]; then
      chown -R 10000:10000 "$d" 2>/dev/null || true
    fi
  done
  # Remove stale runtime files left over from prior crashes / root invocations.
  # The hermes user re-creates them at startup, no data lost.
  for f in "${DATA_DIR}/gateway.pid" "${DATA_DIR}/gateway.lock" \
           "${DATA_DIR}/gateway_state.json" "${DATA_DIR}/auth.lock"; do
    [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
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
# AGENTS.md = "Context File" Hermès qui rend l'agent self-aware du dashboard.
# Lu par prompt_builder.build_context_files_prompt(cwd=TERMINAL_CWD) à chaque
# conversation. TERMINAL_CWD est exporté avant le launch gateway/dashboard.
render_tpl "${TEMPLATE_DIR}/config/AGENTS.md.tpl"     "${DATA_DIR}/AGENTS.md"

# =============================================================================
# 2. Initialize Hermes profile (first boot only)
# =============================================================================
PROFILE_PATH="${PROFILES_DIR}/${CLIENT_SLUG}"
if [[ ! -d "${PROFILE_PATH}" ]]; then
  log "Initializing Hermes profile: ${CLIENT_SLUG}"
  if [[ -x "${HERMES_BIN}" ]]; then
    # The CLI command is `hermes profile create` (the older docs called it
    # `init`, which the binary no longer supports as of v0.10.x).
    "${HERMES_BIN}" profile create "${CLIENT_SLUG}" --path "${PROFILE_PATH}" \
      --display-name "${CLIENT_NAME}" \
      --vertical "${CLIENT_VERTICAL}" \
      --tone "${CLIENT_TONE}" \
      || warn "hermes profile create returned non-zero (continuing — may already exist)"
  else
    warn "Hermes binary not found at ${HERMES_BIN} — skipping profile create"
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
# Read the per-instance skill list from Supabase if available — overrides
# the build-time ENABLED_SKILLS env. This lets the admin change a tenant's
# skills via the UI without re-deploying the container.
fetch_instance_skills() {
  if [[ -z "${SUPABASE_URL}" || -z "${SUPABASE_SERVICE_ROLE_KEY}" || -z "${INSTANCE_ID}" ]]; then
    return 0
  fi
  local from_db
  from_db=$(curl -s -m 10 \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/rest/v1/instances?id=eq.${INSTANCE_ID}&select=enabled_skills" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print((d[0].get('enabled_skills') or '').strip()) if d else print('')" 2>/dev/null \
    || echo "")
  if [[ -n "${from_db}" ]]; then
    log "  Using per-instance skills from DB: ${from_db}"
    ENABLED_SKILLS="${from_db}"
  fi
}
fetch_instance_skills
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
# 4.5. Self-heal `instances.api_token` in Supabase platform DB
# =============================================================================
# Why: at provision time, the control-plane generates HERMES_API_TOKEN, injects
# it into Coolify env AND writes it to `instances.api_token`. But if anyone
# rotates the env (or a manual edit diverges them), the proxy ends up using
# the DB token while the gateway accepts the env one → 401 on every chat call.
# We push the env token to DB on every boot so they stay in sync.
sync_token_to_db() {
  if [[ -z "${SUPABASE_URL}" || -z "${SUPABASE_SERVICE_ROLE_KEY}" || -z "${INSTANCE_ID}" ]]; then
    log "  Skip (missing SUPABASE_URL / SERVICE_ROLE / INSTANCE_ID)"
    return 0
  fi
  local resp
  resp=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
    -X PATCH \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"api_token\":\"${HERMES_API_TOKEN}\"}" \
    "${SUPABASE_URL}/rest/v1/instances?id=eq.${INSTANCE_ID}" 2>/dev/null || echo "000")
  if [[ "${resp}" =~ ^2 ]]; then
    log "  → Supabase instances.api_token synced (HTTP ${resp})"
  else
    warn "  → Supabase PATCH returned HTTP ${resp} (proxy may 401 until manual sync)"
  fi
}
log "Syncing api_token to Supabase platform DB"
sync_token_to_db

# =============================================================================
# 4.6. Re-apply Composio MCP config (from tenant_integrations + platform_settings)
# =============================================================================
# Why: Composio MCP url + headers can change (admin rotates the multi-toolkit
# server, COMPOSIO_API_KEY rotates). The Edge Function `composio-webhook` only
# pushes config when an OAuth flow finishes — but a redeploy resets the
# container's /opt/data/config.yaml, so the MCP server stops being announced.
# We re-read from Supabase on every boot and patch config.yaml idempotently.
apply_composio_mcp() {
  if [[ -z "${SUPABASE_URL}" || -z "${SUPABASE_SERVICE_ROLE_KEY}" || -z "${ORG_ID}" || -z "${COMPOSIO_API_KEY}" ]]; then
    log "  Skip (missing Supabase creds, ORG_ID, or COMPOSIO_API_KEY)"
    return 0
  fi

  # Does this org have any active Composio integration ? `wc -l` outputs
  # whitespace-padded counts on some BSD-flavours, and the `|| echo 0` adds
  # a second number if the curl pipe fails — strip both to a clean integer.
  local active_count
  active_count=$(curl -s -m 10 \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/rest/v1/tenant_integrations?org_id=eq.${ORG_ID}&backend=eq.composio&status=eq.active&select=id" 2>/dev/null \
    | grep -oE '"id":' | wc -l 2>/dev/null || echo 0)
  active_count=$(echo "${active_count}" | tr -d ' \n' | head -c 6)
  if [[ -z "${active_count}" ]] || [[ "${active_count}" == "0" ]]; then
    log "  No active Composio integration for org=${ORG_ID} — skipping"
    return 0
  fi

  # Read MCP base URL from platform_settings
  local mcp_url
  mcp_url=$(curl -s -m 10 \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/rest/v1/platform_settings?key=eq.composio_mcp_url&select=value" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['value'] if d else '')" 2>/dev/null \
    || echo "")
  if [[ -z "${mcp_url}" ]]; then
    warn "  composio_mcp_url not set in platform_settings"
    return 0
  fi

  # Build full URL with user_id query param (= org_id, the value passed to
  # Composio when the tenant connected an account).
  local full_url
  if [[ "${mcp_url}" == *"?"* ]]; then
    full_url="${mcp_url}&user_id=${ORG_ID}"
  else
    full_url="${mcp_url}?user_id=${ORG_ID}"
  fi

  log "  Patching /opt/data/config.yaml with Composio MCP server"
  "${HERMES_BIN%/hermes}/python" - <<PY || warn "  Python patch failed"
import yaml, sys
path = "/opt/data/config.yaml"
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}
cfg.setdefault("mcp_servers", {})["composio"] = {
    "url": "${full_url}",
    "auth_type": "header",
    "headers": {"x-api-key": "${COMPOSIO_API_KEY}"},
}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("OK")
PY
}
log "Re-applying Composio MCP config from Supabase"
apply_composio_mcp

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
# TERMINAL_CWD pointe sur DATA_DIR pour que prompt_builder lise AGENTS.md
# rendu en étape 1. Sans ça, la cwd serait `/` (racine container) et l'agent
# ignorerait toute la carte du dashboard.
API_SERVER_HOST="${GATEWAY_HOST}" \
  API_SERVER_PORT="${GATEWAY_PORT}" \
  API_SERVER_KEY="${HERMES_API_TOKEN}" \
  TERMINAL_CWD="${DATA_DIR}" \
  "${HERMES_BIN}" gateway run --replace \
  > "${DATA_DIR}/gateway.log" 2>&1 &
GW_PID=$!
log "  gateway PID=${GW_PID}"

log "Starting Hermes dashboard (port ${DASHBOARD_PORT})"
TERMINAL_CWD="${DATA_DIR}" \
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
# `wait -n PID...` waits for one of the SPECIFIC children to exit. Without
# the PID list, `wait -n` would also catch the `apply_default_model`
# background task (which is supposed to exit quickly after seeding the
# config) and shut the container down. We only care about the long-running
# servers : gateway + dashboard.
set +e
wait -n "${GW_PID}" "${DASH_PID}"
EXIT_CODE=$?
set -e
warn "A long-running server exited with code ${EXIT_CODE} — shutting down sibling"
shutdown
