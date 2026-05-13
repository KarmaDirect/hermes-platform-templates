---
name: secretaire-elevenlabs-webstate
description: Gère les appels entrants ElevenLabs, qualifie la demande, crée ou retrouve le contact dans Webstate, log l’échange, confirme au client par SMS et escalade au patron si urgence. SKIP automatique si le tenant n’est pas lié à Webstate.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
  - confirmation-hub
metadata:
  hermes:
    tags: [webstate, secretariat, voice, elevenlabs, hitl]
    category: secretariat
    triggers: [webhook]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID, ELEVENLABS_API_KEY]
---

# Secrétariat ElevenLabs Webstate

## Quand l’utiliser

Utilise ce skill quand ElevenLabs t’envoie un appel entrant, une transcription, ou un événement de conversation vocale à traiter pour un tenant Webstate.

Cas typiques :
- prise d’appel entrant
- message vocal laissé par un client
- qualification d’une demande de devis ou de rendez-vous
- urgence à faire remonter au patron
- rappel client après appel manqué

## Avant de brancher quoi que ce soit

Ne pars pas directement sur les clés API. Commence par cadrer le métier du secrétariat :
- activité du client
- type de secrétaire attendu
- motifs d’appel à gérer
- urgences à reconnaître
- ce qu’il faut faire selon le motif
- qui alerter et quand
- ton de réponse
- horaires de traitement
- canaux de sortie

Si l’utilisateur n’a pas encore donné ces éléments, pose-les d’abord de façon courte et concrète. Ne propose pas une intégration générique tant que le flux métier n’est pas clair.

Voir aussi `references/intake-scope.md` pour le questionnaire de cadrage.

## Prérequis

- `ELEVENLABS_API_KEY` configurée
- tenant déjà lié à Webstate
- accès CRM via `crm-webstate`
- canal d’escalade via `confirmation-hub` si urgence

## Entrée attendue

Payload JSON minimal :
```json
{
  "channel": "elevenlabs",
  "event_type": "call.started|call.ended|transcript|voicemail",
  "from_number": "+33612345678",
  "from_name": "Marc Dupont",
  "from_email": "client@exemple.fr",
  "transcript": "Bonjour, j’ai besoin d’un devis pour…",
  "duration_sec": 52,
  "recording_url": "https://...",
  "received_at": "2026-05-07T13:00:00Z"
}
```

## Sortie attendue

```json
{
  "skipped": false,
  "contact_action": "matched|created",
  "contact_id": "uuid",
  "intent": "rdv|devis|urgence|support|info|autre",
  "activity_id": "uuid",
  "next_action": "sms_sent|task_created|escalated_owner|handoff_to_rdv|handoff_to_devis"
}
```

## Workflow

1. **Skip check**
   - si le tenant n’est pas lié à Webstate, retourne `{ "skipped": true }`
   - si le payload est vide ou invalide, retourne une erreur claire

2. **Normalisation**
   - normalise le numéro en format E.164
   - nettoie le nom du contact
   - garde la transcription brute pour audit, mais crée un résumé court pour l’activité

3. **Recherche contact**
   - cherche d’abord par téléphone normalisé
   - puis par email si fourni
   - si plusieurs candidats existent, garde le meilleur match et marque un flag de doute dans les notes

4. **Création contact si inconnu**
   - crée un contact Webstate avec :
     - prénom/nom si disponibles
     - téléphone
     - email si disponible
     - source = `hermes_elevenlabs`
     - statut = `new`

5. **Qualification**
   - classe l’intention en : `rdv`, `devis`, `urgence`, `support`, `info`, `autre`
   - règles simples :
     - urgence = fuite, panne, inondation, cassé, urgence, plus de chauffage
     - devis = prix, estimation, chiffrage, travaux, photo, intervention
     - rdv = rendez-vous, dispo, créneau, quand passer

6. **Log dans Webstate**
   - crée une activité de type appel ou message
   - inclut : durée, transcription, résumé, numéro source, canal ElevenLabs, horodatage

7. **Action métier**
   - `urgence` → escalade immédiate au patron via `confirmation-hub`
   - `rdv` → passe la main à `agenda-intelligent-webstate` si actif, sinon crée une tâche de rappel
   - `devis` → passe la main à `devis-conversationnel-webstate` si actif, sinon crée une tâche de qualification
   - `support|info|autre` → crée une tâche de suivi et envoie un SMS de confirmation

8. **Confirmation client**
   - envoie un SMS court :
     - accusé réception
     - prochaine action
     - délai de rappel si pertinent

## Règles de sécurité et qualité

- ne demande jamais deux fois les mêmes infos si le contact existe déjà
- n’envoie pas de SMS en double sur moins de 10 minutes pour le même numéro
- si la transcription est vide, log l’appel quand même avec un résumé minimal
- si l’appel a lieu hors horaires ouvrés, adapte le message de retour
- si le cas est ambigu, privilégie une tâche humaine plutôt qu’une automatisation risquée

## Intégrations associées

- `crm-webstate` : contacts, activités, tâches, RDV
- `confirmation-hub` : escalade au patron
- `agenda-intelligent-webstate` : prise de RDV si disponible
- `devis-conversationnel-webstate` : qualification devis si disponible

## Notes de déploiement

- skill désactivé par défaut
- à activer seulement sur les tenants qui ont branché ElevenLabs + Webstate
- ne stocke jamais les secrets dans le skill, seulement les noms de variables d’environnement
