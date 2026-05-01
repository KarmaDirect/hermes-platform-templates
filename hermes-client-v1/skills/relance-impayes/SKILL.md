---
name: relance-impayes
description: Génère email + SMS de relance pour une facture impayée, ton adapté au niveau de retard (J+7 / J+15 / J+30).
version: 1.1.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [business, finance, recouvrement, email, sms, hitl-on-l3]
    category: business
    triggers: [cron, webhook, manual]
---

# Relance Impayés

## When to Use

Quand une facture est en retard de paiement et qu'il faut générer un message de relance pré-rédigé. **Le LLM rédige, pas le patron** — donc le ton doit être impeccable. Niveau 3 (J+30) déclenche escalation HITL : le patron valide avant envoi.

## Quick Reference

**Input** (JSON) :
```json
{
  "level": 1|2|3,
  "invoice": {
    "invoice_number": "F-2026-0042",
    "client_name": "Garage Cantin",
    "client_email": "contact@example.fr",
    "client_phone": "+33545678901",
    "amount_eur": 2450,
    "issued_at": "2026-04-08",
    "due_date": "2026-04-15",
    "days_overdue": 18,
    "payment_link": "https://pay.example/inv/abc"
  },
  "company_name": "Bastide BTP",
  "owner_name": "Jean Bastide",
  "reply_email": "compta@bastide-btp.fr"
}
```

**Output** (JSON STRICT) :
```json
{
  "subject": "Sujet email court (max 80 char)",
  "email_html": "Corps HTML inline-style",
  "sms_text": "Texte SMS ≤160 char, sans emoji",
  "recommended_channel": "email|sms|email+sms|escalation"
}
```

## Niveaux de relance

### Niveau 1 — J+7 à J+14 : courtois rappel amical
- Sujet : `"Petit rappel — facture {{invoice_number}}"`
- Hypothèse implicite : oubli de bonne foi.
- Pas d'accusation, pas de menace.
- Mention claire montant + date d'échéance + lien de paiement.
- `recommended_channel: email`

### Niveau 2 — J+15 à J+29 : ferme mais respectueux
- Sujet : `"Relance facture {{invoice_number}} — {{amount_eur}} €"`
- Plus direct, sans agressivité.
- Rappel intérêts de retard légaux 10.05% (taux légal France 2026).
- Demande retour rapide (réponse sous 48h).
- `recommended_channel: email+sms`

### Niveau 3 — J+30+ : mise en demeure pré-contentieuse
- Sujet : `"MISE EN DEMEURE — facture {{invoice_number}}"`
- Formel, structuré, daté.
- Mentionne intérêts de retard + indemnité forfaitaire 40€ (B2B, loi du 22 mars 2012) + recouvrement contentieux.
- Phrase clé : « À défaut de règlement sous 8 jours, nous nous réservons le droit d'engager toute procédure utile. »
- `recommended_channel: escalation` (le patron valide avant envoi).

## Procedure

1. Lis `level` et choisis le ton + sujet correspondants.
2. Compose le corps email HTML (inline-style, pas de framework). Structure : salutation → contexte facture → demande de règlement → lien paiement (bouton stylé) → mention conséquences (niveau 2+) → signature.
3. Compose le SMS : ≤160 caractères, factuel, avec lien paiement raccourci. **Sans emoji** (B2B).
4. Détermine `recommended_channel` selon le niveau.
5. Output JSON strict.

## Pitfalls

- **Toujours en français professionnel**, vouvoiement.
- **Toujours mentionner** : numéro facture, montant TTC en €, date d'échéance, jours de retard.
- **Pas d'emoji** dans email ni SMS (B2B sérieux).
- **Niveau 3** : `recommended_channel` doit être `escalation` SYSTÉMATIQUEMENT (HITL).
- HTML email : inline-style uniquement (`<div style="…">`). Pas de `<style>` block, pas de classes.
- Lien de paiement en bouton CSS inline (`background:#111;color:#fff;padding:10px 18px;border-radius:6px;text-decoration:none`).

## Signature

Format : `Cordialement, {{owner_name}} \n {{company_name}} \n {{reply_email}}`. Si `owner_name` manque, fallback : `L'équipe {{company_name}}`.

## Verification

- JSON strict (parser sans erreur).
- `subject` ≤80 chars.
- `sms_text` ≤160 chars.
- Si `level=3`, `recommended_channel === "escalation"`.
- Mention montant et numéro facture présente dans email ET sms.
