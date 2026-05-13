---
name: crm-doublons
description: Audite le CRM du tenant et détecte les contacts/leads doublons (même email, même téléphone normalisé E.164, ou similarité nom+ville Levenshtein élevée). Propose un groupe de fusion avec primary désigné. Ne fusionne JAMAIS sans validation humaine.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-client-lookup
metadata:
  hermes:
    tags: [crm, hygiene, audit, hitl]
    category: crm
    triggers: [webhook, channel-message]
---

# CRM Doublons

## When to Use

Le CRM d'une PME accumule des doublons sans qu'on s'en rende compte : le même client saisi 2 fois (une via formulaire, une via téléphone), le même fournisseur orthographié différemment, le même prospect créé par 2 commerciaux. Conséquences : SMS envoyé deux fois, devis incohérents, chiffres pipeline faussés.

Ce skill audite le CRM à la demande (chat) ou via cron mensuel, retourne les groupes de doublons trouvés et propose une fusion. Il ne fusionne jamais lui-même : output destiné à l'humain qui valide.

Cas d'usage typiques (input chat patron) :
- "Trouve les doublons dans mon CRM"
- "Audit hygiène contacts"
- "Vérifie qu'on n'a pas de clients en double"
- "Combien de doublons dans mes leads ?"

## Quick Reference

**Input** (JSON, tous champs optionnels) :
```json
{
  "scope": "contacts|leads|fournisseurs|all",
  "min_confidence": 0.85,
  "limit_groups": 50,
  "exclude_ids": ["uuid1", "uuid2"]
}
```

**Output** (JSON STRICT) :
```json
{
  "audit_id": "audit-2026-05-05-001",
  "scope_audited": "contacts",
  "total_records": 482,
  "groups_found": 12,
  "groups": [
    {
      "group_id": "g1",
      "match_reason": "email_exact",
      "confidence": 1.0,
      "primary_id": "uuid-primary",
      "primary_summary": "Jean Dupont — jean.dupont@bouygues.fr — 06 12 34 56 78 — Lyon",
      "duplicates": [
        {
          "id": "uuid-dup-1",
          "summary": "J. Dupont — jean.dupont@bouygues.fr — Lyon",
          "fields_matching": ["email"],
          "fields_diverging": ["nom", "phone"]
        }
      ],
      "merge_suggestion": {
        "keep_id": "uuid-primary",
        "merge_fields": {
          "phone": "06 12 34 56 78",
          "nom": "Jean Dupont"
        },
        "delete_ids": ["uuid-dup-1"]
      }
    }
  ],
  "stats_by_reason": {
    "email_exact": 7,
    "phone_e164_exact": 3,
    "name_city_similar": 2
  },
  "next_action": "review_groups"
}
```

## Workflow

1. **Récupération données** : appeler `crm-client-lookup` avec `mode: "list"` pour récupérer tous les contacts/leads/fournisseurs selon le `scope`. Si volume > 5000 records, paginate par 1000.

2. **Normalisation** :
   - Email : `lowercase` + `trim` + retirer `+tag` Gmail (jean+work@gmail.com → jean@gmail.com)
   - Téléphone : convertir en E.164 (`+33612345678`). Retirer espaces, points, tirets. Préfixer +33 si commence par 0 et que pays = FR.
   - Nom : `lowercase` + `trim` + retirer accents + retirer civilité (M., Mme, Mr, Mrs)
   - Ville : `lowercase` + `trim` + retirer accents + retirer code postal embarqué

3. **Matching multi-stratégies** (priorité décroissante) :
   - **email_exact** (confidence 1.0) : groupe par email normalisé non-vide
   - **phone_e164_exact** (confidence 1.0) : groupe par téléphone E.164 non-vide ET non-déjà-matché par email
   - **name_city_similar** (confidence 0.85-0.95) : Levenshtein normalisé sur nom+ville (seuil 0.85). Uniquement si email ET phone manquent.
   - **siret_exact** (confidence 1.0, fournisseurs uniquement) : groupe par SIRET 14 chiffres

4. **Filtrage** : exclure les groupes < `min_confidence` (default 0.85). Limit à `limit_groups` (default 50). Exclure les ids dans `exclude_ids`.

5. **Sélection primary** : pour chaque groupe, le primary est celui avec :
   - Le plus de champs renseignés (score = nb champs non-null)
   - À score égal : le plus ancien (created_at le plus petit, sauvegarde de l'historique)

6. **Suggestion de fusion** : pour chaque champ qui diverge, proposer la valeur la plus complète (longueur > 0 + format valide). Stocker dans `merge_suggestion.merge_fields`.

7. **Pas d'action** : output JSON. La fusion réelle est faite par un autre skill `crm-fusion` (à venir) après validation humaine via HITL Telegram/Email.

## Pitfalls

- **Ne JAMAIS fusionner automatiquement** : ce skill produit un rapport. La fusion réelle est manuelle ou via skill séparé `crm-fusion` après validation HITL.
- **Faux positifs nom+ville** : "Jean Dupont Paris" et "Jean Dupont Paris" peuvent être 2 personnes réelles. Confidence < 0.95 sur ce critère, et marquer `requires_human_review: true`.
- **Email partagé légitime** : `contact@entreprise.fr` peut apparaître sur 5 contacts différents (le DG, le DAF, le commercial...). Si l'email matche mais le nom/téléphone diffère significativement, baisser confidence à 0.70 et noter `match_reason: "shared_corporate_email"`.
- **Performance** : sur 10000+ contacts, ne PAS faire un produit cartésien O(n²). Utiliser des hashmaps par clé normalisée pour le matching exact, et bucketing par initiales pour le fuzzy match.
- **Scope limité** : ne pas mélanger contacts et fournisseurs dans le même groupe — ce sont des entités séparées même si même email.
- **Output JSON strict** : pas de markdown code-fences, pas de texte autour. Le frontend parse directement.

## Channels d'invocation

- **Chat web** : "trouve les doublons", "audit CRM", "vérifie hygiène contacts" → trigger automatique
- **Cron mensuel** : 1er du mois 8h UTC, audit complet, push résumé Telegram patron
- **Webhook custom** : `POST /crm/doublons-audit` avec `scope` + filtres
- **Telegram** : `/audit_crm` commande directe au bot du tenant

## Configuration env vars

Aucune nouvelle clé API requise. Le skill s'appuie sur :
- `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` (déjà set au boot) pour query la DB Webstate du tenant via skill `crm-client-lookup`
- LLM provider configuré dans `config.yaml` pour la sélection du primary et la rédaction du résumé

## Handoff vers d'autres skills

- **`crm-client-lookup`** : prérequis, sert à récupérer la liste des contacts/leads/fournisseurs
- **`crm-fusion`** (futur, V1.1) : prend un `merge_suggestion` validé et exécute la fusion réelle dans la DB
- **`telegram-send-rich`** : pour pousser le résumé d'audit au patron avec boutons "Valider/Rejeter" par groupe
- **`briefing-quotidien`** : peut inclure un compteur "X doublons à traiter" dans le récap mensuel

## Roadmap

- v1.1 : skill séparé `crm-fusion` qui exécute la fusion validée
- v1.2 : détection automatique de doublons à la création (intercept au moment du POST contact, propose merge avant insert)
- v1.3 : matching IA sémantique sur "Boulangerie Marie" vs "Marie Pâtisserie" via embedding
