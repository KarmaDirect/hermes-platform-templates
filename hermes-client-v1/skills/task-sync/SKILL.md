---
name: task-sync
description: Persiste une tâche dans Supabase tenant_tasks (la table que la page /tasks du dashboard affiche). Utilise ce skill au lieu du tool natif `todo` désactivé pour ce profil — c'est le seul moyen pour que la tâche soit visible et éditable dans l'UI.
version: 2.0.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [productivity, todo, dashboard-bridge]
    category: productivity
    triggers: [manual]
---

# task-sync

## When to Use

Utilisateur dit « ajoute une tâche », « rappelle-moi de... », « note qu'on doit faire X ». Tu dois **toujours** passer par ce skill (le tool natif `todo` est désactivé sur cette interface chat).

## Quick Reference

**Input** :
```json
{
  "title": "Appeler le client Dupont pour le devis salle de bain",
  "priority": "high",
  "column_name": "todo",
  "due_date": "2026-05-03T09:00:00Z"
}
```

**Output** : `{"success": true, "task_id": "uuid"}`.

## Procedure

**Important** : utilise le tool `terminal` (PAS `execute_code` qui tourne dans un sandbox isolé sans accès aux env vars `SUPABASE_*`).

**Une seule étape** : appelle `terminal` avec ce one-liner Python (modifie `TITLE`, `PRIORITY`, `COLUMN`, `DUE_DATE`).

```bash
python3 - <<'PYEOF'
import os, json, urllib.request, urllib.error

TITLE      = "Appeler le client Dupont pour le devis salle de bain"
PRIORITY   = "medium"     # "low" | "medium" | "high"
COLUMN     = "todo"       # "backlog" | "todo" | "in_progress" | "review" | "done"
DUE_DATE   = None         # ISO 8601 string ou None

url = f"{os.environ['SUPABASE_URL']}/rest/v1/tenant_tasks"
key = os.environ['SUPABASE_SERVICE_ROLE_KEY']

body = {
    "org_id":      os.environ['ORG_ID'],
    "title":       TITLE,
    "column_name": COLUMN,
    "priority":    PRIORITY,
}
if DUE_DATE:
    body["due_date"] = DUE_DATE

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

Le heredoc `'PYEOF'` (single-quoted) empêche toute interpolation shell — apostrophes françaises et `${var}` sont préservés.

## Format de réponse à l'utilisateur

```
✅ Tâche ajoutée : « <title> »
Priorité : <priority>. Visible dans /tasks.

[[goto:/tasks|Voir mes tâches]]
```

En cas d'erreur, dis « pas pu enregistrer côté dashboard, raison : <courte> » sans stack.
