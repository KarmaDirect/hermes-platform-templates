---
name: devis-from-description
description: Génère un brouillon de devis structuré (lignes, HT/TVA/TTC, hypothèses, exclusions) à partir d'une description texte des travaux.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [business, sales, devis, btp, services, hitl]
    category: business
    triggers: [webhook, manual]
---

# Devis from Description

## When to Use

Quand un patron de PME (BTP en priorité) reçoit une demande de devis par email/téléphone/web et veut un **brouillon structuré** prêt à être complété (prix unitaires) puis envoyé au client. Pas pour générer le devis final — c'est un brouillon HITL (human-in-the-loop).

## Règle d'or

**N'invente JAMAIS un prix précis.** Tu proposes une décomposition en lignes avec `unit_price_estimated: null` + `needs_pricing: true`. Le patron met les vrais prix avant envoi.

## Quick Reference

**Input** (JSON) :
```json
{
  "description": "Texte libre de la demande client",
  "vertical": "btp|services|restauration|...",
  "surface_m2": 30,
  "budget_indicatif": null,
  "ville": "La Rochelle",
  "contact_name": "Marc Dupont"
}
```

**Output** (JSON STRICT) :
```json
{
  "devis": {
    "client_name": "string|null",
    "ville": "string|null",
    "items": [
      {
        "label": "string",
        "description": "string|null",
        "quantity": number,
        "unit": "m²|ml|h|j|pièce|forfait",
        "unit_price_estimated": null,
        "total_estimated": null,
        "needs_pricing": true
      }
    ],
    "total_ht_estimated": null,
    "tva_rate": 20.0,
    "total_ttc_estimated": null,
    "validity_days": 30,
    "delai_realisation": "string|null"
  },
  "hypotheses_assumed": ["..."],
  "exclusions": ["..."],
  "ready_to_send": false
}
```

## Procedure

1. Lis la description librement.
2. Décompose en **lignes distinctes** : chaque tâche, chaque matériau, chaque déplacement = une ligne. **Pas de "forfait global"**.
3. Pour chaque ligne, détermine :
   - `quantity` (surface, longueur, heures, nombre de pièces)
   - `unit` (`m²`, `ml`, `h`, `j`, `pièce`, `forfait`)
   - `needs_pricing: true` (toujours pour les nouveaux devis)
4. Liste `hypotheses_assumed` : tout ce que tu as supposé (TVA standard 20%, accès facile, sol existant ok, surface confirmée non vérifiée terrain…).
5. Liste `exclusions` : ce qui n'est PAS inclus (démolition, évacuation déchets, finitions peinture, raccordements…).
6. Estime `delai_realisation` honnêtement (ex : "2 à 3 jours", "1 semaine après commande matériaux"). Si tu ne sais pas, `null`.
7. **Toujours** : `ready_to_send: false`. C'est HITL, le patron valide.

## Pitfalls

- Description trop vague (<20 mots significatifs) → `items: []`, `hypotheses_assumed: ["Description trop vague pour générer le devis — demander précisions"]`.
- Pas de symbole € dans les nombres (format number).
- Pas de centimes (arrondi euro).
- Pas de Markdown dans la sortie : JSON strict.
- Si surface mentionnée par client mais pas vérifiée terrain : ajouter "Surface confirmée par client non vérifiée terrain" dans `hypotheses_assumed`.

## Verification

- `ready_to_send` est strictement `false`.
- Toutes les lignes ont `needs_pricing: true` (sauf si l'input fournissait des prix explicites).
- `tva_rate` est un nombre (pas une string).
- `hypotheses_assumed` non vide (au moins TVA + accès).
- `exclusions` non vide (au moins évacuation déchets pour BTP).
