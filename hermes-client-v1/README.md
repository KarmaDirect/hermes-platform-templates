# Hermès Client Edition v1

Template Docker déployable pour chaque client PME de la plateforme Hermès.
Une instance = un container Hermès isolé, un volume de données dédié, un set de skills activable au cas par cas.

> Fait partie du livrable Hermès Platform. Provisionné automatiquement par le control-plane (livrable 2/3) via l'API Coolify.

---

## Installation manuelle (debug local)

```bash
cp .env.example .env
# Éditer .env avec les credentials du client (au moins HERMES_API_TOKEN, ANTHROPIC_API_KEY, CLIENT_*)

docker compose up -d
docker compose logs -f hermes
```

Vérifier la santé :

```bash
curl http://localhost:8642/health
```

Démarrer aussi Paperclip (optionnel) :

```bash
docker compose --profile with-paperclip up -d
```

---

## Déploiement Coolify (mode prod)

Ce template est déployé automatiquement par le control-plane Hermès Platform quand un nouveau client signe.

```
URL : https://app.hermes-platform.fr/admin/instances → "Nouveau client"
```

Le control-plane :
1. Crée le projet Coolify pour le client.
2. Pousse ce template (clone Git ou registry).
3. Injecte les variables d'env (LLM keys, channels, slug…).
4. Lance le build + le run.
5. Vérifie `/health` puis marque l'instance `ready` dans la DB Hermès Platform.

---

## Variables d'environnement

| Variable | Obligatoire | Usage |
|---|---|---|
| `CLIENT_NAME` | oui | Nom affiché du client |
| `CLIENT_SLUG` | oui | Identifiant kebab-case, sert de profil Hermès et de suffixe container/volume |
| `CLIENT_VERTICAL` | oui | `btp`, `restauration`, `coiffure`, `medical`, `generic` |
| `CLIENT_BRAND_COLOR` | non | Couleur d'accentuation (PDF, UI) |
| `CLIENT_TONE` | non | `pro`, `familier`, `technique`, `premium` |
| `HERMES_API_TOKEN` | oui | Token interne Hermès, généré par le control-plane |
| `ANTHROPIC_API_KEY` | oui | LLM principal |
| `GEMINI_API_KEY` | recommandé | Vision + ASR |
| `OPENAI_API_KEY` | non | Fallback uniquement |
| `VAPI_API_KEY` | conditionnel | Active le standard téléphonique |
| `WHATSAPP_TOKEN` | conditionnel | Active WhatsApp |
| `TELEGRAM_BOT_TOKEN` | conditionnel | Briefing patron + confirmations |
| `RESEND_API_KEY` | conditionnel | Emails transactionnels |
| `INSTAGRAM_ACCESS_TOKEN` | conditionnel | Posts sociaux |
| `ENABLED_SKILLS` | oui | Liste CSV des skills à activer |
| `SUPABASE_URL` | oui | DB centrale Hermès Platform |
| `SUPABASE_SERVICE_ROLE_KEY` | oui | Write-back DB centrale |
| `TZ` | non | `Europe/Paris` par défaut |
| `LOG_LEVEL` | non | `info` par défaut |
| `HERMES_HTTP_PORT` | non | `8642` par défaut |
| `HERMES_ADMIN_PORT` | non | `9119` par défaut, bound localhost |
| `HERMES_TEMPLATE_VERSION` | non | tag d'image, `v1` par défaut |
| `PAPERCLIP_API_TOKEN` | non | Optionnel, si profile `with-paperclip` |
| `PAPERCLIP_PORT` | non | `7777` par défaut |

---

## Skills inclus

| Skill | Catégorie | Channels requis | README |
|---|---|---|---|
| `reception-call` | communication | vapi | [skills/reception-call/README.md](./skills/reception-call/README.md) |
| `devis-vocal` | sales | whatsapp ou telegram | [skills/devis-vocal/README.md](./skills/devis-vocal/README.md) |
| `devis-photo` | sales | (visual input) | [skills/devis-photo/README.md](./skills/devis-photo/README.md) |
| `relance-impayes` | finance | email | [skills/relance-impayes/README.md](./skills/relance-impayes/README.md) |
| `suivi-chantier` | operations | telegram | [skills/suivi-chantier/README.md](./skills/suivi-chantier/README.md) |
| `posts-sociaux` | marketing | instagram | [skills/posts-sociaux/README.md](./skills/posts-sociaux/README.md) |
| `compta-classement` | finance | email ou whatsapp | [skills/compta-classement/README.md](./skills/compta-classement/README.md) |
| `briefing-quotidien` | management | telegram | [skills/briefing-quotidien/README.md](./skills/briefing-quotidien/README.md) |

---

## Architecture

```
hermes-client-v1/
├── Dockerfile.hermes        # multi-stage build
├── docker-compose.yml       # stack hermes + paperclip optionnel
├── bootstrap.sh             # init au premier boot
├── .env.example             # vars documentées
├── config/
│   ├── hermes.yaml.tpl      # config principale (envsubst)
│   └── channels.yaml.tpl    # wiring channels
└── skills/                  # 8 skills core (manifests + READMEs)
```

---

## TODOs / points à confirmer

1. **Image base** : `nousresearch/hermes-agent:v2026.4.16` — tag à confirmer auprès de Nous Research et registry à choisir (privé/public).
2. **Binaire serveur** : `bootstrap.sh` exécute `hermes serve --host 0.0.0.0 --port 8642`. Adapter si le binaire upstream s'appelle autrement (`hermes-agent`, `python -m hermes.server`).
3. **Code Python des skills** : volontairement absent — ce template ne fournit que les manifests + READMEs. Le code réel sera packagé dans une image dérivée par le control-plane.
