---
name: pilote-automations-webstate
description: Permet au client de toggle ON/OFF en langage naturel n'importe laquelle des 41 automations natives Webstate (sms_reminder_j1, payment_thanks, weather_alert, treasury_alert, etc.). Lit/configure la table smart_automations via wrapper Edge Fn. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, automations, settings, control]
    category: configuration
    triggers: [channel-message]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Pilote Automations Webstate

## When to Use

Le client demande à modifier le comportement automatique de Webstate :
- "Désactive les SMS d'anniversaire"
- "Active la relance impayé J+10"
- "Active le rappel RDV J-1"
- "Quelles automations sont activées ?"
- "Modifie le template SMS de relance devis"

## Quick Reference

### Liste des 41 automations supportées

**Secrétariat** : sms_reminder_j1, sms_reminder_h4, missed_call_sms, no_show_followup, rdv_recap_email, weekend_autoreply, sms_welcome

**Commercial** : quote_relance_3, quote_relance_7, speed_to_lead, avis_google, quote_viewed_alert, expired_quote_offer, ghost_quote, sms_anniversary

**Facturation** : payment_thanks, auto_invoice, invoice_relance_3, invoice_relance_10, mise_demeure, invoice_due_soon, recurring_invoice

**Opérationnel** : treasury_alert, satisfaction_nps, annual_maintenance, post_work_portfolio, reactivation, propose_maintenance, attestation_fiscale, sponsorship

**BTP** : marge_chantier, suivi_chantier_etapes, pipeline_forecast, confirm_photo, weather_alert, stock_alert

**Intelligence** : daily_report, morning_brief, b2b_siren_enrichment, email_triage, auto_reply_faq, weekly_report, birthday_contact

### Workflow

1. Skip si `WEBSTATE_REFRESH_TOKEN` absent.
2. Parse intent : `list`, `enable <type>`, `disable <type>`, `configure <type>`.
3. **list** : `GET /rest/v1/smart_automations?org_id=eq.{ORG}&select=type,is_active,config` via crm-webstate. Réponse formatée :
   ```
   ✅ Activées (12) :
   - sms_reminder_j1 (rappel RDV J-1, 18h)
   - quote_relance_3 (relance devis J+3)
   - payment_thanks (SMS merci paiement)
   ...
   
   ⏸ Désactivées (29) :
   - sms_anniversary, treasury_alert, ...
   ```
4. **enable / disable** : POST `/functions/v1/hermes-write-table` :
   ```
   {"action": "update", "table": "smart_automations",
    "org_id": "...", "id": "...",
    "data": {"is_active": true|false}}
   ```
   Si la row n'existe pas pour ce type, create.
5. **configure** : update `config` JSON (ex: pour quote_relance_3, modifier
   le template SMS, le délai, le ton). Demande HITL si changement majeur via
   `confirmation-hub`.

## Pitfalls

- **Anti-doublon Hermès** : si l'admin active `relance-impayes` Hermès en même
  temps que `invoice_relance_3` Webstate, prévenir l'utilisateur :
  "Attention, les 2 systèmes vont envoyer en doublon".
- **Crons natifs** : activer une automation Webstate déclenche les crons natifs.
  Les actions Hermès n'overrident PAS, elles cohabitent (sauf pour
  relance-impayes désactivé par bootstrap).
- **Permissions** : la table `smart_automations` a RLS owner-only. Le wrapper
  `hermes-write-table` bypasse via service_role après check membership.

## Toggle

Désactivé par défaut. Activer = ajouter au CSV `enabled_skills`.

## Handoff

- `crm-webstate` : pour list/update smart_automations via wrapper
- `confirmation-hub` : HITL avant changements majeurs
