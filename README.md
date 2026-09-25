# traefik-ansible

Provisionne un VPS Ubuntu neuf (22.04+ ; 24.04 recommandé), quel que soit le provider (Linode, Hetzner, OVH, AWS…), **en une seule commande** :
durcissement sécurité, puis Traefik qui sert une page "coucou" derrière une authentification BasicAuth, en HTTPS Let's Encrypt.

Le dépôt est autonome : tout ce qu'il faut est dans ce dossier, plus les deux clés SSH et le vault, qui restent sur ta machine.

## Démarrage

### 1. Une seule fois : le vault

```bash
cd traefik-ansible
ansible-vault create group_vars/all/secrets.vault.yml
```

Colle les clés de [`secrets.example.yml`](secrets.example.yml) avec de vraies valeurs :

| Clé | Rôle |
|---|---|
| `vault_admin_password` | mot de passe sudo d'admin, 12 caractères minimum |
| `vault_admin_password_salt` | exactement 16 caractères `[a-zA-Z0-9./]` ; garde le hash stable d'un run à l'autre |
| `traefik_basic_auth_password` | mot de passe de la page coucou (utilisateur `admin`) |

Le fichier est chiffré et ignoré par git.

### 2. Créer le VPS

- Choisis Ubuntu 24.04 **avec un mot de passe root et sans clé SSH**. Le provider ne voit jamais tes clés.
- Si le provider a un firewall cloud, ouvre en entrée **TCP 22, 22222, 80 et 443**. Une fois le provisioning terminé, tu peux fermer le 22.

### 3. Lancer

```bash
./provision.sh 203.0.113.25                     # root (Linode, Hetzner, DO…)
./provision.sh -u ubuntu 203.0.113.25           # AWS, OVH
./provision.sh -c 198.51.100.40/32 203.0.113.25 # SSH limité à ton IP
```

Le script te demande trois choses, dans cet ordre, toutes dans le même terminal :

1. le mot de passe du **vault**, une seule fois (il est réutilisé par chaque étape) ;
2. `yes` pour accepter l'empreinte SSH du serveur, à la première connexion ;
3. le **mot de passe root** du provider, une seule fois, pour `ssh-copy-id`.

Tu n'as jamais besoin d'ouvrir de session SSH toi-même. À la fin :

```bash
ssh traefik-test-admin     # admin, port 22222, clé admin
ssh traefik-test-deploy    # deploy, port 22222, clé deploy
# page : https://203-0-113-25.sslip.io  (identifiant admin + mot de passe du vault)
```

### Relancer plus tard

Le bootstrap ne se lance qu'une fois : ensuite, root est fermé et le port 22 aussi. Tout le reste est idempotent :

```bash
ansible-playbook site.yml -e ansible_host=203.0.113.25 --ask-vault-pass
```

Pour ne pas répéter `-e ansible_host`, mets l'IP dans `inventory.ini`.

## Ce qui se passe, dans l'ordre

```
provision.sh
 ├─ ssh-copy-id admin.pub → root@IP:22            (mot de passe provider)
 ├─ bootstrap.yml
 │   ├─ [local]  alias ~/.ssh/config traefik-test-admin / -deploy
 │   ├─ [root:22]  crée admin (sudo + mot de passe) et deploy (rien)
 │   │             admin.pub → admin, deploy.pub → deploy
 │   ├─ [admin:22] UFW autorise 22222, sshd écoute sur 22 ET 22222
 │   │             empreinte du serveur enregistrée pour [IP]:22222
 │   └─ [admin:22222] preuve que ça marche, PUIS : ferme 22,
 │                    verrouille root, retire la clé du compte provider
 └─ site.yml
     ├─ hardening.yml  UFW, fail2ban, sysctl, auditd, AppArmor,
     │                 mises à jour auto, journald, Docker
     └─ traefik.yml    Traefik + nginx + vérification 401 / 200 "coucou"
```

Root n'est jamais coupé avant qu'on ait prouvé qu'admin se connecte et passe root. Même chose pour le port 22 : on ne le ferme qu'après avoir vérifié que 22222 répond. Tu ne peux donc pas te retrouver enfermé dehors.

## Les comptes

| Compte | Clé SSH | Privilèges | Rôle |
|---|---|---|---|
| `root` | aucune (celle du bootstrap est retirée) | total, mais SSH refusé et mot de passe verrouillé | secours via le mode rescue du provider |
| `admin` | `~/.ssh/ansible-linode/traeffik-forward-proxy/admin` | sudo **avec mot de passe** | Ansible, administration, `sudo docker` |
| `deploy` | `…/deploy` | aucun : ni sudo, ni groupe docker | pousse du contenu dans `/srv/apps` |

- **Pourquoi deux comptes.** `deploy` est le compte qu'une CI ou un collègue peut utiliser pour livrer des fichiers. S'il est compromis, l'attaquant peut modifier la page, mais pas le système. Le groupe docker est refusé exprès, parce que l'accès au socket Docker équivaut à être root.
- **Pourquoi un mot de passe sudo pour admin.** Avec la clé seule, quelqu'un qui vole la clé devient root. Avec le mot de passe en plus, il lui faut la clé **et** le mot de passe. C'est aussi ce mot de passe qui permet de se connecter via la console web du provider. Ansible le lit dans le vault, donc l'automatisation n'est pas affectée.
- **Pas de mot de passe pour deploy.** L'authentification SSH par mot de passe est désactivée et deploy n'a pas sudo : un mot de passe ne protégerait rien.

La segmentation se teste directement : `deploy` modifie la page sans aucun privilège.

```bash
scp -P 22222 -i ~/.ssh/ansible-linode/traeffik-forward-proxy/deploy index.html \
    deploy@203.0.113.25:/srv/apps/coucou/index.html
# ou : scp index.html traefik-test-deploy:/srv/apps/coucou/
```

## HTTPS : Traefik remplace certbot

Traefik contient un client ACME. Il obtient le certificat Let's Encrypt, le stocke dans `/opt/traefik/acme/acme.json` et le renouvelle tout seul. L'application derrière lui parle en **HTTP simple** sur le réseau Docker interne : il n'y a aucun fichier cert ou clé à placer dans l'app. Certbot ne sert que si l'application gère TLS elle-même, sans reverse proxy.

**sslip.io** est un DNS public qui renvoie l'IP contenue dans le nom : `203-0-113-25.sslip.io` résout vers `203.0.113.25`. C'est ce qui permet d'avoir un vrai certificat sans acheter de domaine. C'est la valeur par défaut, utilisée quand `traefik_domain` est vide. Comme ce domaine est partagé par tout le monde, Let's Encrypt peut parfois refuser l'émission parce que le quota est atteint.

**Passer à ton domaine Cloudflare :**

1. Crée un enregistrement `A coucou.tondomaine.fr → IP` en mode **DNS only (nuage gris)**. Le proxy orange bloque le challenge HTTP-01.
2. Relance avec `-e traefik_domain=coucou.tondomaine.fr`, ou fixe la valeur dans `group_vars/all/main.yml`.

Pour des tests répétés, `traefik_acme_staging: true` évite les quotas. Le certificat obtenu n'est alors pas reconnu par les navigateurs.

## Choix de sécurité de la stack

- Le socket Docker n'est **pas monté** dans Traefik : les routes viennent d'un fichier (`/opt/traefik/dynamic.yml`).
- Traefik tourne sous l'utilisateur 65534 (non-root), en `read_only`, avec `cap_drop: ALL` et `no-new-privileges`. Il écoute sur 8080/8443, que Docker publie en 80/443.
- nginx tourne sous l'uid de deploy, en `read_only`. Il ne publie aucun port et monte `/srv/apps/coucou` en lecture seule.
- Le mot de passe BasicAuth est stocké en bcrypt dans `/opt/traefik/users.htpasswd` (0640).
- Le HTTP est redirigé vers HTTPS en 301. Les réponses portent HSTS, `nosniff` et `X-Frame-Options: DENY`. TLS 1.2 minimum.
- ⚠ Les ports publiés par Docker contournent UFW. Ici ce n'est pas un problème : seuls 80 et 443 sont publiés, et ils sont ouverts de toute façon. Si un autre conteneur doit être joignable, fais-le passer par Traefik plutôt que de publier son port.

## Hardening v2 (issu de l'audit Lynis et ssh-audit)

| Ajout | Détail |
|---|---|
| Crypto SSH moderne | Seulement ed25519/rsa-sha2 et curve25519. Échange de clés post-quantique `sntrup761` en priorité. Plus de courbes NIST, de SHA-1 ni de MAC non-ETM. `LogLevel VERBOSE` enregistre l'empreinte de la clé utilisée à chaque connexion. |
| sysctl | `protected_fifos`, `suid_dumpable=0`, `sysrq=0`, BPF durci, `log_martians`, pas d'envoi de redirects. Volontairement **non appliqués** : `ip_forward=0` et `modules_disabled=1`, qui casseraient Docker. |
| Modules noyau | dccp, sctp, rds et tipc désactivés |
| Divers | Pas de core dumps, `UMASK 027`, `/etc/sudoers.d` en 0750, bannière légale |
| auditd | Règles sur les comptes, sudo, SSH, les clés, le firewall, Docker, systemd, `/opt/traefik`, et **chaque commande lancée en root par un humain**. Recherche : `sudo ausearch -k root_commands -i` |
| Anti brute-force BasicAuth | Middleware Traefik `rateLimit` (20 req/s par IP, rafale 40, au-delà 429). fail2ban lit `/opt/traefik/logs/access.log` et bannit après 5 réponses 401 en 10 min. |

Le bannissement se fait dans la chaîne iptables `DOCKER-USER`, pas dans UFW : les ports publiés par Docker contournent UFW, un ban UFW n'aurait donc aucun effet sur 80 et 443.

```bash
sudo fail2ban-client status traefik-auth     # IP bannies
sudo fail2ban-client set traefik-auth unbanip <IP>
```

Chaque exécution de `traefik.yml` fait une requête anonyme (401) pour vérifier la page. Relancer le playbook plus de 5 fois en 10 minutes peut donc bannir ta propre IP pendant 1 h, sauf si elle figure dans `ssh_allowed_cidrs`.

## Cas particuliers selon le provider

- **Hetzner, serveur créé sans clé.** Le mot de passe root reçu par mail doit être changé à la première connexion, ce qui fait échouer `ssh-copy-id`. Connecte-toi une fois avec `ssh root@IP`, change le mot de passe, puis relance `./provision.sh`.
- **AWS.** Il n'y a pas de mot de passe : le provider injecte obligatoirement une clé pour `ubuntu`. Utilise `-u ubuntu` et ajoute `admin.pub` à la main (ou utilise ta keypair AWS pour `ssh-copy-id`).
- **VPS recréé avec la même IP.** L'empreinte SSH change. Supprime les anciennes entrées :
  `ssh-keygen -R 203.0.113.25 && ssh-keygen -R '[203.0.113.25]:22222'`

## Variables utiles (`group_vars/all/main.yml`)

| Variable | Défaut | Rôle |
|---|---|---|
| `ssh_port` | `22222` | port SSH final |
| `ssh_allowed_cidrs` | `[]` | restreint SSH (sinon : rate-limit + fail2ban) |
| `bootstrap_user` | `root` | compte initial du provider |
| `ssh_key_dir` | `~/.ssh/ansible-linode/traeffik-forward-proxy` | dossier des clés admin/deploy |
| `traefik_domain` | `""` | vide = sslip.io |
| `traefik_acme_staging` | `false` | CA de test Let's Encrypt |
| `traefik_image` / `coucou_image` | versions épinglées | à mettre à jour volontairement |

## Validation locale

```bash
bash -n provision.sh
for p in bootstrap.yml hardening.yml traefik.yml site.yml; do
  ansible-playbook --syntax-check "$p"
done
```

## Contrôles après provisioning

```bash
ssh root@IP                                    # refusé
nc -vz -w 5 IP 22                              # timeout : UFW jette le paquet sans répondre
ssh traefik-test-admin 'sudo -k; sudo -n true' # refusé : le mot de passe est exigé
ssh -t traefik-test-admin 'sudo docker ps'     # ok après le mot de passe
ssh traefik-test-deploy 'docker ps; sudo -n true' # les deux refusés
curl -I http://203-0-113-25.sslip.io           # 301 → https
curl -I https://203-0-113-25.sslip.io          # 401
curl -u admin:*** https://203-0-113-25.sslip.io # coucou
```
