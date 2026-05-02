---
name: cron-sync
description: Persiste un cron dans Supabase tenant_crons (la table que la page /cron du dashboard affiche). À appeler au lieu (ou en plus) du tool natif `cronjob` quand l'utilisateur veut que le cron soit visible et géré dans l'UI.
version: 1.0.0
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

Le tool natif `cronjob` Hermès enregistre dans le store interne du container — la page `/cron` du dashboard ne le voit pas (elle lit `tenant_crons` Supabase). Ce skill comble le silo : appelle-le quand l'utilisateur dit « crée un cron », « planifie », « tous les matins », « chaque lundi ».

Tu peux soit (a) appeler `cron-sync` directement, soit (b) appeler `cronjob` puis `cron-sync` en doublon — option (a) suffit pour 95% des cas.

## Quick Reference

**Input** :
```json
{
  "name": "recap_matin_8h",
  "schedule": "0 8 * * *",
  "instruction": "Fais-moi un récap matinal : emails non lus, tâches en cours, RDV du jour.",
  "agent_id": "lea-secretaire",
  "skill_id": "briefing-quotidien"
}
```

**Output** : `{"success": true, "cron_id": "uuid"}`.

## Procedure

1. Variables d'env (déjà injectées) :
   - `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ORG_ID`

2. Convertis la requête utilisateur en cron expression standard 5-fields :
   - « tous les matins à 8h » → `0 8 * * *`
   - « chaque lundi à 9h » → `0 9 * * 1`
   - « toutes les 30 minutes » → `*/30 * * * *`
   - « tous les jours ouvrés à 10h » → `0 10 * * 1-5`
   - Si flou, demande précision avant d'appeler le skill.

3. Requête HTTP via `terminal` :

```bash
NAME=$(jq -Rs . <<< "<nom court snake_case>")
INSTRUCTION=$(jq -Rs . <<< "<prompt complet pour l agent au moment du run>")
curl -sS -X POST "${SUPABASE_URL}/rest/v1/tenant_crons" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{
    \"org_id\": \"${ORG_ID}\",
    \"name\": ${NAME},
    \"schedule\": \"<cron expression>\",
    \"instruction\": ${INSTRUCTION},
    \"enabled\": true,
    \"agent_id\": \"<slug agent ou null>\",
    \"skill_id\": \"<slug skill ou null>\"
  }"
```

4. Parse la réponse JSON pour récupérer `id`. Renvoie `{"success": true, "cron_id": "<id>"}`.

5. Erreurs typiques :
   - 400 : `schedule` invalide (5 champs requis : minute heure jour mois jour-semaine).
   - 23505 (unique violation) : un cron du même nom existe déjà — propose un nom différent ou une mise à jour.

## Format de réponse à l'utilisateur

```
Cron créé : recap_matin_8h
Tous les jours à 8h, je te ferai un récap (emails, tâches, RDV).

[[goto:/cron|Voir mes crons]]
```

## Style

- Confirme avec **le nom du cron + l'horaire en français + l'action** en 1 phrase.
- Si l'utilisateur veut modifier ou désactiver, oriente vers `/cron` page (pas de `cron-sync` update pour l'instant).
