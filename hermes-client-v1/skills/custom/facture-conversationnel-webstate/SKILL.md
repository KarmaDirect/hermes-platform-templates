---
name: facture-conversationnel-webstate
description: Crée une facture Webstate à partir d'une conversation naturelle avec validation HITL stricte avant envoi. Récap visuel + checklist (client, lignes, TVA, remise, échéance, mode paiement) + PDF aperçu dans le chat après envoi. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, facture, sales, hitl]
    category: facturation
    triggers: [channel-message]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Facture Conversationnel Webstate

## When to Use

Le patron demande "fais une facture pour Marc Dupont 1500€", "facture le
chantier rue Pasteur", "transforme le devis #024 en facture". Le skill
gère un workflow HITL strict avec récap+confirmation avant tout envoi.

## Quick Reference

**Input** :
```json
{
  "contact_query": "Marc Dupont",
  "scope": "rénovation salle de bain (devis #024)",
  "from_quote_id": "uuid (optionnel : transforme un devis signé en facture)",
  "vat_mode": "10%|20%|5.5%",
  "payment_mode": "transfer|stripe|cash|check",
  "due_days": 30,
  "send_now": false
}
```

**Output** : `{ invoice_id, invoice_number, total_ttc, pdf_url, payment_link?, ready_to_send, next_action }`

## Workflow STRICT HITL

### Phase 1 — Compréhension
1. Skip check `WEBSTATE_REFRESH_TOKEN`.
2. **Match contact** via crm-webstate.
3. Si `from_quote_id` fourni :
   - Charger le devis original
   - Vérifier `status` : `signed` → factuable, `sent`/`draft` → demander
     pourquoi facturer (devis pas signé, c'est inhabituel)
   - Reprendre les `items` du devis comme défaut
4. Sinon : composer items depuis la conversation (comme devis-conversationnel-webstate).

### Phase 2 — Récap + checklist HITL

Avant INSERT, poster au patron :

```
🧾 RÉCAP FACTURE AVANT ENVOI

👤 CLIENT
   Marc Dupont — marc@bouygues.fr — 06 12 34 56 78
   ⚠️ vérification SIRET : 552 120 222 (Bouygues SA)
   [ confirme ] [ changer client ]

🔧 LIGNES (3) — issues du devis DEV-2026-024 signé le 12/05/2026
   1. Visite technique          1 forfait    80,00 €
   2. Fourniture matériaux      1 lot       350,00 €
   3. Pose carrelage            6 m²    270,00 €

💰 TOTAUX
   Sous-total HT : 700,00 €
   TVA 10%       : 70,00 €
   TOTAL TTC     : 770,00 €

📅 ÉCHÉANCE
   Date émission : aujourd'hui (06/05/2026)
   Date échéance : 05/06/2026 (J+30)

💳 MODE DE PAIEMENT
   Stripe (lien de paiement créé automatiquement)
   ⚠️ Pénalités retard : taux BCE + 10 points (auto)
   ⚠️ Indemnité forfaitaire : 40€ (auto, mention obligatoire L441-10)

❓ CHECKLIST PATRON
   ✓ Client vérifié (SIREN, adresse de facturation correcte) ?
   ✓ Lignes complètes (pas oublié supplément, frais déplacement) ?
   ✓ TVA correcte ?
   ✓ Pas de remise à appliquer ?
   ✓ Échéance 30 jours adaptée (sinon préciser : 7j ? 60j ?)
   ✓ Mode paiement bon (Stripe, virement, chèque, espèces) ?
   ✓ Acompte déjà payé ? (si oui ajuster montant)

👉 Pour envoyer : "OK envoie" / "Oui valide"
👉 Pour ajuster : précise quoi changer
👉 Pour annuler : "Non"
```

### Phase 3 — Attendre validation explicite

**JAMAIS d'INSERT sans réponse positive du patron.**

### Phase 4 — Insert + envoi (post-validation)

1. INSERT facture via wrapper `hermes-write-invoice` :
   ```
   POST /functions/v1/hermes-write-invoice
   {action:"create", org_id:ORG, data:{
     contact_id, quote_id (si from_quote_id),
     invoice_data: {items: [...], totals: {...}, conditions: {...}},
     total_amount: 770,
     issued_at: today,
     due_date: today + due_days,
     status: "draft"
   }}
   ```
2. Récupère `invoice_id`.
3. Si `payment_mode == "stripe"` :
   - Appelle `POST /functions/v1/create-invoice-payment-link`
   - Récupère `payment_link` (URL Stripe Checkout).
4. (Optionnel) Génère PDF via `generate-facturx` Edge Fn (e-facture
   conforme 2026, format Factur-X PDF/A-3) :
   ```
   POST /functions/v1/generate-facturx
   {invoice_id}
   ```
5. Met facture `status="sent"`, ajoute `pdf_url` + `stripe_payment_link`.
6. Optionnel : envoie email + SMS au client (à voir si Webstate cron auto-envoie ou si on déclenche).

### Phase 5 — Confirmation + PDF + lien Stripe

Réponse finale au patron :

```
✅ Facture émise et envoyée

FACT-2026-058 · 770€ TTC · échéance 05/06/2026

[📄 PDF Facture](https://api.webstate.fr/storage/.../FACT-058.pdf)

💳 Lien de paiement Stripe (à transmettre au client) :
[💳 Payer 770€ TTC](https://buy.stripe.com/test_xxx)

Webstate enverra automatiquement :
• Rappel J-3 avant échéance
• Relance J+1 si impayé
• Relance J+10 (formelle)
• Mise en demeure J+30

Tu veux personnaliser le ton des relances ?
```

## Pitfalls

- **JAMAIS facturer un devis non signé** sans validation explicite patron
- **TVA mode auto-liquidation** (BTP B2B sous-traitance) : pour les
  organisations avec `btp_settings.tva_mode='autoliquidation'`, ne pas
  appliquer la TVA, mention spéciale "TVA due par le preneur (art 283-2 CGI)"
- **Acompte déjà perçu** : si le devis avait un acompte signé+payé, soustraire
  du total facture finale (mode `installments` du RPC `create_invoice_from_quote`)
- **Numérotation** : utilise toujours `generate_invoice_number(org_id)` RPC,
  jamais d'invoice_number manuel (continuité légale obligatoire)
- **Pas de DELETE** : facture émise = comptablement intouchable. Pour annuler,
  émettre un avoir (facture négative) via skill séparé `avoir-webstate` (V1.1).

## Toggle

Désactivé par défaut. Activer = `enabled_skills` CSV.

## Handoff

- `crm-webstate` : list contacts, list quotes (pour from_quote_id)
- `devis-conversationnel-webstate` : si patron veut transformer un devis
  qui n'existe pas encore → délègue d'abord à devis-conversationnel
- `recouvrement-webstate` (V1.1) : pour les impayés post-J+30
- `confirmation-hub` : pour les cas custom (acompte, dispute, avoir)
