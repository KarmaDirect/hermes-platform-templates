---
name: enrichissement-leads-webstate
description: Enrichit automatiquement les leads B2B reçus dans Webstate (table leads ou contacts source=website_form) avec les données SIREN via Pappers. Score le lead, détecte les doublons, propose une priorité d'action. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, leads, b2b, enrichment, pappers]
    category: commercial
    triggers: [webhook, cron]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Enrichissement Leads Webstate

## When to Use

Trigger automatique sur :
- Cron 30 min : scan `leads` + `contacts` non enrichis (`source IN ('website_form','public_form','api')` AND `metadata.enriched != true`)
- Webhook `receive-website-lead` (Webstate Edge Fn) : push direct du formulaire

## Quick Reference

**Workflow par lead** :
1. Skip check `WEBSTATE_REFRESH_TOKEN`.
2. Si SIREN/SIRET absent dans le lead :
   - Si email pro (pas gmail/yahoo/etc) → extract domain → recherche Pappers via `pappers-search` Edge Fn Webstate (`mode: "search"`, `query: domain`).
   - Si SIRET trouvé → enrichit lead avec `company_name, siret, naf_code, effectif, ca_annuel`.
3. Si SIREN connu → `mode: "company"` → fetch full data (dirigeants, capital, parution, statut).
4. **Scoring** : 
   - Effectif < 5 → score 30 (TPE artisan)
   - Effectif 5-50 → score 60 (PME idéale)
   - Effectif 50+ → score 80 (mid-market premium)
   - Activité matchant vertical du tenant (BTP, Restauration, etc.) → +20
   - Lead chaud (créé < 24h) → +15
   - Total max 100.
5. Update contact via `crm-webstate.update_contact` :
   - `metadata.enriched = true`, `metadata.score = 75`, `metadata.siret = "...",
     metadata.naf = "...", metadata.effectif = ...`
   - `tags = ['enriched', 'lead-chaud-50plus']`
6. Si score >= 80 → trigger `secretaire-webstate.callback` avec priorité haute, OU notification Telegram patron via reporting-ceo-webstate.

## Pitfalls

- **Quota Pappers** : free tier = 250 req/mois. Cache résultats 30j (table `b2b_siren_enrichment` Webstate déjà existante).
- **Email perso** (gmail/yahoo) : skip enrichissement, juste tag `tags=['lead-perso']`.
- **Lead doublon** : si SIRET match contact existant avec status='client', flagger comme `metadata.is_returning_customer=true`.

## Toggle

Désactivé par défaut. Activer = ajouter `enrichissement-leads-webstate` à
`enabled_skills`. Pas de credential supplémentaire requise (pappers-search
côté Webstate utilise sa propre clé Pappers org).

## Handoff

- `crm-webstate` : pour update contacts/leads
- `secretaire-webstate` : si score haut → callback prioritaire
- `reporting-ceo-webstate` : leads chauds dans le brief matin
