---
name: integration-list
description: Liste les intégrations Composio actuellement connectées pour ce tenant en lisant Supabase tenant_integrations. À appeler avant toute réponse sur "quelles intégrations sont connectées" — ne jamais deviner.
version: 1.0.1
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [integrations, composio, dashboard-bridge]
    category: productivity
    triggers: [manual]
---

# integration-list

## When to Use

L'utilisateur demande quelles intégrations sont connectées (« quelles intégrations », « est-ce que Gmail est branché », « mes outils connectés », « je peux faire X avec Stripe ? »).

Tu **ne dois jamais deviner** — la vérité vit dans Supabase `tenant_integrations`. Ce skill la lit pour toi.

## Quick Reference

**Input** : aucun.
**Output** : liste structurée `[{provider, status, display_account, connected_at}]`.

## Procedure

1. Variables d'env (déjà injectées) :
   - `SUPABASE_URL` (ex: `http://supabase-kong:8000`)
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `ORG_ID`

2. Requête HTTP via `terminal` :

```bash
curl -sS "${SUPABASE_URL}/rest/v1/tenant_integrations?org_id=eq.${ORG_ID}&select=provider,status,display_account,backend,last_used_at,last_error" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Accept: application/json"
```

3. Parse la réponse JSON. Filtre par `status` :
   - `active` → "connecté"
   - `pending` → "en attente d'OAuth"
   - `error` → "erreur (avec last_error)"

4. Si la liste est vide : retourne explicitement `{"connected": [], "message": "Aucune intégration connectée"}`. Ne propose pas de noms imaginaires.

5. Si erreur HTTP, retourne `{"success": false, "error": "<msg>"}` ; ne pas inventer.

## Format de réponse à l'utilisateur

Réponds en 2-4 lignes max :

```
Voici tes intégrations actives :
- Gmail (compte joshua@webstate.fr, depuis le 28/04)
- Stripe (compte Webstate SAS, depuis le 30/04)

[[goto:/integrations|Gérer mes intégrations]]
```

Si rien :

```
Aucune intégration connectée pour l'instant.
[[goto:/integrations|Connecter Gmail / Outlook / Stripe…]]
```

## Style

- Pas de checklist exhaustive de toutes les intégrations possibles. Juste **ce qui est réellement connecté**.
- Pas de jargon (pas de "Composio MCP", pas de "OAuth flow"). Juste le nom du service.
