# Skill — compta-classement

Toutes les pièces comptables qui arrivent par email ou WhatsApp sont OCRisées, classées et stockées au bon endroit.

## Pipeline
1. Ingestion (PJ email, photo WhatsApp, upload manuel).
2. OCR via Gemini Vision.
3. Détection type (facture fournisseur, ticket, note de frais).
4. Catégorisation selon plan comptable du métier (BTP : matériaux, outillage…).
5. Stockage Supabase + export optionnel Pennylane / Qonto / Google Drive.

## Human-in-the-loop
- Catégorie inconnue → demande au patron.
- Montant > 500 € → confirmation avant export comptable.
