---
name: agenda-intelligent-webstate
description: Gère le calendrier Webstate du tenant intelligemment. Analyse les dispos équipe (organization_members + appointments existants), propose 3 créneaux au client, réserve le RDV dans Webstate, programme les rappels SMS J-1 + H-4. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, agenda, rdv, secretariat]
    category: agenda
    triggers: [channel-message]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Agenda Intelligent Webstate

## When to Use

Le client demande à fixer un rendez-vous : "rdv demain", "vous êtes dispo
quand", "j'aimerais venir voir", "passez chez moi", etc. Le skill prend la
main et oriente jusqu'à la confirmation.

## Quick Reference

**Input** :
```json
{
  "contact_id": "uuid Webstate",
  "purpose": "visite_chantier|rdv_client|consultation|livraison|reunion|autre",
  "preferred_window": "matin|aprem|fin_aprem|tout (default)",
  "preferred_dates": ["2026-05-08", "2026-05-09"] | null,
  "duration_min": 60,
  "location": "chez_client|bureau|telephone|visio",
  "address_hint": "12 rue X, Lyon" | null,
  "assigned_to_preference": "uuid (optionnel)"
}
```

**Output** :
```json
{
  "appointment_id": "uuid Webstate (si confirmé)",
  "proposed_slots": [
    {"start": "2026-05-08T09:00:00Z", "end": "2026-05-08T10:00:00Z", "assigned_to": "uuid"},
    ...
  ],
  "confirmation_method": "sms_pending|email_pending|chat_inline",
  "next_action": "wait_client_confirm|confirmed_booked|fallback_callback"
}
```

## Workflow

1. **Skip check** : `WEBSTATE_REFRESH_TOKEN` absent → return `{skipped: true}`.

2. **Load équipe** : `GET /rest/v1/organization_members?org_id=eq.{ORG}&select=user_id,role,specialty` (via crm-webstate). Récupère qui peut prendre le RDV (member + manager + owner).

3. **Load appointments existants** : `GET /rest/v1/appointments?org_id=eq.{ORG}&start_time=gte.{today}&start_time=lte.{today+14d}` pour voir les créneaux occupés.

4. **Calcul dispos** :
   - Heures ouvrées : 8h-12h + 14h-18h (lun-ven), 9h-12h sam, fermé dim
   - Pas de chevauchement avec appointments existants (par assigned_to)
   - Buffer 15 min entre RDV
   - Si `purpose=visite_chantier` ou `livraison` : éviter les heures repas et trafic Paris/Lyon (8h-9h30, 17h30-19h)

5. **Proposer 3 créneaux** :
   - 1er créneau : le plus tôt dispo qui matche `preferred_window`
   - 2e créneau : J+1 même créneau
   - 3e créneau : J+2 ou J+3 dans une autre window
   - Tri par `assigned_to_preference` si fourni, sinon round-robin équipe

6. **Envoyer proposition** :
   - Si chat actif (web/Telegram/WhatsApp) : message inline avec 3 boutons
   - Sinon : SMS via `crm-webstate.send_sms` "Je vous propose : 1) {date1} 2) {date2} 3) {date3}. Répondez 1, 2, ou 3."

7. **Attente confirmation** : status `wait_client_confirm`. Le skill `confirmation-hub` gère la réponse asynchrone.

8. **Sur confirmation** :
   - `crm-webstate.create_appointment` avec :
     ```
     {"org_id": ORG, "title": purpose+contact_name, "start_time": slot.start,
      "end_time": slot.end, "type": purpose, "contact_id": contact_id,
      "assigned_to": slot.assigned_to, "location": location, "status": "scheduled"}
     ```
   - SMS confirmation au client : "RDV confirmé : {date} avec {membre}. Adresse : {address}."
   - Active automation native Webstate `sms_reminder_j1` et `sms_reminder_h4` qui prennent le relais (Webstate envoie automatiquement les rappels J-1 18h et H-4).

## Pitfalls

- **Ne pas double-book** : check_overlap obligatoire avant l'INSERT appointment.
- **Pas en dehors heures ouvrées** sauf si `org.settings.work_after_hours = true`.
- **Fériés FR** : skill `briefing-quotidien` peut maintenir une liste, sinon utiliser API `https://calendrier.api.gouv.fr/jours-feries/metropole.json` (en cache 1 jour).
- **Si aucune dispo dans 14 jours** : retour `next_action=fallback_callback` + tâche "Rappeler {contact} pour RDV manuel".
- **Conflit rappels Webstate** : Webstate gère les rappels J-1/H-4. NE PAS programmer de SMS rappel côté Hermès = doublon.

## Toggle ON/OFF

Désactivé par défaut. Activer en ajoutant `agenda-intelligent-webstate` à
`enabled_skills` côté DB Hermès. Restart container.

## Handoff

- `secretaire-webstate` : appelle ce skill quand l'intent est `rdv`
- `crm-webstate` : pour list/create appointments + send_sms
- `confirmation-hub` : pour gérer la réponse asynchrone du client
