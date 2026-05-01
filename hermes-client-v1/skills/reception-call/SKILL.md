---
name: reception-call
description: Standard téléphonique IA — qualifie un transcript d'appel (ElevenLabs ou autre source voix), extrait l'intention, l'urgence, et formule une réponse à dire à l'appelant.
version: 1.1.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [communication, voice, elevenlabs, qualification, intent-extraction]
    category: communication
    triggers: [webhook]
---

# Reception Call

## When to Use

Reçoit un transcript d'appel téléphonique (typiquement transcrit par **ElevenLabs Conversational AI**). Qualifie l'appel, extrait l'intention, détecte l'urgence, et formule une réponse synthétique. **Voix-agnostique** : n'importe quel orchestrateur voix peut déclencher ce skill via webhook.

## Quick Reference

**Input** (JSON) :
```json
{
  "caller_phone": "+33612345678",
  "caller_name": "Marc Dupont (si connu, sinon null)",
  "transcript": "transcript brut de l'appel",
  "source": "elevenlabs-conversational",
  "call_id": "id côté orchestrateur voix"
}
```

**Output** (JSON STRICT) :
```json
{
  "qualified": true|false,
  "intent": "devis|rdv|sav|info|urgence|spam|autre",
  "urgency": "high|medium|low",
  "appointment_request": {
    "requested": true|false,
    "preferred_date": "YYYY-MM-DD|null",
    "preferred_time": "HH:MM|null",
    "topic": "string|null"
  },
  "next_action": "appointment|callback|transfer|voicemail|spam_ignore",
  "summary": "Phrase courte (max 200 char)",
  "reply_to_caller": "Ce que l'agent voix dit avant de raccrocher (max 2 phrases)"
}
```

## Procedure

1. Lis le transcript en entier.
2. Détermine `qualified` : `true` si demande utile (devis, RDV, SAV, info pertinente, urgence), `false` pour démarchage / faux numéro / appel mute.
3. Choisis `intent` parmi `devis | rdv | sav | info | urgence | spam | autre`.
4. Évalue `urgency` :
   - `high` : urgence terrain réelle (fuite, panne hiver, sinistre) OU client important demandant rappel sous 1h
   - `medium` : devis sous 48h, RDV cette semaine
   - `low` : info, démarche pas pressée
5. Si l'appelant demande **explicitement** un RDV → `appointment_request.requested = true`. Pas d'inférence.
6. Choisis `next_action` :
   - `appointment` : qualifié + RDV souhaité → équipe humaine cale les détails
   - `callback` : qualifié sans RDV mais suivi nécessaire
   - `transfer` : urgence terrain → notifier patron immédiatement
   - `voicemail` : pas urgent, message au patron
   - `spam_ignore` : poubelle
7. Compose `summary` : ≤200 chars, pour le patron.
8. Compose `reply_to_caller` : 2 phrases max, ton chaleureux pro, confirme ce qui a été compris + précise la suite. **Jamais de promesse de prix précis.**

## Spécialisation par vertical

**BTP** : extraire type prestation (pose/rénovation/dépannage), surface si mentionnée, ville/CP, délai. Mots-clés `urgency: high` → fuite, panne chauffage, disjoncté, sinistré, infiltration active.

**Restauration** : date/créneau, nb couverts (adultes/enfants), allergies/régimes mot-à-mot, occasion. Annulation = `intent: rdv` + mention dans summary.

**Generic** : applique les règles ci-dessus, reste neutre.

## Pitfalls

- **JSON strict** uniquement. Pas de Markdown, pas de commentaire avant/après le JSON.
- **Ne jamais inventer** un nom, un numéro, une date qui n'est pas dans le transcript.
- **Ne jamais promettre un prix** dans `reply_to_caller`. Toujours « Notre équipe vous rappelle pour le détail ».
- Transcript trop court ou inintelligible → `qualified: false, intent: "autre", urgency: "low", next_action: "voicemail"`.

## Verification

- Output est un JSON valide (parser sans erreur).
- `qualified` est cohérent avec `intent` (si `intent: spam`, alors `qualified: false`).
- `reply_to_caller` est en français, ≤2 phrases.
- `summary` ≤200 chars.
