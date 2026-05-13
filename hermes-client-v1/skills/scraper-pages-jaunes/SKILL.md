---
name: scraper-pages-jaunes
description: Cherche des prospects (entreprises, artisans, restaurants) sur Pages Jaunes par métier + code postal et renvoie une liste structurée (nom, téléphone, adresse, site web) pour alimenter le CRM du tenant.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - browser-use-runner
metadata:
  hermes:
    tags: [commercial, prospection, btp, restauration, web, hitl]
    category: commercial
    triggers: [manual, webhook]
---

# scraper-pages-jaunes

## When to Use

Quand le patron a besoin de **trouver de nouveaux prospects** dans une zone géographique sans payer un outil de prospection à 200€/mois.

**Cas d'usage** :
- "Trouve-moi 30 plombiers dans le 17000 que je peux contacter pour de la sous-traitance."
- "Liste les restaurants Italien du 13e arrondissement Paris."
- "Cherche les électriciens RGE en Charente-Maritime."

**À NE PAS utiliser** si :
- Le tenant a un compte Sellsy / Pipedrive / HubSpot avec API officielle — utiliser ces wrappers à la place.
- L'objectif est de **contacter à froid > 100 personnes en B2C** (RGPD : prospection sans consentement = risque CNIL).

## Règle RGPD (NON-NÉGOCIABLE)

- ✅ Pages Jaunes liste **des entreprises** (SIRET, raison sociale) — c'est de la **donnée business**, pas perso. OK pour scraper.
- ❌ Jamais d'enrichissement avec données perso (LinkedIn, mail nominatif gérant) sans opt-in.
- ✅ Maximum **3 contacts à froid par jour par tenant** vers la liste produite (pas de mass-mail). Ce skill n'envoie rien — il alimente seulement le CRM.

## Input

```json
{
  "metier": "plombier",
  "code_postal": "17000",
  "ville": "La Rochelle",
  "rayon_km": 20,
  "limit": 30
}
```

## Output (JSON STRICT)

```json
{
  "ok": true,
  "query": {"metier": "plombier", "code_postal": "17000"},
  "results_count": 28,
  "results": [
    {
      "nom_commercial": "Plomberie Dupont",
      "siret": null,
      "telephone": "05 46 XX XX XX",
      "adresse": "12 rue de la Paix, 17000 La Rochelle",
      "site_web": "https://plomberie-dupont.fr",
      "email": null,
      "rating_pages_jaunes": 4.5,
      "nb_avis": 47
    }
  ],
  "next_steps": [
    "Importer dans contacts (status='prospect_pages_jaunes', tag='À qualifier')",
    "Programmer 3 appels max par jour via skill `cold-call-coach`"
  ]
}
```

## Procédure

1. Construire la query URL Pages Jaunes : `https://www.pagesjaunes.fr/recherche/{ville}/{metier}` + filtre rayon.
2. Appeler `browser-use-runner` avec :
   - `task` = "Liste les N premiers résultats, extraire pour chaque : nom commercial, téléphone, adresse complète, site web, note moyenne et nb avis."
   - `extract_schema` = le schema results ci-dessus
   - `max_steps` = 12 (scroll + extract)
3. Dédupliquer par téléphone normalisé (E.164).
4. **Filtrer** les résultats sans téléphone (pas exploitables).
5. **Limiter** à `limit` (défaut 30).
6. INSERT dans `contacts` table tenant avec `status='prospect_pages_jaunes'`, `source='scraper-pages-jaunes'`, `imported_at=now()`.
7. Retourner le JSON résumé + `next_steps`.

## Pitfalls

- Pages Jaunes a un anti-bot souple mais présent : si scraping > 1×/heure même IP → captcha. Le rate limit du runner (3s) suffit pour < 30 résultats.
- Le téléphone est parfois rendu en image (anti-scrape) — `browser-use` agit comme un humain et clique "Afficher le numéro" puis lit le DOM rendu. Garde 1 fallback "afficher" dans le `task`.
- Pages Jaunes ne donne PAS le SIRET — l'enrichir post-scrape via API Sirene (gratuit, public, INSEE).

## Verification

- `results_count > 0` (sinon query trop restrictive)
- Chaque `telephone` matche regex E.164 ou format FR `0X XX XX XX XX`
- Si screenshot disponible, vérifier visuellement présence des cartes Pages Jaunes
- Audit log entry `skill:scraper-pages-jaunes` dans `activity_log` avec query + results_count

## Exemple usage chat

> **Patron** : Hermès, trouve-moi 20 plombiers à La Rochelle, je dois sous-traiter des chantiers cette semaine.
>
> **Hermès** : Lance le skill `scraper-pages-jaunes`(metier=plombier, code_postal=17000, limit=20). Résultat : 18 prospects qualifiés ajoutés à ton CRM. Je te propose les 3 à appeler en priorité (note Google ≥ 4 + site web) : Plomberie Dupont, Sanitech 17, Plomb-Express. Tu veux que je te prépare le script d'appel ?
