# Skill — suivi-chantier

Surveille en continu les RDV/chantiers et alerte en cas d'anomalie.

## Détections
- Chantier non démarré 30 min après l'heure prévue.
- Aucune photo "pendant" uploadée 24h après le démarrage.
- Météo défavorable (>5mm pluie) prévue J+1 → propose un report au client.

## Sorties
- Notification Telegram au patron.
- SMS au client si report météo confirmé (humain-in-the-loop sur le report).
- Mini rapport quotidien soir compilant les chantiers du jour.
