---
name: devis-conversationnel-webstate
description: Génère un devis Webstate à partir d'une conversation naturelle (chat/voix). Lit l'historique du client (devis précédents, factures, prix négociés), propose des lignes pertinentes, applique un template, crée le devis via crm-webstate, l'envoie via Edge Fn generate-and-send-quote. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, devis, sales, conversational]
    category: commercial
    triggers: [channel-message]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Devis Conversationnel Webstate

## When to Use

Le client demande "fais un devis pour Marc Dupont, rénovation salle de bain
6m², carrelage + peinture". Le skill :

1. Match contact "Marc Dupont" (ou crée).
2. Charge l'historique : derniers devis du contact (`crm-webstate.list_quotes?contact_id=...`)
   pour récupérer les prix négociés, le ton.
3. Charge les `quote_templates` de l'org pour le scope. Si vide, continue sans template.
4. Charge les `products` du catalogue org pour les prix unitaires.
5. Propose des lignes structurées via LLM avec context :
   - Conversation client + ton org + historique devis + prix marché BTP 2026
6. Crée le devis via RPC Webstate `POST /rest/v1/rpc/create_quote` (pas un insert direct). Si `p_template_id` n'existe pas, passer `null` dans ce tenant.
7. Vérifie le devis créé avec `rpc/get_public_quote` avant de demander une validation d'envoi.
8. Confirme au client : "Devis #2026-024 prêt. Veux-tu que je l'envoie par

   email à Marc maintenant ?"
9. Si oui → `generate-and-send-quote` Edge Fn Webstate (PDF + email + SMS).

## Quick Reference

**Input** :
```json
{
  "contact_query": "Marc Dupont",
  "scope": "rénovation salle de bain 6m² + carrelage + peinture",
  "vertical": "btp",
  "vat_mode": "10%",
  "send_now": false
}
```

**Output** (JSON strict) :
```json
{
  "quote_id": "uuid",
  "quote_number": "DEV-2026-024",
  "contact_id": "uuid",
  "contact_action": "matched|created",
  "items_count": 8,
  "total_ttc": 4250.50,
  "items_summary": [
    {"label": "Dépose ancien carrelage", "qty": 6, "total": 90},
    ...
  ],
  "ready_to_send": false,
  "next_action": "review_or_send"
}
```

## Workflow détaillé — STRICT HITL (Human In The Loop)

**JAMAIS de quote envoyée sans validation explicite du patron via chat.**

### Phase 1 — Compréhension (silencieux)
1. Skip check `WEBSTATE_REFRESH_TOKEN`.
2. **Match/create contact** : recherche dans contacts via crm-webstate. Si
   plusieurs candidats correspondent au prénom/nom, lister au patron pour
   choix. Si aucun match : proposer création AVEC les infos qu'on a.
3. **Charger context** :
   - Derniers 5 devis du contact (prix négociés, ton, type de chantier).
   - `quote_templates` org (templates métier).
   - `products` catalogue (prix unitaires de référence).
4. **LLM compose un brouillon** mental — pas encore d'INSERT DB.

### Phase 2 — Récap + checklist HITL (CRITIQUE)

Avant TOUT INSERT en DB, le skill DOIT poster un récap structuré au patron
dans le chat avec une checklist explicite :

```
📋 RÉCAP AVANT ENVOI

👤 CLIENT
   Marc Dupont — marc@bouygues.fr — 06 12 34 56 78
   Adresse : 12 rue de la Paix, 75001 Paris
   ⚠️  Contact créé maintenant (pas dans le CRM avant)
   [ confirme ] [ changer client ]

🔧 LIGNES (3)
   1. Visite technique chantier         1 forfait    80,00 €
   2. Fourniture matériaux              1 lot       350,00 €
   3. Pose carrelage                    6 m²    270,00 €  (45€/m²)
   
💰 TOTAUX
   Sous-total HT : 700,00 €
   TVA 10%       : 70,00 €  ← rénovation logement (>2 ans)
   TOTAL TTC     : 770,00 €
   
❓ CHECKLIST PATRON
   ✓ Le client est correct ?
   ✓ Toutes les lignes sont là (pas oublié déplacement, évacuation gravats) ?
   ✓ TVA 10% OK ? (sinon : 20% neuf, 5,5% éco-rénovation)
   ✓ Pas de remise à appliquer ?
   ✓ Délai validité 30 jours OK ?
   ✓ Conditions paiement standard ?
   
👉 Pour valider et envoyer : "OK envoie" / "Oui valide"
👉 Pour ajuster : dis-moi quoi changer (ligne, prix, TVA, remise, conditions)
👉 Pour annuler : "Non" / "Annule"
```

### Phase 3 — Réponse patron (attendre)

Le skill **ne fait RIEN tant que le patron n'a pas répondu explicitement**.
Si la réponse est :
- **OK / Oui / Valide / Envoie** → passe Phase 4
- **Modification** (ex : "TVA 20%", "ajoute déplacement 50€", "remise 10%") :
  applique la modification, réémet le récap complet (Phase 2), redemande
  validation
- **Non / Annule** : abandonne, pas d'INSERT, pas de devis créé

### Phase 4 — Création + envoi

1. Crée le devis via RPC Webstate : `POST /rest/v1/rpc/create_quote`.
   ```json
   {
     "p_org_id": ORG,
     "p_contact_id": ...,
     "p_template_id": null,
     "p_quote_data": {
       "items": [{"description": "...", "quantity": 1, "unit_price": 100, "tax_rate": 10}],
       "totals": {"subtotal": 100, "tax": 10, "total": 110},
       "client": {"name": "...", "email": "...", "phone": "...", "address": "..."},
       "conditions": {"validity_days": 30, "payment_terms": "30 jours"}
     },
     "p_status": "draft",
     "p_quote_date": today,
     "p_validity_date": today_plus_30
   }
   ```
2. Récupère `quote_id` / `quote_number`.
3. Vérifie immédiatement avec `POST /rest/v1/rpc/get_public_quote`.
4. Appelle Edge Fn Webstate : `POST /functions/v1/generate-and-send-quote` avec `{quote_id, send_email: true, send_sms: true}`.
5. Récupère `pdf_url` de la réponse.

### Phase 5 — Confirmation finale + PDF dans chat

Le skill doit afficher au patron une réponse finale **avec lien PDF**
formaté pour que le frontend détecte et affiche l'aperçu :

```
✅ Devis envoyé à Marc Dupont

DEV-2026-024 · 770€ TTC
• Email envoyé à marc@bouygues.fr
• SMS envoyé au 06 12 34 56 78

[📄 Aperçu PDF du devis](https://api.webstate.fr/storage/v1/object/public/quotes/.../xxx.pdf)

Webstate va automatiquement relancer Marc J+3 et J+7 si pas signé. Tu veux
que je note un rappel particulier ?
```

Le frontend chat détecte le pattern `[📄 ...](url.pdf)` et affiche un
aperçu cliquable inline + bouton "Télécharger".

## Pitfalls

- **Création devis** : dans ce tenant, privilégier `rpc/create_quote` puis `rpc/get_public_quote` pour vérifier. Éviter d'enseigner un insert direct `POST /rest/v1/quotes` comme chemin principal.
- **Référence API** : voir `references/quote-rpc.md` pour le payload minimal et la vérification.
- **Hallucination prix** : ne PAS inventer des prix. Si pas de match dans
  catalogue ou historique, marquer `confidence_global=0.5` et `hypotheses`
  explicit "Prix à confirmer marché Lyon BTP 2026".
- **TVA** : 10% rénovation logement habité (>2 ans), 20% neuf, 5.5% économie
  d'énergie. Demander confirmation client si ambigu.
- **Numérotation** : utiliser RPC `generate_quote_number(p_org_id)` côté Webstate
  ou laisser PostgREST auto-incrémenter.
- **Pas de vrai client** : si `contact_query` ne match pas et que le client
  ne fournit ni email ni téléphone, NE PAS créer de contact fantôme. Demander
  info ou marquer le devis avec contact_id=null + metadata.lead_only=true.

## Toggle

Désactivé par défaut. Activer dans CSV.

## Handoff

- `devis-photo` (skill natif) : si photo fournie en début de conversation, délègue à devis-photo qui revient avec items pré-remplis
- `crm-webstate` : pour CRUD contact + quote
- `secretaire-webstate` : peut chaîner depuis "qualification appel = devis"
- `confirmation-hub` : HITL avant envoi si total > seuil org
