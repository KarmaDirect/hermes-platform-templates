---
name: browser-use-runner
description: Wrapper bas niveau pour exécuter une tâche browser via la lib browser-use (navigation, click, fill, scrape) avec capture screenshot + résultat structuré. Utilisé par les skills métier (Pages Jaunes, avis Google, chantiers concurrence) — pas directement par le user final.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - python>=3.11
  - browser-use>=0.4
metadata:
  hermes:
    tags: [internal, infra, web, browser, scraping]
    category: infra
    triggers: [tool_call]
---

# browser-use-runner

## When to Use

**Skill interne**. Tu l'appelles depuis d'autres skills quand tu as besoin de :
- Naviguer sur un site qui bloque les bots (Cloudflare, Akamai, PerimeterX)
- Remplir un formulaire web (login, recherche, filtre)
- Cliquer plusieurs étapes pour atteindre une donnée
- Extraire du contenu rendu en JavaScript (les sites React/Vue)

**Ne pas appeler directement** si :
- L'info est dispo via une API JSON (préférer `requests`)
- C'est un simple HTML statique (préférer `Firecrawl` ou `httpx`)
- Le site a un endpoint OpenAPI documenté

## Coût

- LLM utilisé : par défaut le modèle du tenant (Codex CLI / Nous Portal gratuit StepFun)
- Browser : Chromium headless, ~250 MB RAM par session, démarrage ~3s
- Latence : 5-30s par tâche selon complexité (vs <1s pour un GET HTTP direct)

## Input

```json
{
  "task": "Description en langage naturel de ce qu'il faut faire",
  "url": "https://...",
  "extract_schema": {
    "type": "object",
    "properties": {"...": "..."}
  },
  "screenshot": true,
  "max_steps": 15
}
```

## Output (JSON STRICT)

```json
{
  "ok": true,
  "data": { /* matche extract_schema */ },
  "steps_taken": 8,
  "duration_ms": 14523,
  "screenshot_path": "/data/browser-use/screenshots/2026-05-13_pages-jaunes_abc.png",
  "error": null
}
```

En cas d'échec :
```json
{
  "ok": false,
  "data": null,
  "error": "Page not loaded after 30s",
  "screenshot_path": "/data/browser-use/screenshots/2026-05-13_failure_abc.png"
}
```

## Procédure

1. Vérifier que `browser_use` est installé : `python -c "import browser_use; print(browser_use.__version__)"`.
2. Vérifier que le tenant a une env `BROWSER_USE_HEADLESS=true` (toujours headless en prod).
3. Exécuter `runner.py` avec les args en JSON sur stdin.
4. Récupérer le JSON de stdout + screenshot path.
5. Limiter `max_steps` à 15 par défaut (anti-boucle infinie).
6. **Toujours** capturer un screenshot final pour audit human-review.

## Sécurité

- ⚠️ **Jamais** stocker de credentials clients dans le `task`. Si auth nécessaire, utiliser les `tenant_credentials` chiffrés et les injecter en variables env (`$QONTO_API_KEY`, etc.).
- ⚠️ **Jamais** scraper de données personnelles (nom + téléphone + email d'individus identifiés sans consentement). Toujours s'en tenir aux entreprises / établissements publics. Cf. RGPD article 6.
- ⚠️ Respecter les `robots.txt` des sites publics. Pas de scraping massif (rate-limit 1 req/3s par défaut).
- ⚠️ **Aucun login** sur compte personnel client (Gmail/Banque/etc.) — toujours OAuth via Composio MCP ou wrappers API directs.

## Pitfalls

- Cloudflare a renforcé sa détection 2026 : si échec répété, escalader vers Browserbase (coût mais fingerprint résidentiel).
- Le LLM peut "halluciner" un click sur un élément invisible — `extract_schema` strict + validation Zod côté caller obligatoire.
- Headless Chromium a une fuite mémoire connue après ~100 sessions — relancer le container tenant 1×/semaine.

## Verification

Après chaque appel, le caller doit valider :
1. `ok === true`
2. `data` matche le `extract_schema` fourni (Zod ou jsonschema)
3. `duration_ms < 60000` (sinon timeout)
4. Screenshot affiche bien le contenu attendu (audit human-review déclenché si doute)
