# Skill — reception-call

Standard téléphonique IA disponible 24/7, branché sur Vapi.

## Ce que fait le skill
- Reçoit chaque appel entrant via webhook Vapi.
- Qualifie l'appelant selon le secteur (BTP, restauration, etc.).
- Propose un créneau de RDV via le CRM si le besoin est identifié.
- Route vers messagerie ou transfert humain si hors capacité IA.
- Écrit un résumé + un contact dans le CRM Hermès Platform.

## Channels requis
`vapi`

## Sortie typique
- Contact créé / mis à jour dans le CRM
- Événement `call.qualified` ou `call.handed_off` dans `hermes_events`
- Notification Telegram au patron si urgence ou montant > seuil
