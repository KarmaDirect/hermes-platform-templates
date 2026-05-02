---
name: task-sync
description: Persiste une tâche dans Supabase tenant_tasks (la table que la page /tasks du dashboard affiche). À appeler après le tool natif `todo` pour que la tâche soit visible côté UI.
version: 1.0.1
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

Le tool natif `todo` Hermès écrit dans un store local — la page `/tasks` du dashboard ne le voit pas (elle lit la table Supabase `tenant_tasks`). Ce skill comble ce silo : appelle d'abord `todo(action="add", ...)` puis ce skill pour rendre la tâche visible dans l'UI.

Trigger : utilisateur dit « ajoute une tâche », « rappelle-moi de... », « note qu'on doit faire X ».

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

**Output** : `{"success": true, "task_id": "uuid"}` ou erreur explicite.

## Procedure

1. Variables d'env (déjà injectées dans le container) :
   - `SUPABASE_URL` (ex: `http://supabase-kong:8000`)
   - `SUPABASE_SERVICE_ROLE_KEY` (JWT service_role, full access)
   - `ORG_ID` (UUID de l'organisation tenant)

2. Appelle `terminal` avec ce shell (échappe correctement le titre) :

```bash
TITLE=$(jq -Rs . <<< "<titre tâche>")
curl -sS -X POST "${SUPABASE_URL}/rest/v1/tenant_tasks" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{
    \"org_id\": \"${ORG_ID}\",
    \"title\": ${TITLE},
    \"column_name\": \"todo\",
    \"priority\": \"medium\"
  }"
```

3. Valeurs valides (sinon CHECK constraint rejette) :
   - `column_name` : `backlog` | `todo` | `in_progress` | `review` | `done`
   - `priority` : `high` | `medium` | `low`

4. Parse la réponse JSON pour récupérer `id`. Renvoie `{"success": true, "task_id": "<id>"}`.

5. En cas d'erreur HTTP :
   - 401/403 : `SUPABASE_SERVICE_ROLE_KEY` absent → vérifier env du container.
   - 404 : table absente — n'invente pas, prévenir l'utilisateur.
   - 400 : check les contraintes column_name/priority ci-dessus.

## Style

- Confirme à l'utilisateur en 1 phrase : « Tâche ajoutée à ta liste. Visible dans /tasks. »
- En cas d'erreur, résume « pas pu enregistrer côté dashboard, mais c'est dans ta todo locale » et propose `[[goto:/tasks|Voir mes tâches]]`.
