---
name: avis-google-webstate
description: Envoie SMS demande avis Google après facture marquée payée. Suit la conversion (ouvertures, clics) via la table reviews. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, avis, marketing, retention]
    category: marketing
    triggers: [webhook, cron]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID, GOOGLE_PLACE_ID]
---

# Avis Google Webstate

## When to Use

Cron 6h chaque jour : scan factures `status='paid'` ET `paid_at < now()-24h` ET
pas encore taggées `metadata.avis_demanded`. Envoie 1 SMS par client.

## Quick Reference

**Workflow** :
1. Skip si `WEBSTATE_REFRESH_TOKEN` ou `GOOGLE_PLACE_ID` absent.
2. Query factures paid récentes via `crm-webstate.list_invoices`.
3. Pour chacune, get contact (`/rest/v1/contacts?id=eq.{contact_id}`).
4. Vérifier que le client a déjà un avis (table `reviews` côté Webstate
   ou via Google API si configurée). Si oui, skip.
5. SMS via `crm-webstate.send_sms` :
   ```
   Bonjour {first_name}, merci pour votre confiance ! Si vous avez 30s,
   votre avis Google nous aide énormément : https://g.page/r/{PLACE_ID}/review
   À bientôt, {org_name}
   ```
6. Insert dans `reviews` Webstate avec `status='requested'` + `requested_at`.
7. Tag facture `metadata.avis_demanded=true` (PATCH via `hermes-write-table`).

**Tracking** : si Google Business API configuré, cron quotidien check des
nouveaux avis et fait le matching contact (par nom + ville). Update
`reviews.status='received'` et notifie patron Telegram.

## Pitfalls

- **Anti-harcèlement** : 1 SMS demande max par contact tous les 6 mois. Check
  `reviews` historique avant envoi.
- **Pas après mauvaise expérience** : si dernier `activities` sur ce contact
  contient `metadata.sentiment='negative'` (par skill `feedback-webstate` ou
  inspection NPS), SKIP.
- **Heures ouvrées** : SMS entre 9h et 19h heure tenant uniquement.

## Toggle

Désactivé par défaut. Pour activer : 
1. Push credential `GOOGLE_PLACE_ID` (= identifiant Google My Business du client) via Push credential modal admin.
2. Ajouter `avis-google-webstate` à `enabled_skills`.
3. Restart container.

## Handoff

- `crm-webstate` : list invoices, send_sms, update contact
- `confirmation-hub` : optionnel si on veut HITL avant envoi SMS bulk
