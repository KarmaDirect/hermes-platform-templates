# briefing-emails-matin

Skill d'ouverture de journée pour les agents Hermès. Lit la boîte Gmail du tenant via Composio MCP et produit un briefing markdown court (≤ 8 lignes), classé par urgence + type d'expéditeur.

## Quick install (côté admin)

1. Le tenant configure son **COMPOSIO_API_KEY** dans `/credentials`.
2. Le tenant connecte **Gmail** via `/integrations` (OAuth Composio).
3. L'admin pousse ce skill sur le tenant via `/admin/skills-marketplace` → "Push to all".
4. Le tenant peut soit déclencher manuellement (`/skill briefing-emails-matin` dans le chat), soit attendre le cron 8h00 UTC du lundi au vendredi.

## Output exemple

```markdown
## Briefing emails du 02/05/2026

**🔴 Urgent (1)**
- Garage Cantin · Devis 12 fenêtres · Demande pour semaine prochaine, urgent

**👥 Clients (2)**
- Mme Durand · Suivi chantier salle de bain · Question photos avant/après
- M. Petit · Facture F-2026-0042 · Confirme virement effectué

**🏭 Fournisseurs (1)**
- BricoMat Pro · Livraison commande #4521 · Décalée à mardi 14h

**📨 Autres (3)**
- Pôle Emploi · Newsletter offres BTP local
- LinkedIn · 4 nouveaux contacts cette semaine
- Stripe · Récap hebdomadaire paiements

---
*7 emails analysés · 12 encore à traiter*
```

## Why this design

- **Output fixé en markdown**, pas JSON : le briefing est lisible direct dans le chat sans rendering custom.
- **≤ 8 lignes** : si tu lis le briefing en 5s, c'est utile. Au-delà, c'est de la pollution.
- **Classification par expéditeur** plutôt que par sujet : un patron BTP gère ses clients/fournisseurs/spam différemment.
- **Pas d'envoi automatique** : ce skill est passif. Il informe, ne décide pas.
