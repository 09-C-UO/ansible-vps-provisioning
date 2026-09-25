# Architecture et couches de défense

Ce dépôt applique une défense en profondeur. Chaque couche suppose que la précédente peut céder. Un attaquant qui franchit le pare-feu tombe sur sshd ; s'il obtient une session, il lui manque encore le mot de passe sudo ; s'il devient root, auditd a déjà enregistré ses commandes et AIDE signalera ce qu'il a modifié ; et s'il détruit tout, les sauvegardes sont ailleurs.

## Chemin d'administration (SSH)

```
                         Internet
                             │
┌────────────────────────────▼─────────────────────────────┐
│ 1. Firewall du provider (optionnel)                      │  filtrage avant même d'atteindre la VM
├──────────────────────────────────────────────────────────┤
│ 2. UFW, chaîne INPUT                                     │  tout refusé (DROP) sauf 22222/tcp
│    « limit » : 6 connexions / 30 s par IP                │  80/443 ouverts pour Traefik
├──────────────────────────────────────────────────────────┤
│ 3. fail2ban (jail sshd)                                  │  5 échecs en 10 min → ban UFW,
│                                                          │  durée croissante en cas de récidive
├──────────────────────────────────────────────────────────┤
│ 4. sshd                                                  │  port 22222, clés uniquement,
│    AllowUsers admin deploy, root refusé                  │  crypto moderne (ssh-audit 0/0),
│    MaxAuthTries 3, LoginGraceTime 30                     │  empreinte de clé journalisée
├───────────────────────────┬──────────────────────────────┤
│ 5a. admin                 │ 5b. deploy                   │
│  sudo AVEC mot de passe   │  aucun sudo, aucun groupe    │
│  (le vol de la clé seule  │  docker, pas de tunnel.      │
│  ne donne pas root)       │  Ne peut que déposer une     │
│                           │  demande de déploiement.     │
├───────────────────────────┴──────────────────────────────┤
│ 6. Traces : auditd (commandes root avec l'utilisateur    │
│    d'origine, fichiers sensibles), journald persistant   │
│    et scellé                                             │
├──────────────────────────────────────────────────────────┤
│ 7. Détection : connexion SSH admin, AIDE (quotidien),    │  → alerte Discord #sécurité
│    rkhunter (hebdomadaire)                               │
├──────────────────────────────────────────────────────────┤
│ 8. Sauvegardes chiffrées hors du serveur (restic → S3)   │  dernière ligne : tout reconstruire
└──────────────────────────────────────────────────────────┘
```

## Chemin d'un visiteur (HTTP)

```
 Visiteur
    │
    │   (option) Cloudflare en proxy : WAF, anti-DDoS, IP du serveur masquée
    ▼
┌──────────────────────────────────────────────────────────┐
│ Chaîne DOCKER-USER (iptables, chaîne FORWARD)            │  les ports publiés par Docker
│  · bans fail2ban traefik-auth                            │  CONTOURNENT UFW : le filtrage
│  · (Cloudflare) 80/443 acceptés depuis Cloudflare seul   │  se fait donc ici
└──────────────────────────┬───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│ Traefik (conteneur non-root, lecture seule, cap_drop ALL,│
│ sans socket Docker)                                      │
│  · TLS 1.2+ (Let's Encrypt), redirection HTTP → HTTPS    │
│  · en-têtes de sécurité (HSTS, nosniff, frame deny)      │
│  · rateLimit par IP                                      │
│  · BasicAuth (optionnel, par application)                │
│  · access log → fail2ban                                 │
└──────────────────────────┬───────────────────────────────┘
                           ▼  réseau Docker « edge »
┌──────────────────────────────────────────────────────────┐
│ Service web de l'application (seul membre d'edge)        │
│ non-root, lecture seule, cap_drop ALL, aucun port publié │
└──────────────────────────┬───────────────────────────────┘
                           ▼  réseau « <app>_internal » (internal: true)
┌──────────────────────────────────────────────────────────┐
│ PostgreSQL : joignable par l'application seule,          │
│ sans accès à Internet, sans port publié                  │
└──────────────────────────────────────────────────────────┘
```

Deux applications ne partagent aucun réseau à part `edge`, et seul leur service web y est branché. Une application compromise ne voit donc ni la base de l'autre ni ses workers.

## Répartition des fichiers sur le serveur

| Chemin | Propriétaire | Contenu |
|---|---|---|
| `/opt/traefik/` | root | configuration Traefik, certificats (`acme/`), access log (`logs/`) |
| `/opt/traefik/dynamic/` | root | une route par application, relue à chaud |
| `/opt/apps/<app>/` | root (0750) | `compose.yml`, `compose.edge.yml`, `.env` (secrets, 0600), `release.env` (image en service) |
| `/srv/apps/<app>/` | deploy | contenu publié par deploy (fichiers statiques) |
| `/var/lib/app-deploy/inbox/` | root:deploy (0770) | demandes de déploiement déposées par deploy |
| `/var/lib/app-deploy/status/` | root (lisible) | résultat du dernier déploiement de chaque application |
| `/etc/app-deploy/` | root (0750) | ce que le worker a le droit de faire pour chaque application |
| `/etc/restic/` | root (0700) | dépôt, mot de passe et clés des sauvegardes |

La règle générale : **ce qui décide de ce qui s'exécute appartient à root, ce que deploy produit reste des données.**

## Playbooks

```
provision.sh -i inventories/<env> <IP>
 ├─ bootstrap.yml     une seule fois : comptes, SSH 22 → 22222, root fermé
 └─ site.yml          idempotent, relançable à volonté (connexion admin)
     ├─ hardening.yml    système, SSH, pare-feu, audit, Docker
     ├─ traefik.yml      point d'entrée HTTP, bordure (Cloudflare, ACME)
     └─ apps.yml         rôles notify, monitoring, app_deploy, apps, backup, integrity
```

Les environnements sont des inventaires (`inventories/test`, `inventories/prod`, `inventories/lab`). Chacun a son `group_vars/vps/main.yml` et son vault, et `group_vars/all/main.yml` porte les valeurs par défaut.
