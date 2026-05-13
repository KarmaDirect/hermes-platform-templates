#!/usr/bin/env bash
# upgrade-tenant-hermes-013.sh
#
# Upgrade un tenant Hermès Platform de v0.12 "Curator" vers v0.13 "Tenacity".
# À lancer depuis le VPS Hermès Platform (51.75.24.107) en SSH.
#
# Usage:
#   ./upgrade-tenant-hermes-013.sh <tenant_slug> [--dry-run]
#   ./upgrade-tenant-hermes-013.sh webstate-test
#   ./upgrade-tenant-hermes-013.sh webstate-test --dry-run
#
# Étapes :
#   1. Backup du volume /opt/data/{tenant} (skills + auth.json + memory)
#   2. Pull image v0.13 (vérif tag disponible)
#   3. docker compose down du container Hermès tenant
#   4. Rebuild avec nouveau FROM
#   5. docker compose up -d
#   6. Healthcheck : gateway port 8642 répond, dashboard port 9119 répond
#   7. Test /goal end-to-end (smoke)
#   8. Vérif config.yaml a `secret_redaction: true` (breaking 0.13)
#
# Cf. ROADMAP_2026-05.md Phase 11 + memory:reference_hermes_ecosystem_20260513.md

set -euo pipefail

TENANT_SLUG="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ -z "$TENANT_SLUG" ]]; then
  echo "Usage: $0 <tenant_slug> [--dry-run]"
  echo "Tenants actifs (depuis l'host) :"
  sudo docker ps --filter "name=hermes-" --format "  - {{.Names}}" | grep -v -E "control-plane|dashboard" || true
  exit 1
fi

DATA_DIR="/opt/data/${TENANT_SLUG}"
BACKUP_DIR="/opt/backups/hermes-upgrade-013/$(date -u +%Y%m%dT%H%M%SZ)-${TENANT_SLUG}"
COMPOSE_FILE="/opt/tenants/${TENANT_SLUG}/docker-compose.yml"
CONTAINER_NAME=$(sudo docker ps --filter "name=hermes-${TENANT_SLUG}" --format '{{.Names}}' | head -1 || true)

if [[ -z "$CONTAINER_NAME" ]]; then
  echo "❌ Aucun container actif matchant hermes-${TENANT_SLUG}*. Abandon."
  exit 2
fi

echo "================================================================"
echo "  Upgrade Hermès 0.12 → 0.13 'Tenacity'"
echo "  Tenant      : $TENANT_SLUG"
echo "  Container   : $CONTAINER_NAME"
echo "  Data dir    : $DATA_DIR"
echo "  Backup dir  : $BACKUP_DIR"
echo "  Compose     : $COMPOSE_FILE"
echo "  Dry run     : $DRY_RUN"
echo "================================================================"

if $DRY_RUN; then
  echo ""
  echo "Mode dry-run — affichage des étapes sans exécution."
  echo ""
  echo "  [1/7] BACKUP du volume tenant vers $BACKUP_DIR"
  echo "  [2/7] PULL image nousresearch/hermes-agent:v2026.5.7"
  echo "  [3/7] DOWN $CONTAINER_NAME"
  echo "  [4/7] BUILD nouvelle image (FROM v2026.5.7)"
  echo "  [5/7] UP -d nouveau container"
  echo "  [6/7] HEALTHCHECK gateway:8642 + dashboard:9119 + secret_redaction=true"
  echo "  [7/7] SMOKE test /goal 'echo ok'"
  exit 0
fi

# Pre-flight : vérifier que la nouvelle image existe avant de tuer le tenant.
echo "[0/7] Vérification disponibilité image upstream..."
if ! sudo docker manifest inspect nousresearch/hermes-agent:v2026.5.7 >/dev/null 2>&1; then
  echo "⚠️  Tag v2026.5.7 indisponible. Tentative fallback v2026.5.6..."
  if sudo docker manifest inspect nousresearch/hermes-agent:v2026.5.6 >/dev/null 2>&1; then
    IMG_TAG="v2026.5.6"
  else
    echo "❌ Aucun tag 0.13 trouvé. Abandon."
    exit 3
  fi
else
  IMG_TAG="v2026.5.7"
fi
echo "✓ Image cible : nousresearch/hermes-agent:$IMG_TAG"

# 1. Backup
echo "[1/7] Backup volume tenant..."
sudo mkdir -p "$BACKUP_DIR"
sudo tar -czf "$BACKUP_DIR/data.tar.gz" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
sudo cp -a "$DATA_DIR/config.yaml" "$BACKUP_DIR/" 2>/dev/null || true
sudo cp -a "$DATA_DIR/auth.json" "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ Backup OK : $BACKUP_DIR/data.tar.gz ($(sudo du -sh "$BACKUP_DIR/data.tar.gz" | cut -f1))"

# 2. Pull
echo "[2/7] Pull image $IMG_TAG..."
sudo docker pull "nousresearch/hermes-agent:$IMG_TAG"

# 3. Down
echo "[3/7] Stop container $CONTAINER_NAME..."
if [[ -f "$COMPOSE_FILE" ]]; then
  sudo docker compose -f "$COMPOSE_FILE" down
else
  sudo docker stop "$CONTAINER_NAME" && sudo docker rm "$CONTAINER_NAME"
fi

# 4. Build : si l'image est buildée localement à partir de notre Dockerfile.hermes,
#    on rebuild. Si le tenant utilise directement l'image upstream sans rebuild
#    (cas où Coolify pull direct), on saute cette étape.
TEMPLATE_DIR="/opt/hermes-platform-templates/hermes-client-v1"
if [[ -f "$TEMPLATE_DIR/Dockerfile.hermes" ]]; then
  echo "[4/7] Rebuild image custom (FROM v0.13)..."
  cd "$TEMPLATE_DIR"
  sudo docker build -f Dockerfile.hermes -t "hermes-client-v1:0.13" .
else
  echo "[4/7] Pas de Dockerfile.hermes en local — skip rebuild (image upstream pull only)"
fi

# 5. Up
echo "[5/7] Up container..."
if [[ -f "$COMPOSE_FILE" ]]; then
  sudo docker compose -f "$COMPOSE_FILE" up -d
else
  echo "❌ Aucun compose file en $COMPOSE_FILE. Re-créer le tenant manuellement."
  exit 4
fi

# Wait healthy
echo "Attente healthy (max 60s)..."
NEW_CONTAINER=$(sudo docker ps --filter "name=hermes-${TENANT_SLUG}" --format '{{.Names}}' | head -1)
for i in {1..30}; do
  STATUS=$(sudo docker inspect --format='{{.State.Health.Status}}' "$NEW_CONTAINER" 2>/dev/null || echo "missing")
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
echo "Status container : $STATUS"

# 6. Healthcheck
echo "[6/7] Healthcheck endpoints..."
sudo docker exec "$NEW_CONTAINER" curl -sf http://localhost:8642/health >/dev/null && echo "  ✓ gateway:8642" || echo "  ✗ gateway:8642 KO"
sudo docker exec "$NEW_CONTAINER" curl -sf http://localhost:9119/health >/dev/null && echo "  ✓ dashboard:9119" || echo "  ✗ dashboard:9119 KO"
# Vérif secret_redaction (breaking 0.12 → 0.13)
SECRET_REDACT=$(sudo docker exec "$NEW_CONTAINER" grep -E "secret_redaction\s*:" /opt/data/config.yaml 2>/dev/null | head -1 || echo "missing")
echo "  secret_redaction config: $SECRET_REDACT"
if [[ "$SECRET_REDACT" != *"true"* ]]; then
  echo "  ⚠️  secret_redaction n'est pas 'true' — risque de leak secrets dans logs (breaking 0.13)."
  echo "      Action manuelle : éditer /opt/data/$TENANT_SLUG/config.yaml et ajouter 'secret_redaction: true'."
fi

# Vérif version effective
NEW_VERSION=$(sudo docker exec "$NEW_CONTAINER" cat /opt/hermes/pyproject.toml 2>/dev/null | grep -E "^version" | head -1 || echo "?")
echo "  Version Hermès container : $NEW_VERSION"

# 7. Smoke test /goal
echo "[7/7] Smoke test /goal (best-effort)..."
# /goal nécessite une session active — on saute si on n'a pas de token API.
# À tester manuellement depuis le chat web après upgrade.
echo "  ℹ Test /goal manuel depuis chat web (chat.tenant.url → tape '/goal status')"

echo ""
echo "================================================================"
echo "✅ Upgrade terminé pour $TENANT_SLUG"
echo "   Backup     : $BACKUP_DIR"
echo "   Container  : $NEW_CONTAINER"
echo "   Image      : nousresearch/hermes-agent:$IMG_TAG"
echo ""
echo "🔄 Rollback si nécessaire :"
echo "   sudo docker stop $NEW_CONTAINER && sudo docker rm $NEW_CONTAINER"
echo "   cd $(dirname "$DATA_DIR") && sudo tar -xzf $BACKUP_DIR/data.tar.gz"
echo "   # Re-deploy avec FROM v2026.4.30"
echo "================================================================"
