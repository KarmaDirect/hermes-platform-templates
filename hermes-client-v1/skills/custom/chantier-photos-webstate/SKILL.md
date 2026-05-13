---
name: chantier-photos-webstate
description: Upload photos chantier (avant/pendant/après) dans Webstate (table site_photos + chantier_documents). Tag automatique de la phase via vision IA. Génère situation_pdf à la demande. SKIP si tenant non lié.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies:
  - crm-webstate
metadata:
  hermes:
    tags: [webstate, btp, chantier, photos, vision]
    category: btp
    triggers: [channel-message, webhook]
    enabled_by_default: false
    requires_env: [WEBSTATE_REFRESH_TOKEN, WEBSTATE_API_URL, WEBSTATE_ORG_ID]
---

# Chantier Photos Webstate

## When to Use

Le client (artisan, ouvrier, chef chantier) envoie une photo via WhatsApp,
Telegram, email avec une mention du chantier ("photo chantier rue Pasteur",
"avant pose", "fin chantier #234").

## Quick Reference

**Input** :
```json
{
  "image_url": "https://...jpg",
  "channel": "whatsapp|telegram|email|web",
  "from_phone": "+33611111111",
  "caption": "fin chantier rue Pasteur",
  "chantier_hint": "rue Pasteur" | null
}
```

**Output** :
```json
{
  "site_photo_id": "uuid Webstate",
  "chantier_id": "uuid",
  "phase_detected": "avant|pendant|apres|inconnu",
  "tags_detected": ["carrelage", "salle de bain", "fini"],
  "situation_pdf_generated": false
}
```

## Workflow

1. Skip si `WEBSTATE_REFRESH_TOKEN` absent.
2. Match chantier :
   - Recherche `chantiers` par `name ilike caption` ou `address ilike chantier_hint`.
   - Si pas trouvé via texte : query `chantier_members` joint `from_phone` du caller pour trouver le chantier actif de cet ouvrier.
   - Sinon → demande au caller "Photo pour quel chantier ?"
3. **Vision LLM** : analyse photo (si Gemini Vision configuré) :
   - Phase travaux : avant (état initial), pendant (en cours), après (fini)
   - Tags catégoriels : carrelage, peinture, plomberie, électricité, maçonnerie, etc.
   - Score qualité (flou/sombre/cadrage)
4. Upload photo dans bucket Storage Webstate `site-photos` :
   - `POST /storage/v1/object/site-photos/{org_id}/{chantier_id}/{phase}/{ts}.jpg`
   - Récupère URL publique
5. Insert dans `site_photos` Webstate via `hermes-write-table` :
   ```
   {action: "create", table: "site_photos", org_id: ORG,
    data: {chantier_id, photo_url, phase, tags, caption, uploaded_by}}
   ```
6. Insert dans `chantier_documents` aussi (référence cross-table) :
   ```
   {action: "create", table: "chantier_documents", org_id: ORG,
    data: {chantier_id, name: caption, file_url: photo_url, category: "photo"}}
   ```
7. Si caption contient "fin chantier" ou "terminé" → propose génération
   `situation_pdf` via Edge Fn `generate-situation-pdf` Webstate.
8. SMS confirmation au chef de chantier (`organization_members` rôle manager+) :
   "Photo {phase} ajoutée au chantier {name}. Voir : {dashboard_url}"

## Pitfalls

- **Photos floues / 0 contexte** : `phase_detected=inconnu`, log warning, tagger
  "à_revoir" pour que le chef vérifie.
- **Storage quota** : max 50 photos/chantier (audit + nettoyage manuel après).
- **EXIF GPS** : extraire lat/lon de l'EXIF si présent → enrichir `metadata.gps`
  pour cross-check avec `chantiers.address`.
- **Photos sensibles** : si vision détecte personne identifiable (RGPD), flagger
  `metadata.requires_anonymization=true` et pas de partage public.

## Toggle

Désactivé par défaut. Activer = ajouter au CSV `enabled_skills`.

## Handoff

- `crm-webstate` : pour fetch chantiers + write tables via wrapper
- `devis-photo` (skill natif) : si la photo est destinée à un devis, pas un chantier existant, redirige
- `confirmation-hub` : pour génération situation_pdf (HITL = chef chantier valide avant envoi client)
