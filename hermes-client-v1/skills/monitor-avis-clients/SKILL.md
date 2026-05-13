---
name: monitor-avis-clients
description: Surveille les nouveaux avis Google Maps et TripAdvisor pour un établissement (BTP ou Restau) et alerte le patron par Telegram + brouillon de réponse pour chaque avis < 4 étoiles. Cron quotidien.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - browser-use-runner
metadata:
  hermes:
    tags: [marketing, reputation, restauration, btp, services, cron, hitl]
    category: marketing
    triggers: [cron, manual]
---

# monitor-avis-clients

## When to Use

Quand le tenant veut **savoir tout de suite** quand un client poste un avis Google/TripAdvisor — surtout s'il est < 4 étoiles — pour répondre dans la journée (la rapidité de réponse impacte le score moyen).

**Cas d'usage typique** :
- Restaurant qui reçoit ~5 avis/semaine, dont 1 négatif/mois
- Plombier/artisan BTP avec fiche Google My Business
- Coiffeur avec fiche Google + TripAdvisor

**Auto-cron** : configuré 1×/jour à 8h locale (briefing matin) — pas plus fréquent (anti-bot).

## Input

### Mode cron auto

Aucun input — lit `organizations.google_place_id` + `organizations.tripadvisor_url` du tenant.

### Mode manuel

```json
{
  "google_place_id": "ChIJ...",
  "tripadvisor_url": "https://www.tripadvisor.fr/Restaurant_Review-g..."
}
```

## Output (JSON STRICT)

```json
{
  "ok": true,
  "scanned_at": "2026-05-13T08:00:00Z",
  "google": {
    "current_rating": 4.6,
    "current_review_count": 142,
    "new_reviews": [
      {
        "author": "Marc D.",
        "rating": 2,
        "text": "Service trop lent, plat froid",
        "posted_at": "2026-05-12T20:15:00Z",
        "needs_reply": true,
        "draft_reply": "Bonjour Marc, je suis désolé que votre expérience n'ait pas été à la hauteur. Pouvez-vous m'écrire en privé sur ... pour que je comprenne ce qui s'est passé ? Je tiens à m'excuser."
      }
    ]
  },
  "tripadvisor": {
    "current_rating": 4.3,
    "new_reviews": []
  },
  "telegram_alert_sent": true,
  "next_steps": [
    "Valider/éditer le brouillon de réponse depuis le dashboard /inbox",
    "Cliquer 'Publier' déclenche un skill `post-review-reply`"
  ]
}
```

## Procédure

1. **Lire la dernière exec** dans `tenant_tasks` (`task_type='monitor-avis-clients'`) pour récupérer le timestamp du dernier avis vu.
2. **Google Maps** : appeler `browser-use-runner` avec :
   - `url` = `https://www.google.com/maps/place/?q=place_id:{place_id}` + onglet Avis
   - `task` = "Lister tous les avis postés après {last_seen_at}. Extraire auteur, rating, texte, date."
   - `extract_schema` = liste new_reviews
3. **TripAdvisor** (si configuré) : idem, URL TripAdvisor + scrap avis récents.
4. **Filter** : retenir uniquement les avis postés après `last_seen_at`.
5. Pour chaque avis < 4 étoiles : **générer un brouillon de réponse** avec un mini-prompt LLM :
   - Ton : empathique, propose canal privé (DM/email), n'argumente pas en public.
   - Long max 280 chars (twitter-like, lisible mobile).
6. **Telegram alert** via skill `telegram-send-rich` si ≥ 1 avis nouveau.
7. UPDATE `tenant_tasks` avec `last_seen_at = now()`.
8. INSERT dans `activity_log` (`source='monitor-avis-clients'`).

## RGPD

- ✅ Avis publics → données publiées, OK à scraper et conserver
- ⚠️ Ne **jamais** conserver l'identité réelle de l'auteur (Marc D. = OK, Marc Dupont email = NON)
- ⚠️ Réponse publique : ton respectueux, jamais accusatoire (risque diffamation)

## Pitfalls

- Google détecte le scraping → headless Chromium peut être bloqué après 5-10 req/h. Limiter cron à **1×/jour** par tenant strict.
- TripAdvisor a un anti-bot **agressif** — peut nécessiter de basculer vers Apify (~5€/mois pour 1000 restos) si échec répété.
- Le brouillon de réponse **doit être validé humainement** avant publication (HITL absolument requis — un faux pas = procès).
- Avis fake / extorsion : si un avis 1-étoile apparaît avec un texte du type "Payez-moi sinon je laisse mauvais avis", alerte SPÉCIFIQUE Telegram + tag `extortion_suspected` pour signalement Google.

## Verification

- Premier avis ≥ `last_seen_at` (pas de doublon)
- `current_rating ∈ [0, 5]`
- Si Telegram alert : message envoyé OK (status 200)
- Audit `activity_log` entrée avec nb avis trouvés

## Exemple usage

Cron 8h auto. Patron reçoit Telegram :
> 🍽️ **Nouvel avis Google — 2/5** par Marc D. (hier 20h15)
> *"Service trop lent, plat froid"*
>
> Brouillon de réponse prêt :
> "Bonjour Marc, désolé pour cette expérience. Pouvez-vous m'écrire en privé pour comprendre ce qui s'est passé ?"
>
> [Valider ✓] [Éditer 📝] [Ignorer ✗]
