# =============================================================================
# Hermes — channels config (templated)
# =============================================================================
# A channel is enabled iff its credential env var is non-empty. bootstrap.sh
# decides; this file declares the wiring. DO NOT hardcode secrets here.
# =============================================================================

channels:

  vapi:
    enabled_if_env: "VAPI_API_KEY"
    api_key_env: "VAPI_API_KEY"
    inbound:
      webhook_path: "/vapi/incoming-call"
      assistant_id: ""               # set per client by control-plane (CLIENT_VAPI_ASSISTANT_ID)
    outbound:
      max_calls_per_day: 50

  whatsapp:
    enabled_if_env: "WHATSAPP_TOKEN"
    token_env: "WHATSAPP_TOKEN"
    provider: "meta"                 # meta | unipile | zernio
    inbound:
      webhook_path: "/whatsapp/incoming"

  telegram:
    enabled_if_env: "TELEGRAM_BOT_TOKEN"
    bot_token_env: "TELEGRAM_BOT_TOKEN"
    inbound:
      webhook_path: "/telegram/incoming"
    outbound:
      default_chat_id: ""            # patron's Telegram chat_id, set by onboarding

  email:
    enabled_if_env: "RESEND_API_KEY"
    provider: "resend"
    api_key_env: "RESEND_API_KEY"
    from_address: "no-reply@hermes-${CLIENT_SLUG}.webstate.fr"
    reply_to: ""

  instagram:
    enabled_if_env: "INSTAGRAM_ACCESS_TOKEN"
    access_token_env: "INSTAGRAM_ACCESS_TOKEN"
    provider: "zernio"               # cheaper than direct Meta Graph

routing:
  default_inbound_skill: "reception-call"
  fallback_to_human:
    after_failed_attempts: 2
    notify_via: "telegram"
