# Documentation

| Document | Contenu |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | schéma des couches de défense, chemin d'un visiteur, répartition des fichiers |
| [HARDENING.md](HARDENING.md) | chaque mesure : effet, menace visée, commande de vérification, ce qui a été écarté |
| [DEPLOYMENT.md](DEPLOYMENT.md) | déclarer une application, écrire son compose, déployer à la main ou par la CI |
| [BACKUP.md](BACKUP.md) | sauvegardes chiffrées, protection contre la suppression, restauration |
| [OPTIONS.md](OPTIONS.md) | WireGuard et clés FIDO2 : conception, pas encore activés |

## En discussion : logs externes

Les logs restent aujourd'hui sur le serveur (journald persistant, access log Traefik). Un intrus devenu root peut les effacer ; c'est la raison d'être d'une copie externe, envoyée au fil de l'eau.

Sources à envoyer : journald (sshd, sudo, fail2ban, auditd via `audispd`, unités de ce dépôt), l'access log de Traefik, les logs des conteneurs.

| Option | Pour | Contre |
|---|---|---|
| **Vector** (agent) + destination au choix | un seul agent pour Loki, Better Stack, S3, syslog TLS... : la destination peut changer sans toucher au serveur | un agent de plus à tenir à jour |
| Grafana Alloy + Grafana Cloud (Loki) | offre gratuite suffisante pour un VPS, recherche et alertes dans Grafana | lié à l'écosystème Grafana |
| Better Stack (Logtail) | interface simple, alertes intégrées | SaaS payant au-delà d'un petit volume |
| `systemd-journal-upload` vers un serveur à soi | aucun agent tiers | il faut héberger et durcir le récepteur |

Recommandation : Vector, parce qu'il laisse le choix de la destination ouvert. Grafana Alloy si le choix se porte sur Grafana Cloud. Dans les deux cas : identifiant d'envoi en écriture seule (le serveur ne doit pas pouvoir relire ou effacer ce qu'il a envoyé), et une alerte en cas de silence (un serveur qui n'envoie plus rien est un signal en soi).
