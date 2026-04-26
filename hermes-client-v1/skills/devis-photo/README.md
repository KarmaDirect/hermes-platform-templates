# Skill — devis-photo

Une photo de chantier (mur abimé, salle de bain à rénover, etc.) → devis chiffré.

## Pipeline
1. Réception de la photo (WhatsApp / Telegram / email).
2. Analyse vision via Gemini : surfaces, matériaux, état.
3. Génération de lignes de devis avec marge configurée.
4. Confiance < 0.7 → escalade au patron pour ajustement manuel.
5. Production du PDF.

## Modèle vision
`gemini-2.0-flash` (économique, multimodal).

## Human-in-the-loop
**Oui**, surtout sous le seuil de confiance.
