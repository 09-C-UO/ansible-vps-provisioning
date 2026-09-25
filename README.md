# ansible-vps-provisioning

Provisioning Ansible d'un VPS Ubuntu 22.04+ (testé sur 24.04), indépendant du provider : création des comptes, durcissement système, Traefik comme point d'entrée HTTPS unique (Let's Encrypt), applications multi-conteneurs déployées sans accès Docker pour le compte de déploiement, sauvegardes chiffrées hors serveur, contrôle d'intégrité et alertes Discord.

Documentation détaillée : [`docs/`](docs/README.md), dont [HARDENING.md](docs/HARDENING.md) (chaque mesure, sa raison, sa vérification) et [DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Prérequis

- Ansible ≥ 2.15 sur la machine de contrôle.
- Un inventaire par environnement dans `inventories/<env>/` : `hosts.ini` et `group_vars/vps/main.yml` (`test`, `prod`, `lab` fournis).
- Deux paires de clés SSH, `admin` et `deploy`, dans `ssh_key_dir` de l'inventaire.
- Un vault par environnement, `inventories/<env>/group_vars/vps/secrets.vault.yml` (ignoré par git), créé à partir de [`secrets.example.yml`](secrets.example.yml) :

  ```bash
  ansible-vault create inventories/prod/group_vars/vps/secrets.vault.yml
  ```

  | Clé | Contenu |
  |---|---|
  | `vault_admin_password` | mot de passe sudo d'`admin` (12 caractères minimum) |
  | `vault_admin_password_salt` | 16 caractères `[a-zA-Z0-9./]`, rend le hash stable |
  | `traefik_basic_auth_password` | mot de passe BasicAuth |
  | `app_secrets` | variables d'environnement secrètes par application (optionnel) |
  | `discord_webhook_infra`, `discord_webhook_security` | alertes (optionnel) |
  | `restic_password`, `restic_s3_access_key`, `restic_s3_secret_key` | sauvegardes (si `backup_enabled`) |

- Un VPS Ubuntu créé avec un mot de passe root et sans clé SSH.
- Si un firewall cloud est utilisé : TCP 22, 22222, 80 et 443 ouverts en entrée. Le 22 peut être fermé après le provisioning.

## Utilisation

Raccourcis : `just` liste les recettes (`just provision prod <IP> -u ubuntu`, `just site prod <IP>`, `just tags prod <IP> apps`, `just check`, `just lab`...). Les commandes complètes :

```bash
./provision.sh <IP>                              # inventaire test, compte initial root
./provision.sh -i inventories/prod <IP>          # autre environnement
./provision.sh -u ubuntu <IP>                    # compte initial ubuntu (AWS, OVH)
./provision.sh -c 198.51.100.40/32 <IP>          # SSH restreint à un CIDR
```

Saisies demandées : mot de passe du vault, validation de l'empreinte SSH, mot de passe root du provider (une fois, pour `ssh-copy-id`).

Le bootstrap ne peut être exécuté qu'une fois. Les exécutions suivantes, idempotentes :

```bash
ansible-playbook site.yml -i inventories/<env>/hosts.ini -e ansible_host=<IP> --ask-vault-pass
ansible-playbook site.yml ... --tags apps       # une partie seulement : apps, deploy, backup, integrity, notify
```

Déployer une nouvelle version d'une application (détail : [DEPLOYMENT.md](docs/DEPLOYMENT.md)) :

```bash
ssh <prefix>-deploy deploy-request <app> <registry/image>@sha256:<digest>
```

## Séquence

```
provision.sh
 ├─ ssh-copy-id admin.pub → root@IP:22
 ├─ bootstrap.yml
 │   ├─ [local]        alias SSH <prefix>-admin / <prefix>-deploy
 │   ├─ [root:22]      création de admin et deploy, une clé par compte
 │   ├─ [admin:22]     sshd écoute sur 22 et 22222, empreinte ajoutée pour [IP]:22222
 │   └─ [admin:22222]  fermeture du 22, verrouillage de root, retrait de la clé de bootstrap
 └─ site.yml
     ├─ hardening.yml
     ├─ traefik.yml
     └─ apps.yml        rôles notify, monitoring, app_deploy, apps, backup, canary, integrity
```

Root et le port 22 ne sont fermés qu'après vérification de l'accès admin sur le nouveau port.

## Comptes

| Compte | Accès SSH | Privilèges | Usage |
|---|---|---|---|
| `root` | refusé, mot de passe verrouillé | total | console du provider uniquement |
| `admin` | clé `admin` | sudo avec mot de passe | Ansible, administration |
| `deploy` | clé `deploy` (+ clés CI à commande forcée) | aucun (ni sudo ni groupe docker) | contenu dans `/srv/apps`, demandes de déploiement |

L'accès au socket Docker équivaut à root : aucun utilisateur n'est dans le groupe `docker`.

## Mesures de sécurité

| Domaine | Mesures |
|---|---|
| SSH | port 22222, clés uniquement, `AllowUsers admin deploy`, crypto moderne (curve25519, sntrup761, ed25519, MAC ETM), `LogLevel VERBOSE`, forwarding interdit pour deploy |
| Réseau | UFW entrée deny (DROP), SSH en `limit`, fail2ban sur sshd |
| Noyau | sysctl (redirects, source routing, rp_filter, BPF, ptrace, dmesg, sysrq, fifos), modules dccp/sctp/rds/tipc désactivés |
| Système | mises à jour de sécurité automatiques, AppArmor, journald persistant, pas de core dumps, `UMASK 027`, bannière |
| Audit | règles auditd sur comptes, sudoers, SSH, firewall, Docker, systemd, `/opt/traefik`, et commandes exécutées en root (`ausearch -k root_commands -i`) |
| Docker | dépôt officiel, `no-new-privileges`, rotation des logs, pas d'API réseau |
| Traefik | file provider (socket Docker non monté), conteneurs non-root en lecture seule avec `cap_drop: ALL`, TLS 1.2 minimum, HSTS, `rateLimit`, BasicAuth bcrypt |
| Anti brute-force HTTP | fail2ban sur les 401 de `/opt/traefik/logs/access.log`, bannissement dans `DOCKER-USER` (les ports publiés par Docker contournent UFW), ou via l'API Cloudflare derrière Cloudflare |
| Applications | compose vérifié avant déploiement (ni `privileged`, ni port publié, ni socket Docker, `cap_drop: ALL`), base sur un réseau interne sans Internet |
| Déploiement | deploy dépose une demande, un worker root la revalide (dépôt autorisé, digest obligatoire, `O_NOFOLLOW`), déploie et revient en arrière si l'application ne répond pas |
| Intégrité | AIDE quotidien, rkhunter hebdomadaire, alerte à chaque connexion SSH d'admin, alertes Discord `#security` ; faux secrets (honeytokens canarytokens.org) dont l'usage alerte par e-mail |
| Surveillance | disque, inodes, mémoire, charge toutes les 5 min ; alerte au dépassement et au retour à la normale |
| Sauvegardes | restic chiffré vers S3, dumps PostgreSQL, vérification hebdomadaire, restauration testée chaque mois |

Non appliqués car incompatibles avec Docker : `net.ipv4.conf.all.forwarding=0`, `kernel.modules_disabled=1`.

## Variables principales

Dans `group_vars/all/main.yml` :

| Variable | Défaut | Rôle |
|---|---|---|
| `ssh_port` | `22222` | port SSH final |
| `ssh_allowed_cidrs` | `[]` | restriction SSH par CIDR |
| `bootstrap_user` | `root` | compte initial du provider |
| `ssh_key_dir` | `~/.ssh/ansible-linode/traeffik-forward-proxy` | emplacement des clés |
| `traefik_domain` | `""` | domaine de base (`traefik_effective_domain`) ; vide = `<ip>.sslip.io` |
| `traefik_acme_staging` | `false` | CA de test Let's Encrypt |
| `traefik_image`, `coucou_image` | versions épinglées | images Docker (`coucou_image` : exemple `apps/coucou`) |
| `apps` | `[]` | applications servies ([DEPLOYMENT.md](docs/DEPLOYMENT.md)) ; vide = serveur prêt, Traefik répond 404 |
| `edge_proxy` | `none` | `cloudflare` : proxy Cloudflare devant Traefik |
| `acme_challenge` | `http` | `dns` : challenge DNS-01 (`acme_dns_provider`, `acme_dns_env`) |
| `deploy_ci_public_keys` | `[]` | clés CI limitées à `deploy-request` |
| `backup_enabled` | `false` | sauvegardes restic ([BACKUP.md](docs/BACKUP.md)) |

Avec un domaine sur Cloudflare en mode « DNS only », rien de plus n'est nécessaire. En mode proxy, voir [HARDENING.md §10](docs/HARDENING.md#10-bordure-cloudflare-et-certificats).

## Vérification

```bash
ssh root@<IP>                                      # refusé
nc -vz -w 5 <IP> 22                                # timeout
ssh <prefix>-admin 'sudo -k; sudo -n true'         # refusé (mot de passe requis)
ssh <prefix>-deploy 'docker ps; sudo -n true'      # refusés
curl -sI http://<IP>                               # 308 vers https
curl -skI https://<IP>                             # 404 sans application ; sinon le code de l'app
sudo fail2ban-client status traefik-auth           # sur le serveur
```

Sans application, le 404 (avec le certificat auto-signé de Traefik) est l'état attendu d'un serveur prêt.

Chaque exécution de `site.yml` produit une réponse 401 par application en BasicAuth (contrôle anonyme), comptée par fail2ban.

## Tests locaux

Un conteneur Ubuntu 24.04 privilégié joue le rôle d'un VPS neuf ; rien n'est écrit hors de `tests/lab/.work` :

```bash
tests/lab/run.sh             # conteneur neuf, provision.sh, second run (changed=0 exigé), tests
tests/lab/run.sh test        # test_deploy.sh (déploiement, rollback, attaques) + test_ops.sh
python3 tests/test_compose_lint.py
```

Les réglages qui agissent sur tout le noyau (règles auditd, sysctl hors réseau, AppArmor) sont sautés dans un conteneur, qui partage le noyau de la machine hôte.

## Notes par provider

- Hetzner : le mot de passe root doit être changé à la première connexion (`ssh root@<IP>`) avant de lancer `provision.sh`.
- AWS : pas de mot de passe ; utiliser `-u ubuntu` et installer `admin.pub` avec la keypair AWS.
- VPS recréé avec la même IP : `ssh-keygen -R <IP> && ssh-keygen -R '[<IP>]:22222'`.
