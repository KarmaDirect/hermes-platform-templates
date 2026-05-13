---
name: crm-webstate
description: Pilote le CRM Webstate SaaS (contacts, leads, devis, factures, agenda, équipe, stock) du compte client lié via OAuth admin. Pas un mock — appelle vraiment l'API Webstate via JWT bot user. Lit/écrit les contacts, crée des devis/factures, programme des RDV, suit la facturation.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-client-lookup
metadata:
  hermes:
    tags: [crm, webstate, btp, sales, saas-bridge]
    category: crm
    triggers: [webhook, channel-message, cron]
---

# CRM Webstate

## When to Use

Le tenant Hermès est lié via l'admin à un compte Webstate SaaS (CRM/devis/factures/agenda du client). Ce skill permet à l'agent IA Hermès de **piloter ce CRM à distance** : lister les contacts, créer un devis, ajouter un RDV, marquer une facture payée, vérifier les impayés, etc.

L'utilise quand le client demande naturellement :
- « Combien de prospects j'ai dans mon CRM ? »
- « Crée un devis pour Marc Dupont à 1500 € pour rénovation salle de bain »
- « Bloque-moi un créneau demain à 14h pour la visite chantier rue de la Paix »
- « Quelles factures sont en retard ? »
- « Ajoute Lucas Bertin au CRM, c'est un nouveau prospect »

Si **aucun compte Webstate n'est lié** (env vars `WEBSTATE_*` absentes) → réponds que la liaison Webstate n'est pas configurée et que l'admin doit le faire dans `/admin/tenants/{org}/diagnostics`.

## Quick Reference

### Env vars requises (poussées par l'admin via Edge Fn `link-webstate-account`)

- `WEBSTATE_API_URL` — ex: `https://api.webstate.fr`
- `WEBSTATE_REFRESH_TOKEN` — JWT refresh long-lived du bot user
- `WEBSTATE_ORG_ID` — UUID de l'org Webstate
- `WEBSTATE_BOT_EMAIL` (optionnel, pour re-signin si refresh expire)
- `WEBSTATE_BOT_PASSWORD` (optionnel)

### Flow d'auth

1. Au premier appel : `POST {WEBSTATE_API_URL}/auth/v1/token?grant_type=refresh_token` avec `{refresh_token: WEBSTATE_REFRESH_TOKEN}` → récupère `access_token` + nouveau `refresh_token` valide ~1h
2. Cache `access_token` en mémoire (50 minutes max)
3. À expiration : refresh à nouveau
4. Si refresh échoue : fallback signin password (si `BOT_EMAIL/PASSWORD` dispo)

### Tools exposés au LLM

| Tool | Method | Endpoint | Description |
|------|--------|----------|-------------|
| `webstate_list_contacts` | GET | `/rest/v1/contacts?org_id=eq.{ORG_ID}&select=*` | Liste contacts |
| `webstate_get_contact` | GET | `/rest/v1/contacts?id=eq.{id}` | Détails 1 contact |
| `webstate_create_contact` | POST | `/functions/v1/hermes-write-contact` | Crée contact (via wrapper) |
| `webstate_update_contact` | POST | `/functions/v1/hermes-write-contact` (action=update) | Update contact |
| `webstate_list_quotes` | GET | `/rest/v1/quotes?org_id=eq.{ORG_ID}&select=*` | Liste devis |
| `webstate_create_quote` | POST | `/rest/v1/quotes` | Crée devis (PostgREST direct, RLS membership-OK) |
| `webstate_send_quote` | POST | `/functions/v1/generate-and-send-quote` | Envoie devis email+SMS+PDF |
| `webstate_list_invoices` | GET | `/rest/v1/invoices?org_id=eq.{ORG_ID}` | Liste factures |
| `webstate_create_invoice` | POST | `/functions/v1/hermes-write-invoice` | Crée facture (via wrapper) |
| `webstate_create_payment_link` | POST | `/functions/v1/create-invoice-payment-link` | Lien Stripe |
| `webstate_list_appointments` | GET | `/rest/v1/appointments?org_id=eq.{ORG_ID}` | Liste RDV |
| `webstate_create_appointment` | POST | `/rest/v1/appointments` | Crée RDV |
| `webstate_list_team_members` | GET | `/rest/v1/organization_members?org_id=eq.{ORG_ID}` | Liste équipe |
| `webstate_list_stock_items` | GET | `/rest/v1/stock_items?org_id=eq.{ORG_ID}` | Liste stock |

Pour CHAQUE call : header `Authorization: Bearer {access_token}` + header `apikey: {anon_key}` (récupérable via env `WEBSTATE_ANON_KEY` si poussée, sinon optionnel pour les routes /rest/v1 si JWT user valide).

## Workflow exemple — "Crée un devis pour Marc Dupont"

1. Recherche contact "Marc Dupont" dans Webstate via `webstate_list_contacts?or=(first_name.ilike.%25Marc%25,last_name.ilike.%25Dupont%25)`
2. Si trouvé : récupère son `contact_id`
3. Si pas trouvé : `webstate_create_contact` (first_name=Marc, last_name=Dupont, source=hermes_chat) → reçoit le nouveau `contact_id`
4. `webstate_create_quote` avec :
   - `org_id` = WEBSTATE_ORG_ID
   - `contact_id`
   - `quote_data` = JSON des lignes (label, qty, unit_price_eur, total_eur)
   - `total_amount` = somme TTC
   - `status` = "draft"
5. Confirme au client : "Devis créé, ID `xxx`. Veux-tu que je l'envoie par email à Marc ?"
6. Si oui : `webstate_send_quote(quote_id)` → email+SMS+PDF générés et envoyés

## Pitfalls

- **NE JAMAIS leak le refresh_token** dans la réponse au client. Si erreur API, redirige vers "il faut que l'admin re-lie le compte" sans exposer la cause.
- **Auth expirée (401 sur appel)** : essaie refresh access_token UNE fois. Si encore 401, fallback signin password. Si encore échec, marque le tenant_integration en `expired` et alerte l'admin via skill `confirmation-hub`.
- **Cross-tenant safety** : TOUS les calls inclus `org_id=eq.{WEBSTATE_ORG_ID}` (env var). Si on omet le filtre, RLS Webstate appliquera quand même la membership, mais c'est une defense-in-depth.
- **Edge Fn wrappers (hermes-write-contact, hermes-write-invoice)** : pour les opérations bloquées par RLS owner-only. Pas pour quotes/appointments qui passent en direct.
- **Format des output au client** : résume en français naturel, pas de JSON brut. Ex : "12 contacts, dont 3 nouveaux ce mois" au lieu de l'array JSON.
- **Pas de delete factures** : volontaire. Une facture annulée = `status="cancelled"` via update, pas un DELETE.

## Channels d'invocation

- **Chat web/Telegram** : keywords contacts, devis, facture, RDV, agenda, calendrier, planning, prospect, lead, client, fournisseur
- **Webhook** : `POST /webstate/{action}` avec body custom
- **Cron** : skill `briefing-quotidien` peut chaîner sur `webstate_list_invoices?status=overdue` chaque matin

## Configuration env vars (rappel)

Set par l'Edge Fn Hermès `link-webstate-account` quand l'admin lie un compte. Vérifier au démarrage du skill que les 3 vars principales sont présentes :
```
WEBSTATE_API_URL
WEBSTATE_REFRESH_TOKEN
WEBSTATE_ORG_ID
```
Sinon, le skill annonce au LLM "compte Webstate non configuré" et propose à l'admin la procédure de liaison.

## Handoff vers d'autres skills

- **`devis-photo`** : si le client envoie une photo, devis-photo génère le brouillon JSON, ce skill le pousse dans Webstate via `webstate_create_quote`
- **`relance-impayes`** côté Hermès est désactivé pour les tenants Webstate-linked (Webstate gère ses propres crons J+3/J+10/J+20). Ce skill se contente de **lister** les overdue.
- **`crm-doublons`** : si on crée un contact, vérifier d'abord les doublons existants avant l'insert
- **`confirmation-hub`** : pour HITL avant les actions destructives (delete contact, modifier facture déjà envoyée)
