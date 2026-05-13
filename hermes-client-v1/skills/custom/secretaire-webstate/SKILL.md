---
name: secretaire-webstate
description: Réceptionne les appels/messages entrants (Vapi voix, WhatsApp, Telegram, web chat) et les pousse directement dans le CRM Webstate du client lié. Crée le contact si inconnu, log l'appel dans activities, propose un RDV agenda + SMS confirmation, escalade au patron via confirmation-hub si urgence détectée. SKIP automatique si tenant non lié à Webstate.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
  - confirmation-hub
metadata:
  hermes:
    tags: [webstate, secretariat, voice, chat, hitl]
    category: secretariat
    triggers: [channel-message, webhook]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Secrétaire Webstate

## When to Use

Appel entrant (Vapi, Twilio, mobile callback) ou message client (chat web,
WhatsApp, Telegram, email) qui n'est PAS déjà identifié comme un client en
cours. Le skill agit en standard pro :

1. **Identifie** : tente match contact existant (téléphone E.164 ou email).
2. **Crée** si inconnu : nouveau contact dans Webstate avec `source="hermes_call"`.
3. **Qualifie** : objet de l'appel (devis, RDV, urgence, info, support, autre).
4. **Log** : insert dans `activities` Webstate avec type='call' + transcription
   ou résumé du message + duration si voix.
5. **Action** :
   - Si demande de RDV → délègue à `agenda-intelligent-webstate` (si actif)
     ou crée appointment direct via `crm-webstate.create_appointment`.
   - Si urgence (mots-clés "urgence", "fuite", "panne", "cassé", "inondation")
     → escalade `confirmation-hub` patron Telegram.
   - Si demande devis → ping skill `devis-conversationnel-webstate` (si actif).
   - Sinon → message d'attente "votre message a été transmis, on vous rappelle
     dans 1h" + ajout à `contact_tasks` côté Webstate.
6. **Confirmation client** : SMS via `crm-webstate.send_sms` "Bonjour {nom},
   nous avons bien noté votre appel concernant {objet}. {action}".

## Quick Reference

**Input** (depuis trigger channel-message ou webhook) :
```json
{
  "channel": "voice|whatsapp|telegram|email|web_chat",
  "from_number": "+33612345678",
  "from_email": "client@x.fr",
  "from_name": "Marc Dupont",
  "message": "transcription appel ou texte message",
  "duration_sec": 47,
  "received_at": "2026-05-06T10:23:00Z"
}
```

**Output** (JSON) :
```json
{
  "contact_id": "uuid Webstate",
  "contact_action": "matched|created",
  "intent": "rdv|devis|urgence|support|info|autre",
  "activity_id": "uuid Webstate (type=call/message)",
  "next_action": "rdv_proposed|escalated_owner|task_created|sms_sent",
  "task_id": "uuid (si task_created)",
  "appointment_id": "uuid (si rdv_proposed et confirmé)",
  "owner_alerted": false
}
```

## Workflow détaillé

1. **Skip check** : si `WEBSTATE_REFRESH_TOKEN` absent → log debug "non lié Webstate, skip secretaire" et retourne `{skipped: true}`. Pas d'erreur.

2. **Match contact** :
   - Normalise from_number en E.164 (+33...)
   - GET `/rest/v1/contacts?or=(phone.eq.{e164},email.ilike.{email})&org_id=eq.{ORG}&limit=1` via skill `crm-webstate.list_contacts`.
   - Si trouvé → `contact_action=matched`, `contact_id=...`.
   - Si pas trouvé → POST contact via `crm-webstate.create_contact` avec :
     ```
     {"first_name": from_name || "Inconnu", "phone": e164, "email": from_email,
      "category": "lead", "source": "hermes_secretaire", "status": "new"}
     ```
     → `contact_action=created`.

3. **Classify intent** : prompt LLM court avec `message` → enum :
   - `rdv` : demande de rendez-vous
   - `devis` : demande de devis
   - `urgence` : urgence (mots-clés ou ton)
   - `support` : question SAV
   - `info` : demande info simple
   - `autre` : tout le reste

4. **Insert activity** : POST `/rest/v1/activities` (PostgREST direct) :
   ```
   {"org_id": ORG, "type": "call|message", "subject": intent + résumé court,
    "contact_id": contact_id, "metadata": {"duration_sec": d, "channel": ...,
    "transcription": message}}
   ```

5. **Action selon intent** :
   - **urgence** : `confirmation-hub.notify_owner` Telegram avec contact + résumé. Marque activity comme `priority=high`.
   - **rdv** : si skill `agenda-intelligent-webstate` actif, délègue. Sinon SMS au client "Quel jour vous arrange ?" + crée `contact_tasks` "Rappeler {contact} pour fixer RDV".
   - **devis** : si skill `devis-conversationnel-webstate` actif, délègue. Sinon SMS "Pour un devis, on a besoin de plus d'infos. Vous pouvez nous envoyer une photo ?" + tâche.
   - **support / info / autre** : SMS accusé réception "Bien noté, on vous répond dans 1h" + tâche dans `contact_tasks`.

6. **SMS de confirmation** : via Edge Function Webstate `send-sms` avec :
   ```
   {"to": e164, "message": "...", "org_id": ORG}
   ```
   `org_id` permet d'utiliser le `twilio_sender_id` de l'org (alphanum).

## Pitfalls

- **Pas de doublon contact** : avant create, recherche STRICTE par phone E.164 ET email. Si match partiel (juste email pareil mais nom différent), créer un nouveau contact mais flagger `notes="possible doublon de {existing.id}"` pour audit humain.
- **Heures ouvrées seulement** : si l'appel arrive entre 19h-8h ou weekend, le SMS confirme "On vous rappelle demain matin" plutôt que "dans 1h".
- **Anti-spam SMS** : ne pas envoyer 2 SMS au même from_number en moins de 10 min (cooldown). Check `activities` derniers 10min.
- **Transcription voix** : si Vapi a échoué la transcription (message vide), use intent `autre` + tâche "Réécouter l'enregistrement".

## Toggle ON/OFF

Skill **désactivé par défaut**. Pour activer sur un tenant :
1. Admin ajoute `secretaire-webstate` dans `instances.enabled_skills` via la DB Hermès Platform
2. Restart container tenant → bootstrap.sh active le skill

Pour désactiver : retirer du CSV. Le skill ne s'auto-trigger plus sur appels/messages entrants.

## Handoff

- `crm-webstate` : nécessaire pour toutes les opérations CRUD côté Webstate
- `confirmation-hub` : pour escalade urgence
- `agenda-intelligent-webstate` : pour RDV (si actif)
- `devis-conversationnel-webstate` : pour pré-qualification devis (si actif)

## Configuration env vars

Aucune nouvelle clé. S'appuie sur :
- `WEBSTATE_REFRESH_TOKEN`, `WEBSTATE_ORG_ID`, `WEBSTATE_ANON_KEY`, `WEBSTATE_API_URL` (set par link Webstate)
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (pour escalade urgence, optionnel)
