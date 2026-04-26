# Skill — relance-impayes

Relance les clients qui n'ont pas réglé leurs factures, sans casser la relation.

## Cadence
- **J+7** : email courtois avec lien de paiement.
- **J+15** : email + SMS ferme mais respectueux.
- **J+30** : escalade Telegram au patron, plus aucune action automatique.

## Garde-fous
- Montants > 2000 € → confirmation patron avant tout envoi.
- Jamais d'envoi le week-end ou jours fériés.
- Stoppe immédiatement si la facture passe à `paid` entre temps.

## Source de données
Lit `invoices` du SaaS Hermès Platform via Supabase service role.
