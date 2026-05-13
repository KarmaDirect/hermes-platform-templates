---
name: reporting-ceo-webstate
description: Briefing quotidien pour le dirigeant à partir des data Webstate (CA mois, devis à relancer, RDV jour, planning équipe, impayés, leads chauds, alertes trésorerie). Envoyé Telegram chaque matin 8h. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, reporting, ceo, briefing]
    category: reporting
    triggers: [cron, channel-message]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Reporting CEO Webstate

## When to Use

Cron quotidien 8h heure tenant. Envoie un récap structuré au patron. Aussi
disponible à la demande via chat : "résume ma journée", "où on en est",
"brief du matin".

## Quick Reference

**Output** (Telegram message HTML) :
```
🌅 Brief du {date} pour {org_name}

📊 PIPELINE
• CA mois : 12 450 € (+18% vs mois -1)
• Marge moyenne chantier : 32%
• Devis à relancer J+3 : 3 (vue Webstate auto)
• Devis non signés > 7j : 2 → relances en cours

📅 AGENDA AUJOURD'HUI
• 09:00 — Visite chantier rue Pasteur (Marc Dupont)
• 14:30 — RDV signature contrat Mme Bernard
• 16:00 — Réunion équipe

👥 ÉQUIPE
• Lucas absent (congé)
• Adrien sur chantier #234
• Toi : 2 RDV bloqués + 1 free entre 11h-12h

⚠️ ALERTES
• 1 facture impayée > 30j (Mme Lambert, 1850 €)
• Stock vis 8mm sous seuil (12 unités vs 50 min)
• Pluie prévue demain → SMS clients chantier #234 ? [bouton]

🔥 LEADS CHAUDS
• Jean Dubois (formulaire web hier soir, score 85/100)
• ...
```

**Input** (rare, optionnel) :
```json
{
  "scope": "today|week|month",
  "deliver": "telegram|email|both"
}
```

## Workflow

1. **Skip check** si `WEBSTATE_REFRESH_TOKEN` absent.

2. **Queries parallèles via crm-webstate** :
   - CA mois : SUM(invoices.total_amount) WHERE status='paid' AND issued_at>=startOfMonth()
   - Marge moyenne : SELECT marge_chantier (vue précalculée Webstate)
   - Devis à relancer : COUNT(quotes) WHERE status='sent' AND created_at < now()-3d
   - RDV jour : appointments du jour avec contact + location
   - Équipe : organization_members + employee_absences du jour
   - Impayés > 30j : invoices WHERE status IN ('sent','overdue') AND due_date < now()-30d
   - Stock alertes : stock_items WHERE qty < min_qty
   - Leads chauds : contacts WHERE category='lead' AND created_at < now()-24h, scoring via skill `btp-lead-scorer` si actif
   - Météo : Open-Meteo pour les chantiers du lendemain

3. **Compose message** : Markdown structuré, sections épurées avec emojis.
   Limite : 3 lignes par section, lien vers détail dashboard si plus.

4. **Envoi** :
   - Telegram via `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` du patron
   - Email fallback via `crm-webstate.send_email` si Telegram indispo (chat_id=0)

5. **Boutons interactifs** (Telegram) :
   - "📞 Rappeler {lead chaud}" → trigger skill `secretaire-webstate.callback`
   - "💬 Envoyer SMS pluie aux clients chantier #234" → action SMS bulk via `send-sms` Edge Fn Webstate
   - "📊 Voir détail dashboard" → lien webstate.fr/dashboard

## Pitfalls

- **Pas spammer** : 1 brief/jour MAX. Si lancé manuellement à 14h, le brief 8h est skip.
- **Marge confidentielle** : si org.settings.show_margin_to_team=false, ne pas inclure dans brief autre que owner.
- **Cron timezone** : utiliser org.timezone (Europe/Paris par défaut), pas UTC. 8h Paris = 7h UTC en hiver, 6h UTC été.

## Toggle ON/OFF

Désactivé par défaut. Activer = ajouter `reporting-ceo-webstate` à
`enabled_skills` + push `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` du patron
via Push credential modal admin.

## Handoff

- `crm-webstate` : pour toutes les queries
- `briefing-quotidien` (skill natif générique) : ce skill l'override
  quand le tenant est lié à Webstate (pas de doublon)
