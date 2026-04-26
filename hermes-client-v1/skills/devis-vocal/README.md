# Skill — devis-vocal

Le patron envoie un vocal "fais un devis pour 50m² de placo chez Mme Durand", Hermès en sort un devis chiffré.

## Pipeline
1. Réception du vocal (WhatsApp / Telegram / upload).
2. ASR via Gemini → transcription.
3. Extraction des lignes de devis + matching catalogue prix client.
4. Génération du PDF.
5. Demande de confirmation au patron via Telegram avant envoi client.

## Channels recommandés
`whatsapp` ou `telegram` (entrée), `email` (envoi sortant).

## Human-in-the-loop
**Oui**, confirmation systématique avant envoi.
