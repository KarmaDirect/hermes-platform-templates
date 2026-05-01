---
name: briefing-quotidien
description: Résumé matinal envoyé sur Telegram ou email au patron — RDV du jour, urgences, KPI clés, en 6-8 lignes max.
version: 1.1.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [productivity, briefing, management, summary]
    category: productivity
    triggers: [cron, manual]
---

# Briefing Quotidien

## When to Use

Quand le patron veut un résumé ultra-court de sa journée à venir : RDV, chantiers, factures à relancer, météo, rappels perso. Idéal en cron tous les matins à 7h, ou à la demande via `/run briefing-quotidien`.

## Quick Reference

**Input attendu (JSON)** :
```json
{
  "date": "YYYY-MM-DD",
  "rdv_du_jour": [{"heure": "9h", "client_name": "Dupont", "ville": "La Rochelle", "notes": "devis terrasse"}],
  "chantiers_actifs": [{"nom": "Maison Mercier", "statut": "en cours", "ville": "Châtelaillon", "eta_livraison": "10/05"}],
  "factures_a_relancer": [{"client_name": "Garage Cantin", "amount_eur": 2450, "days_overdue": 18}],
  "meteo": "Pluie 8mm prévus matin",
  "rappels_perso": [{"texte": "Anniv client Mercier"}]
}
```

**Output** : un seul bloc texte Markdown, 6-8 lignes max.

## Procedure

1. Lis l'input JSON.
2. Pour chaque section non vide, génère 1 ligne staccato (pas de phrase complète).
3. Préfixe chaque ligne d'un emoji de section : 📅 RDV, 🚧 chantiers, 💰 factures, 🌧️ météo, 📌 rappels.
4. Si une section est vide ou null, **supprime la ligne entière** (pas de "rien à signaler").
5. Si tout est vide : `📭 Aucune urgence aujourd'hui. Bonne journée.`
6. Météo : ne mentionne que si pluie >5mm OU froid <5°C. Sinon, omettre.

## Style

- Sec, télégraphique. "9h: Dupont, devis terrasse, La Rochelle" pas "Vous avez RDV à 9h chez M. Dupont…"
- Pas de bonjour, pas de salutations.
- Montants arrondis à l'euro (`1 250 €` pas `1 247,50 €`).
- Heures format `9h`, `14h30`. Pas `09:00`.

## Exemple

**Input** :
```json
{"date": "2026-05-04", "rdv_du_jour": [{"heure": "9h", "client_name": "Dupont", "ville": "La Rochelle", "notes": "devis terrasse"}], "factures_a_relancer": [{"client_name": "Marie", "amount_eur": 850, "days_overdue": 12}], "meteo": "Pluie 8mm matin"}
```

**Output** :
```
☀️ Briefing du 04/05

📅 9h : Dupont (La Rochelle) — devis terrasse
💰 1 relance : Marie 850 € (12j retard)
🌧️ Pluie 8mm matin — prévoir bâche
```

## Pitfalls

- **Ne JAMAIS inventer** un RDV, un client, un montant qui n'est pas dans l'input.
- Si la météo est ensoleillée et clémente, **omet la ligne** (n'écris pas "🌧️ Beau temps").
- Pas d'emoji parasite — uniquement les 5 emojis de section.
- Pas de wrapper JSON ni de bloc code dans la sortie : juste le texte Markdown direct.

## Verification

Sortie correcte si :
- 6-8 lignes max (header inclus)
- 1 emoji unique par ligne
- Aucune phrase complète style « Vous avez… »
- Aucune section vide ne génère une ligne
