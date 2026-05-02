---
name: integration-list
description: Liste les intégrations Composio actuellement connectées pour ce tenant en lisant Supabase tenant_integrations. À appeler avant toute réponse sur "quelles intégrations sont connectées" — ne jamais deviner.
version: 2.0.0
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

Utilisateur demande quelles intégrations sont connectées (« quelles intégrations », « est-ce que Gmail est branché », « mes outils connectés »). Tu **ne dois jamais deviner** — la vérité vit dans `tenant_integrations`.

## Quick Reference

**Input** : aucun.
**Output** : liste structurée `[{provider, status, display_account, ...}]`.

## Procedure

**Important** : utilise le tool `terminal` (PAS `execute_code` qui tourne dans un sandbox isolé sans accès aux env vars `SUPABASE_*`).

**Une seule étape** : appelle `terminal` avec ce one-liner Python.

```bash
python3 - <<'PYEOF'
import os, json, urllib.request, urllib.error

url = (
    f"{os.environ['SUPABASE_URL']}/rest/v1/tenant_integrations"
    f"?org_id=eq.{os.environ['ORG_ID']}"
    f"&select=provider,status,display_account,backend,last_used_at,last_error"
)
key = os.environ['SUPABASE_SERVICE_ROLE_KEY']

req = urllib.request.Request(
    url,
    headers={
        "apikey":        key,
        "Authorization": f"Bearer {key}",
        "Accept":        "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        rows = json.loads(r.read().decode())
        print("OK", json.dumps(rows, ensure_ascii=False))
except urllib.error.HTTPError as e:
    print("ERR", e.code, e.read().decode()[:300])
PYEOF
```

## Format de réponse à l'utilisateur

Si liste non vide :
```
Voici tes intégrations actives :
- Gmail (compte joshua@webstate.fr, depuis le 28/04)
- Stripe (compte Webstate SAS, depuis le 30/04)

[[goto:/integrations|Gérer mes intégrations]]
```

Si vide :
```
Aucune intégration connectée pour l'instant.
[[goto:/integrations|Connecter Gmail / Outlook / Stripe…]]
```

## Style

- Pas de checklist exhaustive de toutes les intégrations possibles. Juste **ce qui est réellement connecté**.
- Pas de jargon (pas de "Composio MCP", pas de "OAuth flow"). Juste le nom du service.
