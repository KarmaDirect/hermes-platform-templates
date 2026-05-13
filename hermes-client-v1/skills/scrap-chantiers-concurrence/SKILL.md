---
name: scrap-chantiers-concurrence
description: Surveille les appels d'offres publics (BOAMP, marchés-publics.gouv.fr, BatiActu) pour le métier et la zone du tenant BTP, et propose ceux qui matchent la capacité du tenant. Cron 2×/semaine.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - browser-use-runner
metadata:
  hermes:
    tags: [commercial, btp, prospection, cron, hitl]
    category: commercial
    triggers: [cron, manual]
---

# scrap-chantiers-concurrence

## When to Use

Quand l'artisan BTP (plombier, électricien, maçon, peintre, menuisier) veut **gagner des marchés publics ou semi-publics** (collectivités, syndics, bailleurs sociaux) sans passer des heures à chercher.

**Cas d'usage** :
- "Hermès, regarde si y'a des chantiers de plomberie dans le 17 cette semaine"
- "Préviens-moi si une mairie de Charente-Maritime publie un AO chauffage"

**À NE PAS utiliser** :
- Pour des marchés > 90k€ HT (procédure formalisée — l'artisan PME n'a pas la structure)
- Sans certification RGE / Qualibat si le marché l'exige (filtrer en amont)

## Input

### Mode cron auto

Lit le tenant : `organizations.vertical='btp'`, `organizations.metier`, `organizations.address` (extrait département), `organizations.rge_certified`.

### Mode manuel

```json
{
  "metier": "plomberie chauffage",
  "departements": [17, 16],
  "budget_max_eur": 90000,
  "rge_required": false
}
```

## Output (JSON STRICT)

```json
{
  "ok": true,
  "scanned_sources": ["BOAMP", "marches-publics.gouv.fr", "BatiActu"],
  "matches": [
    {
      "title": "Rénovation chauffage gymnase municipal",
      "donneur_ordre": "Mairie de Châtelaillon-Plage",
      "departement": 17,
      "budget_eur_estime": 45000,
      "date_limite_dépôt": "2026-06-15",
      "source_url": "https://www.boamp.fr/avis/...",
      "match_score": 0.85,
      "rge_required": true,
      "alerts": ["RGE Qualibat 4111 demandé", "Délai 15 jours seulement"]
    }
  ],
  "total_matches": 3,
  "telegram_sent": true
}
```

## Procédure

1. Lire les dernières exec dans `tenant_tasks` pour récupérer `last_seen_at`.
2. **BOAMP** (officiel France) : `browser-use-runner` sur `https://www.boamp.fr/pages/recherche/` avec filtres métier + département.
3. **marchés-publics.gouv.fr** : idem.
4. **BatiActu marchés** (libre) : `https://www.batiactu.com/` section appels d'offres.
5. Pour chaque résultat :
   - Extraire titre, donneur d'ordre, budget estimé, date limite, URL source
   - **Match score** calculé sur : matching mots-clés métier (0.4) + département dans liste tenant (0.3) + budget < `budget_max_eur` (0.2) + délai ≥ 7 jours (0.1)
   - Filter `match_score >= 0.6` (sinon noise)
6. **Telegram alert** si ≥ 1 match :
   - Titre + budget estimé + délai
   - Lien direct vers AO
   - Bouton "Préparer dossier candidature" (déclenche skill `prepare-ao-dossier`, MVP-2)
7. UPDATE `tenant_tasks` avec `last_seen_at`.

## Pitfalls

- BOAMP a un **anti-bot léger** (rate limit 30 req/h) — le rate limit 3s du runner suffit pour < 30 AO scannés.
- Beaucoup d'AO ont des **délais courts < 10 jours** — alerter immédiatement, pas le lendemain.
- **RGE Qualibat / Qualifelec** : si le tenant n'est pas certifié, filtrer ces AO en amont (perte de temps sinon).
- Marchés < 25k€ HT = **procédure adaptée** (gré-à-gré possible) — le tenant peut tenter même sans dossier formel.
- Marchés 25-90k€ = **MAPA** procédure adaptée structurée — dossier candidature simple (DC1+DC2).
- Marchés > 90k€ = procédure formalisée — typiquement hors capacité PME 1-5 salariés.

## RGPD

- ✅ Données 100% publiques (publication légale des AO)
- ✅ Donneur d'ordre = personne morale (mairies, syndics) — pas de RGPD
- ⚠️ Si scraping contact (acheteur public) → utiliser uniquement pour répondre à l'AO, pas pour mass-mailer

## Verification

- `total_matches ≥ 0` (peut être 0 = normal)
- Chaque `date_limite_dépôt` est dans le futur
- Chaque `source_url` est sur un domaine officiel (whitelist : boamp.fr, marches-publics.gouv.fr, batiactu.com)
- Audit `activity_log` entry

## Exemple usage

Cron mardi + vendredi 9h. Patron reçoit Telegram :
> 🏗️ **3 nouveaux chantiers matchent ton profil**
>
> 1. **Rénovation chauffage gymnase Châtelaillon** — Mairie · 45k€ · jusqu'au 15/06
>    ⚠️ RGE Qualibat 4111 demandé · Délai 15j
>    [Préparer dossier 📋] [Ignorer ✗]
>
> 2. **Plomberie école primaire La Rochelle** — Mairie · 18k€ · jusqu'au 28/05
>    Procédure adaptée < 25k€, dossier simple
>    [Préparer 📋] [Ignorer ✗]
>
> 3. [...]
