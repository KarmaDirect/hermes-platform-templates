---
name: cron-sync
description: Persiste un cron dans Supabase tenant_crons (la table que la page /cron du dashboard affiche). Utilise ce skill au lieu du tool natif `cronjob` désactivé pour ce profil — c'est le seul moyen pour que le cron soit visible et géré dans l'UI.
version: 2.0.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [productivity, cron, scheduling, dashboard-bridge]
    category: productivity
    triggers: [manual]
---

# cron-sync

## When to Use

Utilisateur dit « crée un cron », « planifie », « tous les matins », « chaque lundi », « toutes les X minutes ». Tu dois **toujours** passer par ce skill (le tool natif `cronjob` est désactivé sur cette interface chat).

## Quick Reference

**Input** :
```json
{
  "name": "recap_matin_8h",
  "schedule": "0 8 * * *",
  "instruction": "Fais-moi un récap matinal : météo La Rochelle, tâches du jour, emails non lus.",
  "agent_id": null,
  "skill_id": "briefing-quotidien"
}
```

**Output** : `{"success": true, "cron_id": "uuid"}`.

## Procedure

**Important** : utilise le tool `terminal` (PAS `execute_code` qui tourne dans un sandbox isolé sans accès aux env vars `SUPABASE_*`). Le terminal hérite de l'env du container.

**Une seule étape** : appelle `terminal` avec ce one-liner Python (modifie `NAME`, `SCHEDULE`, `INSTRUCTION`, `AGENT_ID`, `SKILL_ID`).

```bash
python3 - <<'PYEOF'
import os, json, urllib.request, urllib.error

NAME        = "recap_matin_8h"
SCHEDULE    = "0 8 * * *"
INSTRUCTION = "Fais-moi un récap matinal : météo La Rochelle, tâches du jour, emails non lus."
AGENT_ID    = None
SKILL_ID    = None

url = f"{os.environ['SUPABASE_URL']}/rest/v1/tenant_crons"
key = os.environ['SUPABASE_SERVICE_ROLE_KEY']

body = {
    "org_id":      os.environ['ORG_ID'],
    "name":        NAME,
    "schedule":    SCHEDULE,
    "instruction": INSTRUCTION,
    "enabled":     True,
    "agent_id":    AGENT_ID,
    "skill_id":    SKILL_ID,
}

req = urllib.request.Request(
    url,
    data=json.dumps(body).encode("utf-8"),
    headers={
        "apikey":        key,
        "Authorization": f"Bearer {key}",
        "Content-Type":  "application/json",
        "Prefer":        "return=representation",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        resp = json.loads(r.read().decode())
        print("OK", json.dumps(resp[0] if isinstance(resp, list) else resp, ensure_ascii=False))
except urllib.error.HTTPError as e:
    print("ERR", e.code, e.read().decode()[:300])
PYEOF
```

Le heredoc `'PYEOF'` (single-quoted) empêche toute interpolation shell — apostrophes françaises et `${var}` ne sont jamais interprétés.

## Cron expression reference

- « tous les matins à 8h » → `0 8 * * *`
- « chaque lundi à 9h » → `0 9 * * 1`
- « toutes les 30 min » → `*/30 * * * *`
- « tous les jours ouvrés à 10h » → `0 10 * * 1-5`
- Si flou (« souvent », « régulièrement »), demande précision avant.

## Format de réponse à l'utilisateur

Après succès :
```
✅ Cron créé : `recap_matin_8h`
Tous les jours à 8h, je te ferai un récap (météo, tâches, emails).

[[goto:/cron|Voir mes crons]]
```

En cas d'erreur HTTP, dis simplement « pas pu enregistrer le cron, raison : <message court> » sans étaler la stack.
