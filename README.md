# ansible-vps-provisioning

Provisioning Ansible d'un VPS Ubuntu 22.04+ (testé sur 24.04), indépendant du provider : création des comptes, durcissement système, puis Traefik servant une page statique derrière BasicAuth en HTTPS (Let's Encrypt).

## Prérequis

- Ansible ≥ 2.15 sur la machine de contrôle.
- Deux paires de clés SSH, `admin` et `deploy`, dans `ssh_key_dir` (par défaut `~/.ssh/ansible-linode/traeffik-forward-proxy`).
- Un vault `group_vars/all/secrets.vault.yml` (ignoré par git), créé à partir de [`secrets.example.yml`](secrets.example.yml) :

  ```bash
  ansible-vault create group_vars/all/secrets.vault.yml
  ```

  | Clé | Contenu |
  |---|---|
  | `vault_admin_password` | mot de passe sudo d'`admin` (12 caractères minimum) |
  | `vault_admin_password_salt` | 16 caractères `[a-zA-Z0-9./]`, rend le hash stable |
  | `traefik_basic_auth_password` | mot de passe BasicAuth |

- Un VPS Ubuntu créé avec un mot de passe root et sans clé SSH.
- Si un firewall cloud est utilisé : TCP 22, 22222, 80 et 443 ouverts en entrée. Le 22 peut être fermé après le provisioning.

## Utilisation

```bash
./provision.sh <IP>                        # compte initial root
./provision.sh -u ubuntu <IP>              # compte initial ubuntu (AWS, OVH)
./provision.sh -c 198.51.100.40/32 <IP>    # SSH restreint à un CIDR
```

Saisies demandées : mot de passe du vault, validation de l'empreinte SSH, mot de passe root du provider (une fois, pour `ssh-copy-id`).

Le bootstrap ne peut être exécuté qu'une fois. Les exécutions suivantes, idempotentes :

```bash
ansible-playbook site.yml -e ansible_host=<IP> --ask-vault-pass
```

## Séquence

```
provision.sh
 ├─ ssh-copy-id admin.pub → root@IP:22
 ├─ bootstrap.yml
 │   ├─ [local]        alias SSH traefik-test-admin / traefik-test-deploy
 │   ├─ [root:22]      création de admin et deploy, une clé par compte
 │   ├─ [admin:22]     sshd écoute sur 22 et 22222, empreinte ajoutée pour [IP]:22222
 │   └─ [admin:22222]  fermeture du 22, verrouillage de root, retrait de la clé de bootstrap
 └─ site.yml
     ├─ hardening.yml
     └─ traefik.yml
```

Root et le port 22 ne sont fermés qu'après vérification de l'accès admin sur le nouveau port.

## Comptes

| Compte | Accès SSH | Privilèges | Usage |
|---|---|---|---|
| `root` | refusé, mot de passe verrouillé | total | console du provider uniquement |
| `admin` | clé `admin` | sudo avec mot de passe | Ansible, administration |
| `deploy` | clé `deploy` | aucun (ni sudo ni groupe docker) | dépôt de contenu dans `/srv/apps` |

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
| Anti brute-force HTTP | fail2ban sur les 401 de `/opt/traefik/logs/access.log`, bannissement dans `DOCKER-USER` (les ports publiés par Docker contournent UFW) |

Non appliqués car incompatibles avec Docker : `net.ipv4.conf.all.forwarding=0`, `kernel.modules_disabled=1`.

## Variables principales

Dans `group_vars/all/main.yml` :

| Variable | Défaut | Rôle |
|---|---|---|
| `ssh_port` | `22222` | port SSH final |
| `ssh_allowed_cidrs` | `[]` | restriction SSH par CIDR |
| `bootstrap_user` | `root` | compte initial du provider |
| `ssh_key_dir` | `~/.ssh/ansible-linode/traeffik-forward-proxy` | emplacement des clés |
| `traefik_domain` | `""` | domaine ; vide = `<ip>.sslip.io` |
| `traefik_acme_staging` | `false` | CA de test Let's Encrypt |
| `traefik_image`, `coucou_image` | versions épinglées | images Docker |

Avec un domaine sur Cloudflare, l'enregistrement A doit être en mode « DNS only » pour que le challenge HTTP-01 aboutisse.

## Vérification

```bash
ssh root@<IP>                                      # refusé
nc -vz -w 5 <IP> 22                                # timeout
ssh traefik-test-admin 'sudo -k; sudo -n true'     # refusé (mot de passe requis)
ssh traefik-test-deploy 'docker ps; sudo -n true'  # refusés
curl -I http://<domaine>                           # 308 vers https
curl -I https://<domaine>                          # 401
sudo fail2ban-client status traefik-auth           # sur le serveur
```

Chaque exécution de `traefik.yml` produit une réponse 401 (contrôle anonyme), comptée par fail2ban.

## Notes par provider

- Hetzner : le mot de passe root doit être changé à la première connexion (`ssh root@<IP>`) avant de lancer `provision.sh`.
- AWS : pas de mot de passe ; utiliser `-u ubuntu` et installer `admin.pub` avec la keypair AWS.
- VPS recréé avec la même IP : `ssh-keygen -R <IP> && ssh-keygen -R '[<IP>]:22222'`.
