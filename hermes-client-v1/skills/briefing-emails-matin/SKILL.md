---
name: briefing-emails-matin
description: Lit les emails non-lus Gmail des dernières 24h via Composio MCP et produit un briefing markdown court, classé par urgence et type d'expéditeur.
version: 1.0.0
author: Hermès Platform
license: MIT
dependencies: []
metadata:
  hermes:
    tags: [productivity, email, gmail, briefing, composio]
    category: productivity
    triggers: [cron, manual]
---

# Briefing Emails Matin

## When to Use

Le matin avant 9h, ou à la demande du patron. Tu lis les emails non-lus reçus dans les dernières 24h, tu les classes par urgence + type d'expéditeur, et tu produis un briefing court (≤ 8 lignes). Pas d'envoi automatique, pas d'action — c'est de la lecture + résumé.

## Quick Reference

**Input** (JSON, optionnel) :
```json
{
  "lookback_hours": 24,
  "max_emails": 20,
  "owner_email": "patron@boite.fr"
}
```

**Output** (Markdown strict) :
```markdown
## Briefing emails du <date>

**🔴 Urgent (n)**
- <expéditeur> · <objet> · <résumé 1 ligne>

**👥 Clients (n)**
- ...

**🏭 Fournisseurs (n)**
- ...

**📨 Autres (n)**
- ...

---
*<n_total> emails analysés · <n_unread_remaining> encore à traiter*
```

## Procedure

1. Appelle Composio MCP `gmail.list_messages` avec `q="is:unread newer_than:1d"`, `max_results: max_emails || 20`.
2. Pour chaque message ID retourné, appelle `gmail.get_message` avec `format: "metadata"` (récupère From / Subject / Date) puis fais un appel `format: "full"` UNIQUEMENT pour les 5 plus récents (économie de tokens).
3. Classe chaque email :
   - **Urgent** si Subject contient `URGENT|IMPORTANT|ASAP|relance|impayé|retard|panne`, OU si l'expéditeur a écrit ≥2 fois en 24h non-lu.
   - **Clients** si l'expéditeur a déjà reçu un devis/facture (vérifie en mémoire long terme `crm.contacts` si disponible).
   - **Fournisseurs** si domaine expéditeur ∈ liste fournisseurs en mémoire OU si keywords `commande|livraison|stock|facture fournisseur`.
   - **Autres** : tout le reste.
4. Pour chaque email gardé dans le briefing, résume en **1 ligne max** (≤ 80 caractères). Pas de "vous avez reçu", attaque direct : "Demande devis 12 fenêtres, urgent semaine prochaine".
5. Renvoie le markdown final, rien d'autre. **Pas d'introduction, pas de conclusion**.

## Pitfalls

- **N'envoie jamais d'email automatiquement.** Le briefing est passif.
- Si plus de 20 emails, prends les 20 plus récents — ne paginate pas.
- Si Composio renvoie 401/403, dis simplement : `> ⚠️ Gmail non connecté. Va dans /integrations pour autoriser.` et stop.
- Ne fabrique aucun expéditeur ni objet — si Composio renvoie un résultat partiel, signale-le.
- Pas de PII en clair dans la sortie : si un email contient un numéro CB / SIREN, remplace-le par `<redacted>`.

## Verification

Avant de renvoyer le briefing, vérifie :
- [ ] Markdown bien-formé (titres niveau 2 + bullets)
- [ ] ≤ 8 lignes au total (4 catégories × ≤ 2 emails = OK)
- [ ] Footer `n_total / n_unread_remaining` cohérent avec ce que Composio a retourné
- [ ] Aucun email du domaine `noreply|no-reply|notification` dans la catégorie Clients

## Required credentials

- `COMPOSIO_API_KEY` (env var, présente dans `/opt/data/.env.credentials` si le tenant l'a saisie dans `/credentials`)
- Compte Gmail connecté côté Composio (à vérifier via `composio integrations list`)
