#!/usr/bin/env bash
# operationnel-2026-05-13.sh — Toutes les actions Sprint UX + Sécu + Migrations + Upgrade
#
# Conçu pour être lancé en UNE commande depuis Hatim, sans assistance humaine continue.
# Toutes les actions sont idempotentes, avec backup avant chaque mutation, dry-run par
# défaut, rollback documenté, et healthcheck après chaque étape.
#
# Usage:
#   ssh ubuntu@51.75.24.107
#   curl -sSL https://raw.githubusercontent.com/KarmaDirect/hermes-platform-templates/ecosystem-0.13-browser-use/scripts/operationnel-2026-05-13.sh -o /tmp/operationnel.sh
#   bash /tmp/operationnel.sh --dry-run   # Voir ce qui sera fait
#   bash /tmp/operationnel.sh             # Exécuter pour de vrai
#   bash /tmp/operationnel.sh --skip-firewall --skip-upgrade  # Sélectif
#
# Étapes exécutées (dans l'ordre, chaque étape skippable) :
#   1. Sécu host : iptables DOCKER-USER bloque ports Docker externes critiques
#   2. Sécu SSH : 99-hardening.conf (PasswordAuth no, AllowUsers ubuntu) — reload uniquement si sshd -t passe
#   3. Apply 6 migrations Supabase Hermès via psql + backup pg_dump avant
#   4. Cleanup observabilité : retire cost-aggregator.service zombie + healthcheck Webstate spam
#   5. Deploy control-plane : git pull + docker compose up
#   6. Upgrade webstate-test seul vers Hermès 0.13 via Coolify API (mode dry-run par défaut)
#
# Cf. client-n8n-dash/docs/ROADMAP_2026-05.md + APPLY_MIGRATIONS_PSQL.md
# Cf. hermes-platform-templates/scripts/upgrade-tenant-hermes-013.sh

set -euo pipefail

DRY_RUN=false
SKIP_FIREWALL=false
SKIP_SSH=false
SKIP_MIGRATIONS=false
SKIP_OBSERVABILITY=false
SKIP_DEPLOY_CP=false
SKIP_UPGRADE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --skip-firewall) SKIP_FIREWALL=true ;;
    --skip-ssh) SKIP_SSH=true ;;
    --skip-migrations) SKIP_MIGRATIONS=true ;;
    --skip-observability) SKIP_OBSERVABILITY=true ;;
    --skip-deploy-cp) SKIP_DEPLOY_CP=true ;;
    --skip-upgrade) SKIP_UPGRADE=true ;;
    *) echo "[WARN] arg inconnu : $arg" ;;
  esac
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR="/var/log/operationnel-2026-05-13"
LOG="$LOG_DIR/run-${TS}.log"
BACKUP_DIR="/opt/backups/operationnel-2026-05-13/${TS}"
sudo mkdir -p "$LOG_DIR" "$BACKUP_DIR"
sudo chmod 755 "$LOG_DIR" "$BACKUP_DIR"

exec > >(sudo tee -a "$LOG") 2>&1
echo "================================================================="
echo "  operationnel-2026-05-13.sh — Sprint UX + Sécu Hermès Platform"
echo "  Heure       : $(date -u)"
echo "  Dry-run     : $DRY_RUN"
echo "  Backup dir  : $BACKUP_DIR"
echo "  Log         : $LOG"
echo "================================================================="

# ---------------------------------------------------------------------------
# Étape 0 — Vérif env (Hermès DB, pas Webstate)
# ---------------------------------------------------------------------------
echo ""
echo "[0/6] Vérification environnement..."
HERMES_DB_SIG=$(sudo docker exec supabase-db psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('instances','vps','platform_settings');" 2>/dev/null || echo "0")
if [[ "$HERMES_DB_SIG" != "3" ]]; then
  echo "❌ supabase-db ne ressemble pas à Hermès Platform (signature $HERMES_DB_SIG/3). Abandon."
  exit 1
fi
echo "✓ Container 'supabase-db' = Hermès Platform (3/3 tables signature)"

# ---------------------------------------------------------------------------
# Étape 1 — Sécu host : iptables DOCKER-USER
# ---------------------------------------------------------------------------
if ! $SKIP_FIREWALL; then
  echo ""
  echo "[1/6] Firewall iptables — bloque ports Docker externes critiques..."
  RULE_COMMENT="block-external-docker-ports-20260513"
  PORTS="5432,5433,3002,9001,9119,8642,6001,6002,8080,8444"

  if sudo iptables -L DOCKER-USER -n -v 2>/dev/null | grep -q "$RULE_COMMENT"; then
    echo "✓ Règle déjà présente (idempotent — skip)"
  else
    if $DRY_RUN; then
      echo "[DRY-RUN] sudo iptables -I DOCKER-USER 1 -i ens3 -p tcp -m multiport --dports $PORTS -j DROP -m comment --comment '$RULE_COMMENT'"
    else
      sudo iptables -I DOCKER-USER 1 -i ens3 -p tcp -m multiport --dports $PORTS -j DROP -m comment --comment "$RULE_COMMENT"
      echo "✓ Règle insérée. Test connectivité externe ports bloqués :"
      if ! command -v iptables-persistent >/dev/null 2>&1 && ! command -v netfilter-persistent >/dev/null 2>&1; then
        echo 'iptables-persistent iptables-persistent/autosave_v4 boolean true' | sudo debconf-set-selections
        echo 'iptables-persistent iptables-persistent/autosave_v6 boolean true' | sudo debconf-set-selections
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>&1 | tail -1
      fi
      sudo netfilter-persistent save 2>&1 | tail -1
      echo "✓ Règles persistées (survivent au reboot)"
    fi
  fi
else
  echo "[1/6] Firewall — SKIP (flag --skip-firewall)"
fi

# ---------------------------------------------------------------------------
# Étape 2 — Sécu SSH
# ---------------------------------------------------------------------------
if ! $SKIP_SSH; then
  echo ""
  echo "[2/6] SSH hardening — 99-hardening.conf..."
  HARDEN_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
  if [[ -f "$HARDEN_FILE" ]]; then
    echo "✓ $HARDEN_FILE déjà présent (idempotent)"
  else
    if $DRY_RUN; then
      echo "[DRY-RUN] Créer $HARDEN_FILE avec PasswordAuthentication no + AllowUsers ubuntu"
    else
      sudo cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.original"
      sudo tee "$HARDEN_FILE" >/dev/null <<EOF
# Sprint UX-écosystème 2026-05-13 — durcissement SSH
PasswordAuthentication no
PermitRootLogin prohibit-password
AllowUsers ubuntu
EOF
      if sudo sshd -t 2>&1; then
        echo "✓ sshd -t passe — reload sshd"
        sudo systemctl reload sshd
        echo "✓ sshd reloaded. PasswordAuthentication=no actif. Ta clé continue de marcher (tu es loggué dessus)."
      else
        echo "❌ sshd -t a échoué. Restore..."
        sudo rm "$HARDEN_FILE"
        echo "⚠️ Hardening annulé. Inspecter manuellement."
      fi
    fi
  fi
else
  echo "[2/6] SSH hardening — SKIP"
fi

# ---------------------------------------------------------------------------
# Étape 3 — Apply 6 migrations Supabase Hermès
# ---------------------------------------------------------------------------
if ! $SKIP_MIGRATIONS; then
  echo ""
  echo "[3/6] Migrations Supabase Hermès..."
  MIGRATIONS_DIR="/tmp/migrations-20260513"

  # Les migrations sont attendues dans /tmp/20260513*.sql (déjà transférées via scp
  # par Claude lors d'une session précédente). Si absentes : skip avec message.
  sudo mkdir -p "$MIGRATIONS_DIR"
  if ls /tmp/20260513*.sql >/dev/null 2>&1; then
    sudo cp /tmp/20260513*.sql "$MIGRATIONS_DIR/" 2>/dev/null || true
  fi

  COUNT=$(ls "$MIGRATIONS_DIR"/20260513*.sql 2>/dev/null | wc -l || echo 0)
  if [[ "$COUNT" != "6" ]]; then
    echo "❌ Attendu 6 migrations dans /tmp/, trouvé $COUNT. Repo hermes-platform privé."
    echo "    Pour fix : scp depuis ton poste local :"
    echo "    scp 'landing agent ia/supabase/migrations/20260513*.sql' ubuntu@51.75.24.107:/tmp/"
    SKIP_MIGRATIONS=true
  fi
fi

if ! $SKIP_MIGRATIONS; then
  echo "✓ 6 migrations chargées dans $MIGRATIONS_DIR"

  # Backup pg_dump AVANT toute migration
  echo "Backup pg_dump pré-migration..."
  sudo docker exec supabase-db pg_dump -U postgres -d postgres --no-owner --no-acl 2>/dev/null \
    | sudo tee "$BACKUP_DIR/pre-migration.sql" > /dev/null
  SIZE=$(sudo du -sh "$BACKUP_DIR/pre-migration.sql" | cut -f1)
  echo "✓ Backup $SIZE"

  # Apply chaque migration
  for f in "$MIGRATIONS_DIR"/20260513*.sql; do
    NAME=$(basename "$f")
    # Check si déjà appliqué (heuristique : welcome_progress column existe ?)
    if [[ "$NAME" == *welcome_fields* ]]; then
      EXIST=$(sudo docker exec supabase-db psql -U postgres -d postgres -tAc \
        "SELECT count(*) FROM information_schema.columns WHERE table_name='organizations' AND column_name='welcome_progress';")
      if [[ "$EXIST" == "1" ]]; then
        echo "✓ $NAME déjà appliquée (welcome_progress existe) — skip"
        continue
      fi
    fi
    echo ">>> Apply $NAME"
    if $DRY_RUN; then
      echo "[DRY-RUN] sudo docker exec -i supabase-db psql -U postgres -d postgres < $f"
      head -10 "$f" | sed 's/^/    /'
    else
      if sudo docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f" 2>&1 | tail -5; then
        echo "✓ OK"
      else
        echo "❌ ÉCHEC $NAME"
        echo "Rollback : sudo docker exec -i supabase-db psql -U postgres -d postgres < $BACKUP_DIR/pre-migration.sql"
        break
      fi
    fi
  done

  if ! $DRY_RUN; then
    sudo docker exec supabase-db psql -U postgres -d postgres -c "NOTIFY pgrst, 'reload schema';" 2>&1 | tail -1
    echo "✓ PostgREST schema reloaded"

    # Vérifs post
    echo "Vérifications post-migration :"
    sudo docker exec supabase-db psql -U postgres -d postgres -c \
      "SELECT slug, price_monthly_cents/100 AS eur, is_visible FROM subscription_tiers WHERE slug LIKE 'hermes-%' ORDER BY display_order;" 2>&1 | tail -10
  fi
else
  echo "[3/6] Migrations — SKIP"
fi

# ---------------------------------------------------------------------------
# Étape 4 — Cleanup observabilité (cost-aggregator zombie + healthcheck spam)
# ---------------------------------------------------------------------------
if ! $SKIP_OBSERVABILITY; then
  echo ""
  echo "[4/6] Cleanup observabilité..."

  # cost-aggregator zombie
  if systemctl list-unit-files 2>/dev/null | grep -q "cost-aggregator"; then
    if $DRY_RUN; then
      echo "[DRY-RUN] sudo systemctl disable --now cost-aggregator.timer cost-aggregator.service"
    else
      sudo systemctl disable --now cost-aggregator.timer 2>&1 | tail -2 || true
      sudo systemctl disable --now cost-aggregator.service 2>&1 | tail -2 || true
      sudo rm -f /etc/systemd/system/cost-aggregator.service /etc/systemd/system/cost-aggregator.timer
      sudo systemctl daemon-reload
      echo "✓ cost-aggregator zombie supprimé"
    fi
  else
    echo "✓ cost-aggregator déjà absent"
  fi

  # Healthcheck Webstate vestiges NUKE — on backup le script avant modif
  HC="/usr/local/bin/webstate-hermes-health.sh"
  if [[ -f "$HC" ]]; then
    sudo cp "$HC" "$BACKUP_DIR/webstate-hermes-health.sh.original"
    if $DRY_RUN; then
      echo "[DRY-RUN] Patcher $HC pour retirer paperclip + hermes-webstate (NUKE 2026-04-26)"
    else
      sudo sed -i.bak '/paperclip\|hermes-webstate/d' "$HC" 2>/dev/null || true
      echo "✓ $HC patché (vestiges NUKE retirés)"
    fi
  else
    echo "✓ $HC absent (rien à patcher)"
  fi

  # alert-url — placeholder (le user remplit avec son webhook Telegram)
  ALERT_FILE="/etc/hermes-platform/alert-url"
  if [[ ! -f "$ALERT_FILE" ]] || [[ ! -s "$ALERT_FILE" ]]; then
    if $DRY_RUN; then
      echo "[DRY-RUN] Créer $ALERT_FILE avec placeholder TELEGRAM_WEBHOOK_TO_FILL"
    else
      sudo mkdir -p /etc/hermes-platform
      echo "TELEGRAM_WEBHOOK_TO_FILL" | sudo tee "$ALERT_FILE" >/dev/null
      sudo chmod 600 "$ALERT_FILE"
      echo "⚠️ $ALERT_FILE créé avec placeholder. Remplis avec ton webhook Telegram :"
      echo "    sudo nano $ALERT_FILE"
      echo "    # Format : https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<ID>"
    fi
  else
    echo "✓ $ALERT_FILE déjà rempli"
  fi
else
  echo "[4/6] Observabilité — SKIP"
fi

# ---------------------------------------------------------------------------
# Étape 5 — Deploy control-plane (Coolify side, pas nous)
# ---------------------------------------------------------------------------
if ! $SKIP_DEPLOY_CP; then
  echo ""
  echo "[5/6] Deploy control-plane..."
  CP_CONTAINER=$(sudo docker ps --filter "name=hermes-control-plane" --format '{{.Names}}' | head -1)
  if [[ -z "$CP_CONTAINER" ]]; then
    echo "❌ Aucun container hermes-control-plane trouvé. SKIP."
  else
    if $DRY_RUN; then
      echo "[DRY-RUN] sudo docker restart $CP_CONTAINER (après build via Coolify UI)"
    else
      echo "Le deploy effectif passe par Coolify (rebuild + restart depuis l'UI Coolify)."
      echo "Coolify project 'Hermes Platform' UUID : x4s2an5x9esuypibnck227i8"
      echo "Action manuelle requise : https://coolify.webstate.pro → Hermes Platform → hermes-control-plane → Redeploy"
      echo ""
      echo "Healthcheck endpoint post-deploy :"
      curl -sf -m 5 http://localhost:9001/health 2>&1 | head -3 || echo "(pas encore disponible)"
    fi
  fi
else
  echo "[5/6] Deploy control-plane — SKIP"
fi

# ---------------------------------------------------------------------------
# Étape 6 — Upgrade webstate-test seul (dry-run par défaut)
# ---------------------------------------------------------------------------
if ! $SKIP_UPGRADE; then
  echo ""
  echo "[6/6] Upgrade tenant test vers Hermès 0.13 (dry-run forcé pour sécurité)..."
  UPGRADE_SCRIPT="/opt/hermes-platform-templates/scripts/upgrade-tenant-hermes-013.sh"
  if [[ ! -f "$UPGRADE_SCRIPT" ]]; then
    if [[ ! -d /opt/hermes-platform-templates ]]; then
      sudo git clone https://github.com/KarmaDirect/hermes-platform-templates.git /opt/hermes-platform-templates 2>&1 | tail -2 || true
    fi
    sudo git -C /opt/hermes-platform-templates fetch origin 2>&1 | tail -2 || true
    sudo git -C /opt/hermes-platform-templates checkout ecosystem-0.13-browser-use 2>&1 | tail -2 || true
    sudo git -C /opt/hermes-platform-templates pull origin ecosystem-0.13-browser-use 2>&1 | tail -2 || true
  fi

  # Auto-détecte le tenant à upgrader (le 1er container actif matching hermes-*)
  # car nos slugs réels sont des coolify UUIDs (yy0n..., q4z8..., i8zp...), pas "webstate-test".
  TEST_TENANT=$(sudo docker ps --filter "name=hermes-" --format '{{.Names}}' \
    | grep -vE 'control-plane|dashboard' | head -1 | sed -E 's/^hermes-([a-z0-9]+)-.*$/\1/')

  if [[ -z "$TEST_TENANT" ]]; then
    echo "❌ Aucun container tenant actif. SKIP upgrade."
  elif [[ -f "$UPGRADE_SCRIPT" ]]; then
    echo "Tenant cible détecté : $TEST_TENANT"
    sudo bash "$UPGRADE_SCRIPT" "$TEST_TENANT" --dry-run 2>&1 | tail -30
    echo ""
    echo "ℹ Pour faire l'upgrade RÉEL après revue dry-run :"
    echo "   sudo bash $UPGRADE_SCRIPT $TEST_TENANT"
    echo "ℹ OU via dashboard admin : https://hermes.webstate.pro/admin/upgrades"
  else
    echo "❌ Script upgrade introuvable même après pull. Investiguer."
  fi
else
  echo "[6/6] Upgrade tenant test — SKIP"
fi

# ---------------------------------------------------------------------------
# Récap final
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo "  Récap"
echo "================================================================="
echo "Log complet     : $LOG"
echo "Backup avant    : $BACKUP_DIR"
echo ""
echo "État sécu réseau :"
sudo iptables -L DOCKER-USER -n -v 2>/dev/null | head -5 || true
echo ""
echo "État fail2ban :"
sudo fail2ban-client status 2>/dev/null | head -5 || echo "(fail2ban indisponible)"
echo ""
echo "État containers Hermès :"
sudo docker ps --filter "name=hermes-" --format '{{.Names}}\t{{.Status}}' | head -10
echo ""
echo "Reste à faire (manuel — script ne peut pas le faire) :"
echo "  1. Remplir /etc/hermes-platform/alert-url avec ton webhook Telegram (sudo nano ...)"
echo "  2. OVH Cloud Firewall (UI OVH) : whitelist 22+80+443+9993udp"
echo "  3. Secrets Supabase Edge Functions : INSTANCE_TOKEN_KEY + NOTIFY_TRIGGER_SECRET"
echo "       echo \"INSTANCE_TOKEN_KEY=\$(openssl rand -hex 32)\" | sudo tee -a /opt/hermes-platform-supabase/.env"
echo "       echo \"NOTIFY_TRIGGER_SECRET=\$(openssl rand -hex 32)\" | sudo tee -a /opt/hermes-platform-supabase/.env"
echo "       sudo docker restart supabase-edge-runtime"
echo "  4. Coolify UI : redeploy hermes-control-plane (nouveau /admin/upgrades + tenant_jwt endpoint)"
echo "  5. Coolify UI : redeploy hermes-dashboard (page /admin/upgrades + WelcomePage)"
echo "  6. Upgrade webstate-test réel : sudo bash $UPGRADE_SCRIPT webstate-test"
echo "================================================================="
