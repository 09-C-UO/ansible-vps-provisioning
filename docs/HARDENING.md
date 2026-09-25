# Mesures de durcissement

Chaque mesure est décrite avec le même gabarit :

- **Ce que ça fait** : l'effet concret sur le serveur.
- **Contre quoi** : le scénario d'attaque ou l'incident visé.
- **Vérifier** : une commande dont le résultat prouve que la mesure est en place.
- **Écarté** : ce qui a été volontairement laissé de côté, et pourquoi.

Les commandes « Vérifier » supposent les alias créés par le bootstrap (`<prefix>-admin`, `<prefix>-deploy`) et se lancent depuis le poste d'administration, sauf mention « sur le serveur » (`ssh <prefix>-admin` d'abord). Le schéma d'ensemble des couches est dans [ARCHITECTURE.md](ARCHITECTURE.md).

Sommaire : [Comptes](#1-comptes-et-privilèges) · [SSH](#2-ssh) · [Pare-feu](#3-pare-feu) · [fail2ban](#4-fail2ban) · [Noyau](#5-noyau-sysctl-et-modules) · [Système](#6-système) · [Traces](#7-traces-auditd-et-journald) · [Docker](#8-docker) · [Traefik](#9-traefik) · [Bordure](#10-bordure-cloudflare-et-certificats) · [Applications](#11-applications-et-déploiement) · [Intégrité](#12-intégrité-aide-et-rkhunter) · [Sauvegardes](#13-sauvegardes) · [Surveillance](#14-surveillance-et-alertes) · [Secrets](#15-secrets)

---

## 1. Comptes et privilèges

### 1.1 Trois comptes, trois rôles

**Ce que ça fait.** `root` est verrouillé (mot de passe bloqué, SSH refusé) et ne sert plus qu'à la console du provider. `admin` administre, avec sudo **sur mot de passe**. `deploy` n'a aucun privilège : ni sudo, ni groupe `docker`. Chaque compte a sa propre clé SSH.

**Contre quoi.** Le vol d'une clé SSH. Avec la clé d'`admin` seule, l'attaquant obtient une session mais pas root : il lui manque le mot de passe sudo, qui n'est stocké que dans le vault Ansible. Avec la clé de `deploy` (celle qui risque le plus de fuiter, puisqu'elle sert à publier), il ne peut que publier du contenu et demander le déploiement d'une image déjà autorisée.

**Vérifier.**
```bash
ssh root@<IP>                                      # Permission denied
ssh <prefix>-admin 'sudo -k; sudo -n true'         # "a password is required"
ssh <prefix>-deploy 'id; sudo -n true; docker ps'  # groupes: deploy seul ; les deux refusés
ssh <prefix>-admin 'sudo passwd -S root'           # 2e champ : L (locked)
```

**Écarté.** `NOPASSWD` pour admin, plus pratique pour Ansible, aurait fait de la clé SSH le seul secret entre Internet et root. Ansible lit le mot de passe dans le vault (`ansible_become_password`), l'automatisation n'y perd donc rien. Une règle `NOPASSWD` laissée par une ancienne version est supprimée à chaque run.

### 1.2 Bootstrap sans lock-out

**Ce que ça fait.** Le mot de passe root du provider ne sert qu'une fois (`ssh-copy-id`). Ensuite, chaque fermeture n'a lieu qu'après la preuve que la nouvelle porte fonctionne : admin est créé et testé (connexion **et** sudo) avant que sshd n'écoute sur le nouveau port ; sshd écoute sur 22 **et** 22222 ; une nouvelle connexion est établie sur 22222 ; seulement alors le 22 est fermé, root verrouillé et la clé de bootstrap retirée.

**Contre quoi.** L'erreur d'administration la plus coûteuse sur un VPS : se retrouver dehors, sans autre recours que la console web du provider.

**Vérifier.**
```bash
nc -vz -w 5 <IP> 22        # timeout (port fermé, DROP)
nc -vz -w 5 <IP> 22222     # succeeded
```

**Écarté.** Changer le port en une seule étape : si la nouvelle configuration est refusée (pare-feu cloud, `ssh.socket` sur Ubuntu 24.04 qui ignore `Port` tant qu'il n'est pas régénéré), la session en cours survit mais aucune nouvelle ne s'ouvre.

---

## 2. SSH

### 2.1 Authentification

**Ce que ça fait.** Clés uniquement (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`), `PermitRootLogin no`, `AllowUsers admin deploy`, 3 essais par connexion (`MaxAuthTries 3`), 30 s pour s'authentifier (`LoginGraceTime 30`), sessions inactives coupées après 10 min (`ClientAliveInterval 300` × `ClientAliveCountMax 2`). La configuration est un drop-in `sshd_config.d/00-ansible-hardening.conf` : chargé en premier, il l'emporte sur les valeurs par défaut de la distribution et des images cloud (sshd garde la **première** valeur lue).

**Contre quoi.** Le brute force de mots de passe (impossible sans mot de passe), un compte système ou applicatif créé plus tard avec un shell (refusé par `AllowUsers`), les connexions à moitié ouvertes qui occupent des slots.

**Vérifier (sur le serveur).**
```bash
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries|logingracetime) '
```

**Écarté.** Le changement de port n'est **pas** une mesure de sécurité : un scan le trouve en quelques secondes. Il réduit seulement le bruit dans les logs (les robots visent le 22), ce qui rend les vraies tentatives plus visibles.

### 2.2 Cryptographie

**Ce que ça fait.** Seuls des algorithmes modernes sont proposés : échange de clés `sntrup761x25519` (hybride post-quantique), `curve25519`, DH 4096/8192 bits ; chiffrement ChaCha20-Poly1305 et AES-GCM/CTR ; MAC en mode *encrypt-then-MAC* ; clés hôte Ed25519 et RSA signées en SHA-2. Les clés FIDO2 `sk-ssh-ed25519` sont déjà acceptées (voir [OPTIONS.md](OPTIONS.md)).

**Contre quoi.** Les algorithmes affaiblis (SHA-1, courbes NIST dont l'origine des paramètres est contestée, MAC *encrypt-and-MAC* sensibles aux attaques de type Terrapin), et le « stocker maintenant, déchiffrer plus tard » pour sntrup761.

**Vérifier.**
```bash
uvx ssh-audit -p 22222 <IP>     # attendu : aucun [fail], aucun [warn]
```

**Écarté.** Les clés hôte ECDSA et les algorithmes `ssh-rsa` (SHA-1). La clé hôte RSA est gardée pour les clients anciens, mais uniquement avec des signatures SHA-2.

### 2.3 Tunnels et redirections

**Ce que ça fait.** Redirection d'agent (`AllowAgentForwarding no`), X11 et tunnels `tun` (`PermitTunnel no`) refusés pour tous. Redirection TCP refusée pour `deploy` (`Match User deploy` → `AllowTcpForwarding no`). La clé CI de deploy porte en plus l'option `restrict`, qui coupe tout (pty, redirections, agent) et force la commande `deploy-request`.

**Contre quoi.** Un root malveillant sur le serveur peut utiliser l'agent SSH transféré par un administrateur pour se connecter **ailleurs** avec ses clés, d'où le refus de l'agent. Une clé `deploy` volée ne doit pas servir de rebond vers les services internes (Postgres, API Docker d'un autre hôte, réseau du provider).

**Vérifier.**
```bash
ssh -N -L 15432:127.0.0.1:5432 <prefix>-deploy   # "administratively prohibited"
```

**Écarté.** `AllowTcpForwarding no` pour admin. Admin s'en sert légitimement (`ssh -L 5432:...` pour atteindre une base depuis son poste), et un utilisateur qui a un shell peut de toute façon relayer du trafic avec `socat` ou `nc` : l'interdiction gênerait l'usage sans arrêter un admin compromis. Le gain de sécurité réel porte sur deploy, dont le shell n'est pas censé servir à ça.

### 2.4 Journalisation

**Ce que ça fait.** `LogLevel VERBOSE` enregistre l'empreinte de la clé utilisée à chaque connexion.

**Contre quoi.** Sans elle, on sait qu'« admin » s'est connecté, pas **avec quelle clé**. Si plusieurs clés sont autorisées (clé principale et clé de secours), c'est ce qui permet de savoir laquelle a fuité.

**Vérifier (sur le serveur).** `sudo journalctl -u ssh -g 'Accepted publickey' -n 5`

---

## 3. Pare-feu

### 3.1 UFW (chaîne INPUT)

**Ce que ça fait.** Entrées refusées par défaut, en **DROP** silencieux (le paquet disparaît, sans réponse). Sont ouverts : le port SSH en mode `limit`, 80 et 443. Sorties autorisées. IPv6 géré aussi. Option `-c <CIDR>` de `provision.sh` : SSH limité à un réseau.

**Contre quoi.** L'exposition accidentelle d'un service (une base de données qui écoute sur `0.0.0.0` après une mise à jour, un outil de debug). Le DROP ralentit les scans : l'outil doit attendre un timeout au lieu de recevoir un refus immédiat.

**Vérifier.**
```bash
ssh <prefix>-admin 'sudo ufw status verbose'
```

**Écarté / piège connu.** `limit` refuse (REJECT, donc « Connection refused ») une IP après 6 connexions en 30 s. Ansible ouvre beaucoup de connexions : c'est pourquoi `ControlPersist` (réutilisation de connexion, par défaut dans Ansible) est important, et pourquoi un « Connection refused » soudain en plein run vient souvent de là, pas de sshd. Le filtrage **sortant** (egress) n'est pas appliqué : il casserait apt, Let's Encrypt, les pulls Docker et les webhooks, et demanderait une liste d'autorisations à tenir à jour. C'est une amélioration possible, pas une valeur par défaut raisonnable.

### 3.2 DOCKER-USER : le trou dans UFW

**Ce que ça fait.** Les ports publiés par Docker (80 et 443 de Traefik) ne passent **pas** par la chaîne INPUT d'UFW : Docker les redirige (DNAT) vers le conteneur, et le paquet traverse la chaîne FORWARD. Docker garde une chaîne `DOCKER-USER` devant ses propres règles : c'est là que ce dépôt place les bans fail2ban de Traefik et, derrière Cloudflare, la restriction aux IP de Cloudflare.

**Contre quoi.** L'illusion de sécurité la plus répandue avec Docker : `ufw deny 443` n'a **aucun** effet sur un port publié par un conteneur.

**Vérifier (sur le serveur).**
```bash
sudo iptables -L DOCKER-USER -n -v
```

### 3.3 Firewall du provider

**Ce que ça fait.** Optionnel, en amont de la VM (Linode Cloud Firewall, OVH Edge Network Firewall, Hetzner Firewall...). À configurer dans l'interface du provider : 22222 (et 22 pendant le bootstrap), 80, 443.

**Contre quoi.** Il filtre avant que le trafic n'atteigne la VM, donc même si UFW est mal configuré ou désactivé par erreur. Il ne remplace pas UFW : il ne voit pas les réseaux Docker internes.

---

## 4. fail2ban

### 4.1 Jail sshd

**Ce que ça fait.** 5 échecs en 10 minutes → ban d'une heure via UFW, doublé à chaque récidive (`bantime.increment`). Lit le journal systemd directement.

**Contre quoi.** Le brute force et le bruit des robots. Avec des clés seules, le brute force n'aboutit pas ; fail2ban réduit surtout la charge et le volume de logs.

**Vérifier.** `ssh <prefix>-admin 'sudo fail2ban-client status sshd'`

### 4.2 Jail traefik-auth

**Ce que ça fait.** Compte les réponses 401 (BasicAuth refusée) dans l'access log de Traefik ; 5 en 10 minutes → ban dans `DOCKER-USER` (ou via l'API Cloudflare derrière Cloudflare, voir §10). Le filtre écrit `\[\]` là où se trouvait la date, parce que fail2ban **retire la date de la ligne avant d'appliquer la regex**. Un drop-in systemd démarre fail2ban après Docker, sans quoi la chaîne `DOCKER-USER` n'existe pas encore au démarrage.

**Contre quoi.** Le brute force du mot de passe BasicAuth, que le rateLimit de Traefik ne fait que ralentir.

**Vérifier (sur le serveur).**
```bash
sudo fail2ban-client status traefik-auth
sudo fail2ban-regex /opt/traefik/logs/access.log /etc/fail2ban/filter.d/traefik-auth.conf
```

**Piège connu.** Chaque exécution de `site.yml` provoque un 401 (vérification qu'un visiteur anonyme est bien refusé), compté par fail2ban : 5 runs en 10 minutes depuis la même IP bannissent le poste d'administration pour le HTTP (pas pour SSH). `sudo fail2ban-client set traefik-auth unbanip <IP>` débloque.

---

## 5. Noyau (sysctl et modules)

Fichier : `/etc/sysctl.d/99-ansible-hardening.conf`. **Vérifier** une valeur : `ssh <prefix>-admin 'sysctl kernel.kptr_restrict net.ipv4.conf.all.rp_filter'`.

### 5.1 Réseau

| Réglage | Effet | Contre quoi |
|---|---|---|
| `accept_redirects=0`, `send_redirects=0` (v4 et v6) | ignore et n'émet pas de redirections ICMP | un voisin sur le même réseau qui détourne le trafic (MITM) |
| `accept_source_route=0` | refuse les paquets qui imposent leur route | contournement de filtrage par routage source |
| `rp_filter=2` (mode *loose*) | rejette les paquets dont l'adresse source n'est joignable par aucune interface | usurpation d'adresse source (spoofing) |
| `log_martians=1` | journalise les paquets aux adresses impossibles | rend le spoofing visible |
| `tcp_syncookies=1` | répond aux SYN sans réserver de mémoire quand la file déborde | SYN flood |
| `icmp_echo_ignore_broadcasts=1`, `icmp_ignore_bogus_error_responses=1` | ignore les pings en broadcast et les erreurs ICMP malformées | amplification (smurf), bruit dans les logs |

**Piège.** UFW applique son propre fichier `/etc/ufw/sysctl.conf` à chaque démarrage et rechargement, **après** les sysctl du système. Ce fichier contient `log_martians=0` : sans correction, le réglage ci-dessus est annulé au premier reboot, en silence. Le playbook aligne donc aussi ce fichier ; c'est le test d'idempotence du labo (second run avec `changed=1`) qui l'a révélé.

**Écarté.** `rp_filter=1` (strict) : avec les ponts Docker, le chemin retour n'est pas toujours celui d'arrivée, et le mode strict jette du trafic légitime. `net.ipv4.conf.all.forwarding=0`, recommandé par Lynis (KRNL-6000) : **Docker a besoin du forwarding** pour faire circuler le trafic entre l'interface publique et les conteneurs. Le désactiver coupe tous les sites.

### 5.2 Fuites d'information et exploitation

| Réglage | Effet | Contre quoi |
|---|---|---|
| `kernel.kptr_restrict=2` | masque les adresses du noyau (`/proc/kallsyms`) | contournement de KASLR par un exploit local |
| `kernel.dmesg_restrict=1` | `dmesg` réservé à root | fuite d'adresses et d'informations matérielles |
| `kernel.randomize_va_space=2` | ASLR complète | exploits qui supposent des adresses fixes |
| `kernel.yama.ptrace_scope=1` | un processus ne peut tracer que ses descendants | lecture de la mémoire d'un autre processus du même utilisateur (clés, mots de passe) |
| `kernel.unprivileged_bpf_disabled=1`, `net.core.bpf_jit_harden=2` | eBPF réservé à root, JIT durci | une famille entière d'élévations de privilèges locales passées par eBPF |
| `dev.tty.ldisc_autoload=0` | pas de chargement automatique de disciplines de ligne | CVE exploitant des modules tty rarement utilisés |
| `kernel.sysrq=0` | touches magiques SysRq désactivées | reboot ou dump provoqué depuis la console |
| `fs.suid_dumpable=0`, `kernel.core_uses_pid=1` | pas de core dump pour les programmes setuid | fuite de secrets d'un programme privilégié via son dump |

**Écarté.** `kernel.modules_disabled=1` : interdit tout chargement de module jusqu'au prochain redémarrage, de façon irréversible. Docker, UFW et WireGuard chargent des modules **pendant** le fonctionnement (netfilter, overlay, bridge) ; le premier `docker compose up` après un changement de réseau échouerait. `kernel.perf_event_paranoid` : Ubuntu utilise déjà 4, plus strict que les 3 recommandés par Lynis ; l'écrire aurait **affaibli** la valeur. `ptrace_scope=2` ou `3` : empêche aussi root de déboguer (`strace` sur un service en production), pour un gain marginal une fois que les comptes sont séparés.

### 5.3 Système de fichiers

`fs.protected_hardlinks=1`, `protected_symlinks=1`, `protected_fifos=2`, `protected_regular=2` : un utilisateur ne peut plus créer de lien dur vers un fichier qui n'est pas à lui, ni piéger un programme privilégié avec un lien symbolique, une FIFO ou un fichier préparé d'avance dans un répertoire partagé comme `/tmp`. C'est la protection noyau contre les attaques par course (TOCTOU) sur les fichiers temporaires. Le worker de déploiement s'appuie aussi dessus (§11.2).

### 5.4 Protocoles réseau rares

**Ce que ça fait.** `dccp`, `sctp`, `rds` et `tipc` ne peuvent plus être chargés (`install <module> /bin/false` dans `/etc/modprobe.d/`).

**Contre quoi.** Ces protocoles, inutiles sur un serveur web, ont eu plusieurs failles noyau exploitables par un utilisateur local, et le noyau les charge automatiquement dès qu'un programme ouvre une socket de ce type.

**Vérifier.** `ssh <prefix>-admin 'sudo modprobe -n -v dccp'` → `install /bin/false`

---

## 6. Système

### 6.1 Mises à jour de sécurité automatiques

**Ce que ça fait.** `unattended-upgrades` installe chaque jour les mises à jour de sécurité ; `needrestart` redémarre les services concernés. Les options dpkg gardent la configuration locale en cas de conflit.

**Contre quoi.** La fenêtre entre la publication d'un correctif et son installation, que les attaquants exploitent en masse.

**Vérifier (sur le serveur).** `systemctl status unattended-upgrades` et `/var/log/unattended-upgrades/unattended-upgrades.log`.

**Écarté.** Le redémarrage automatique (`automatic_reboot: false`) : un correctif du noyau n'est actif qu'après un reboot, mais un reboot non planifié coupe les sites. Chaque run de `hardening.yml` signale `/var/run/reboot-required` ; le reboot se fait à la main, au moment choisi. `automatic_reboot: true` (et `automatic_reboot_time`) le rend automatique pour qui préfère.

### 6.2 Petites mesures

| Mesure | Effet | Vérifier |
|---|---|---|
| Pas de core dump (`limits.d`) | un crash ne vide pas la mémoire (secrets compris) dans un fichier | `ulimit -c` → 0 |
| `UMASK 027` (`login.defs`) | les fichiers créés en session ne sont plus lisibles par « les autres » | `grep ^UMASK /etc/login.defs` |
| `/etc/sudoers.d` en 0750 | le contenu des règles sudo n'est pas lisible par les comptes ordinaires | `stat -c %a /etc/sudoers.d` |
| Bannière `/etc/issue`, `/etc/issue.net` | avertissement légal à la console (base juridique en cas de poursuite) | `cat /etc/issue` |
| AppArmor actif | confine les programmes qui ont un profil (dont les conteneurs Docker) | `sudo aa-status` |
| `systemd-timesyncd` | horloge exacte : logs corrélables, TLS et TOTP fiables | `timedatectl` |

**Écarté.** La bannière n'est pas affichée par SSH (pas de directive `Banner`) : elle apparaît avant l'authentification, donc à n'importe qui, sans rien apporter de plus que le texte de la console.

---

## 7. Traces (auditd et journald)

### 7.1 auditd

**Ce que ça fait.** Enregistre les modifications de : comptes (`passwd`, `shadow`, `group`), règles sudo, configuration SSH et clés autorisées, pare-feu et fail2ban, Docker, cron, unités systemd, `/opt/traefik` ; le chargement de modules noyau ; et **chaque commande exécutée en root par un humain connecté**. Cette dernière règle filtre sur l'`auid` (*audit uid*, ou *login uid*) : l'identité fixée à la connexion, qui **survit à sudo**. Une commande lancée par `admin` via sudo apparaît comme « admin », pas comme « root ».

**Contre quoi.** Un intrus devenu root qui modifie un fichier puis nettoie l'historique du shell. L'enregistrement se fait dans le noyau, au moment de l'appel système, pas dans l'historique.

**Vérifier (sur le serveur).**
```bash
sudo ausearch -k root_commands -i | tail -20   # qui a lancé quoi en root
sudo ausearch -k ssh_keys -i                   # modifications des authorized_keys
sudo auditctl -l | wc -l                       # règles chargées
```

**Écarté.** Les règles immuables (`-e 2`) : elles empêchent de modifier les règles jusqu'au reboot, y compris par Ansible. Journaliser **tous** les `execve` : des milliers d'événements par minute avec Docker, qui noient l'essentiel. Limite connue : seules les règles 64 bits (`arch=b64`) sont posées ; un binaire 32 bits échapperait à `root_commands`.

### 7.2 journald

**Ce que ça fait.** Journal persistant (survit au reboot), compressé, plafonné à 500 Mo et un mois.

**Contre quoi.** La perte des traces au redémarrage (journal en mémoire par défaut sur certaines images), et le disque plein.

**Vérifier.** `ssh <prefix>-admin 'journalctl --list-boots | head'` → plusieurs boots listés.

**Limite à connaître.** `Seal=yes` (scellement *Forward Secure Sealing*) n'a d'effet qu'après `sudo journalctl --setup-keys`, qui produit une clé de vérification à conserver **hors** du serveur. Cette étape n'est pas automatisée (la clé ne doit pas rester sur le serveur) : sans elle, le journal n'est pas scellé. Dans tous les cas, un root peut effacer le journal local ; seule l'externalisation des logs protège contre ça (en discussion : [README.md](README.md)).

---

## 8. Docker

### 8.1 Personne dans le groupe docker

**Ce que ça fait.** Ni `admin` ni `deploy` ne sont dans le groupe `docker` ; chaque run le vérifie et corrige.

**Contre quoi.** L'accès au socket Docker **équivaut à root** : `docker run -v /:/host --privileged ...` donne un shell root sur l'hôte, sans mot de passe et sans trace sudo. Admin passe par `sudo docker`, ce qui garde le mot de passe et la trace auditd.

**Vérifier.** `ssh <prefix>-deploy 'docker ps'` → `permission denied`.

### 8.2 Démon

| Réglage `daemon.json` | Effet | Contre quoi |
|---|---|---|
| `no-new-privileges: true` | aucun processus d'un conteneur ne peut gagner de privilèges (setuid, capacités de fichier) | élévation de privilèges à l'intérieur du conteneur |
| `userland-proxy: false` | les ports publiés passent par iptables, pas par un proxy | un processus en moins par port ; et Traefik voit la **vraie IP** du client au lieu de celle du proxy (indispensable pour fail2ban) |
| `live-restore: true` | les conteneurs continuent de tourner pendant un redémarrage du démon | coupure des sites lors d'une mise à jour de Docker |
| `json-file` 10 Mo × 3 | logs des conteneurs plafonnés | disque plein par une application bavarde |

Pas d'API Docker en TCP. Paquets du dépôt officiel Docker, signés.

**Écarté.** `userns-remap` (root du conteneur mappé sur un utilisateur non privilégié de l'hôte) : casse les droits des volumes existants et plusieurs images, alors que les conteneurs de ce dépôt tournent déjà sans root et sans capacités. Docker *rootless* : second démon par utilisateur, pas de ports sous 1024, réseau plus lent, et il faudrait tout de même faire communiquer Traefik avec. `icc=false` : ne s'applique qu'au réseau `bridge` par défaut, que ce dépôt n'utilise pas (réseaux dédiés par application).

---

## 9. Traefik

**Ce que ça fait.**

- **Pas de socket Docker** : les routes viennent de fichiers (`/opt/traefik/dynamic/`, un par application, écrits par Ansible et relus à chaud). Un Traefik compromis ne peut donc pas piloter Docker, alors que le montage de `docker.sock`, courant dans les tutoriels, donne root sur l'hôte.
- Conteneur **non-root** (uid 65534), système de fichiers en **lecture seule**, **toutes les capacités retirées** ; il écoute sur 8080/8443 à l'intérieur, Docker publie 80/443.
- TLS 1.2 minimum, certificats Let's Encrypt, redirection permanente HTTP → HTTPS.
- En-têtes : HSTS un an, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` (envoyés même sur les 401).
- `rateLimit` : 20 requêtes/s en moyenne par IP, pointes à 40.
- BasicAuth (bcrypt) pour les applications qui la demandent (`auth: basic`).
- Pas de vérification de version ni de statistiques envoyées à l'éditeur.

**Contre quoi.** La prise de contrôle de l'hôte via le proxy, exposé à Internet et donc le composant le plus attaqué ; le déclassement TLS ; le clickjacking et le *MIME sniffing* ; les rafales de requêtes.

**Vérifier.**
```bash
curl -sI https://<domaine>/ | grep -iE 'strict-transport|x-frame|x-content|referrer'
curl -sI http://<domaine>/            # 308 vers https
ssh <prefix>-admin 'sudo docker inspect traefik-traefik-1 --format "{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}"'
```

**Écarté.** HSTS `includeSubDomains` et `preload` : ils engagent **tout** le domaine (tous les sous-domaines, pendant des mois, inscrit dans les navigateurs), ce qui ne se décide pas depuis un seul serveur qui n'héberge qu'un sous-domaine. Une Content-Security-Policy globale : elle dépend de chaque application et doit être posée par l'application elle-même.

---

## 10. Bordure (Cloudflare et certificats)

Variables : `edge_proxy` (`none` | `cloudflare`), `acme_challenge` (`http` | `dns`), `acme_dns_provider`.

### 10.1 Sans proxy (`edge_proxy: none`, par défaut)

Le DNS pointe directement vers le serveur (enregistrement A ; chez Cloudflare, mode « DNS only », nuage gris). Certificat par HTTP-01 sur le port 80.

**Recommandé en plus** : un enregistrement **CAA** `0 issue "letsencrypt.org"` sur le domaine, pour qu'aucune autre autorité ne puisse émettre de certificat pour lui.

### 10.2 Derrière Cloudflare (`edge_proxy: cloudflare`)

**Ce que ça fait.**

1. **80/443 n'acceptent que Cloudflare** : l'unité `edge-firewall` place les plages publiées par Cloudflare (`vars/cloudflare_ips.yml`) dans `DOCKER-USER`. La règle ne vise que les **nouvelles connexions entrantes vers un port publié** (`--ctstate DNAT --ctdir ORIGINAL`) : le trafic sortant des conteneurs et les réponses aux visiteurs ne sont pas touchés. Sans cette restriction, un attaquant qui connaît l'IP du serveur contournerait Cloudflare (WAF, anti-DDoS) en s'y connectant directement.
2. **Vraie IP du visiteur** : Traefik ne fait confiance aux en-têtes `X-Forwarded-*` que s'ils viennent des plages Cloudflare (`forwardedHeaders.trustedIPs`). L'access log passe en JSON pour enregistrer `CF-Connecting-IP`, fixé par Cloudflare. `X-Forwarded-For`, lui, peut contenir des adresses choisies par le visiteur : l'utiliser permettrait à un attaquant de faire bannir l'IP de quelqu'un d'autre.
3. **Bans via l'API Cloudflare** : la jail `traefik-auth` utilise l'action `cloudflare-token`. Un ban dans `DOCKER-USER` bloquerait un nœud Cloudflare, et avec lui tous les visiteurs qui passent par ce nœud.

**À régler côté Cloudflare (non automatisé)** : mode SSL/TLS **Full (strict)**. Les autres modes laissent Cloudflare accepter un certificat invalide, voire parler en HTTP clair au serveur.

**Vérifier (sur le serveur).**
```bash
sudo iptables -L EDGE-ONLY -n | head
sudo iptables -L DOCKER-USER -n -v | grep EDGE-ONLY
```

**Écarté.** *Authenticated Origin Pulls* (certificat client Cloudflare exigé par Traefik) : plus fort que le filtrage par IP (qui accepte n'importe quel client Cloudflare, donc n'importe quel compte Cloudflare configuré vers cette IP), mais demande une configuration TLS client dans Traefik ; c'est l'étape suivante logique. Le filtrage IPv6 : Docker ne publie pas les ports en IPv6 avec la configuration de ce dépôt.

### 10.3 Challenge DNS-01 (`acme_challenge: dns`)

**Ce que ça fait.** Let's Encrypt vérifie un enregistrement TXT créé par Traefik via l'API du DNS (OVH, Cloudflare, ou tout fournisseur supporté par lego). Les identifiants sont dans `/opt/traefik/acme-dns.env` (root, 0600).

**Contre quoi / pourquoi.** Nécessaire quand le port 80 n'est pas joignable par Let's Encrypt, et plus robuste derrière un proxy. **Contrepartie** : ces identifiants peuvent modifier la zone DNS, donc rediriger le domaine. D'où des droits minimaux : pour OVH, une clé limitée à `GET/POST/DELETE /domain/zone/<zone>/*` ; pour Cloudflare, un jeton « Zone › DNS › Edit » sur la seule zone concernée.

---

## 11. Applications et déploiement

Détail complet : [DEPLOYMENT.md](DEPLOYMENT.md).

### 11.1 Lint du fichier compose

**Ce que ça fait.** Avant tout déploiement, Ansible analyse le compose de chaque application (`filter_plugins/app_compose.py`) et refuse : `privileged`, les espaces de noms de l'hôte (`network_mode`/`pid`/`ipc`/`uts`/`userns_mode: host`), les ports publiés, les périphériques, `container_name`, l'absence de `cap_drop: [ALL]`, les capacités ajoutées sans être déclarées dans `allowed_cap_add`, `seccomp`/`apparmor` `unconfined`, le montage du socket Docker, tout montage de l'hôte hors de `/opt/apps/<app>` et `/srv/apps/<app>`, et la déclaration du réseau `edge`.

**Contre quoi.** Le compose est exécuté par root. Une seule ligne recopiée d'un tutoriel (`privileged: true`, `- /var/run/docker.sock:...`) suffit à donner l'hôte à l'application. Le lint rend l'erreur bloquante au lieu de silencieuse.

**Vérifier.** `python3 tests/test_compose_lint.py` (poste d'administration).

### 11.2 Déploiement sans accès Docker

**Ce que ça fait.** deploy **dépose une demande** (application + image désignée par son digest `sha256`) dans `/var/lib/app-deploy/inbox/`. Une unité systemd la détecte et lance le worker root, qui la **revalide** entièrement : dépôt d'image dans la liste autorisée de l'application, digest obligatoire, fichier ouvert sans suivre les liens symboliques (`O_NOFOLLOW`), propriétaire vérifié, taille limitée. Le worker déploie, contrôle la santé à travers Traefik, et **revient à l'image précédente** en cas d'échec.

**Contre quoi.** Donner le groupe `docker` à deploy (= root). Et les attaques classiques contre un programme root qui lit des fichiers déposés par un utilisateur : lien symbolique vers `/etc/shadow` (lecture ou écrasement par root), fichier géant, contenu forgé. La boîte de dépôt appartient à root, le statut est écrit dans un répertoire root, et deploy ne choisit jamais **comment** le conteneur tourne (montages, réseaux, privilèges), seulement **quelle version** d'une image autorisée.

**Vérifier.** `tests/lab/test_deploy.sh` rejoue ces attaques contre le labo.

---

## 12. Intégrité (AIDE et rkhunter)

### 12.1 AIDE

**Ce que ça fait.** AIDE garde une empreinte (hash, droits, propriétaire) de chaque fichier système. Chaque jour, il compare l'état réel à cette base et envoie les différences sur le canal Discord de sécurité. Les chemins qui changent par nature (données Docker, logs, contenu applicatif, certificats) sont exclus pour éviter le bruit.

**Contre quoi.** La persistance d'un intrus : binaire remplacé, clé SSH ajoutée, unité systemd ou tâche cron installée.

**Vérifier (sur le serveur).** `sudo systemctl start aide-check.service; sudo journalctl -u aide-check -n 30`

**Choix délibéré : pas de mise à jour automatique de la base.** Mettre à jour la base après chaque run Ansible ferait disparaître du rapport une modification malveillante faite entre deux runs. Après un changement planifié, on lit le rapport, puis on accepte explicitement : `ansible-playbook site.yml --tags integrity -e aide_accept=true ...`.

**Limite.** Un root peut aussi modifier la base AIDE. Elle est incluse dans les sauvegardes : la comparer à une copie ancienne restaurée depuis restic lève le doute.

### 12.2 rkhunter

**Ce que ça fait.** Scan hebdomadaire des signatures de rootkits connus, des binaires système (hash comparé à la base **dpkg**, donc sans fausse alerte après une mise à jour apt), des options SSH dangereuses. Avertissements → canal sécurité. Aucun téléchargement depuis les miroirs rkhunter.

**Écarté.** Les tests de processus cachés et de fichiers supprimés encore ouverts : Docker et containerd en produisent en permanence, par conception. Un rapport qui crie au loup chaque semaine finit par ne plus être lu.

---

## 13. Sauvegardes

Détail : [BACKUP.md](BACKUP.md).

**Ce que ça fait.** Chaque nuit : dump cohérent de chaque base PostgreSQL (`pg_dump`, sans arrêt), puis snapshot **restic** (chiffré avec une clé qui ne quitte pas le vault, dédupliqué) vers un stockage S3 chez un **autre** fournisseur. Chaque semaine, `restic check` relit 5 % des données. Chaque mois, le dernier dump est **restauré** dans un PostgreSQL jetable, sans réseau, et interrogé.

**Contre quoi.** La panne du disque, la suppression par erreur, la perte du compte chez le provider, et le rançongiciel. Pour ce dernier : versioning ou Object Lock sur le bucket, ou une clé serveur sans droit de suppression (`backup_prune_on_server: false`). Un serveur compromis ne peut alors pas effacer l'historique.

**Vérifier (sur le serveur).** `sudo systemctl list-timers 'backup-*'`, puis `sudo journalctl -u backup-restore-test -n 20`.

---

## 14. Surveillance et alertes

### 14.1 Connexions SSH d'admin

**Ce que ça fait.** Chaque ouverture de session SSH d'un compte listé dans `login_alert_users` (par défaut : admin) envoie « Connexion SSH : admin depuis <IP> » au canal `security`. Au plus une alerte par compte et par adresse toutes les 10 minutes (un run Ansible ouvre plusieurs sessions). Déclenché par `pam_exec` dans `/etc/pam.d/sshd`, en ligne `optional` et en arrière-plan : si le script ou Discord échoue, la connexion n'est ni bloquée ni ralentie.

**Contre quoi.** Une clé admin volée et utilisée : c'est le signal d'intrusion le plus direct. Une alerte qui ne correspond à aucune connexion de sa part appelle une réaction immédiate (révoquer la clé, changer le mot de passe sudo, lire `ausearch -k root_commands`).

**Écarté.** Les connexions de deploy (la CI s'y connecte à chaque déploiement : du bruit), et chaque `sudo` d'admin (Ansible en fait des centaines par run).

**Vérifier.** Se connecter en admin, puis regarder le canal `security`, ou `sudo journalctl -t notify-discord -n 5`.

### 14.2 Métriques du serveur

**Ce que ça fait.** Toutes les 5 minutes : disque et inodes (85 %), mémoire disponible (10 %), charge moyenne sur 5 minutes (2 par CPU). Une alerte au franchissement d'un seuil, une autre au retour à la normale, rien entre les deux. Seuils : `health_*` dans `roles/monitoring/defaults/main.yml`.

**Contre quoi.** Le disque plein (logs, images Docker, sauvegardes locales), qui arrête base de données et journalisation en même temps ; une charge anormale et durable est aussi un symptôme classique de minage de cryptomonnaie après une intrusion.

**Écarté.** La santé des conteneurs et des applications : volontairement hors du périmètre (serveur uniquement).

**Vérifier (sur le serveur).** `sudo /usr/local/sbin/server-health` affiche `ok` ou la liste des dépassements.

### 14.3 Canaux Discord

**Ce que ça fait.** `notify-discord` envoie vers deux canaux : `infra` (métriques, déploiements, sauvegardes) et `security` (connexions admin, AIDE, rkhunter). Toute unité qui échoue (`OnFailure=`) envoie ses dernières lignes de log. Les messages sont aussi écrits dans le journal (`journalctl -t notify-discord`), même quand Discord ne répond pas. Les mentions (`@everyone`) contenues dans un log sont neutralisées.

**Vérifier (sur le serveur).** `sudo /usr/local/sbin/notify-discord infra "test" "message de test"`

---

## 15. Secrets

**Ce que ça fait.** Tous les secrets sont dans un vault Ansible par environnement (`inventories/<env>/group_vars/vps/secrets.vault.yml`), chiffré et exclu de git. Sur le serveur, ils atterrissent dans des fichiers root 0600 (`/opt/apps/<app>/.env`, `/etc/restic/`, `/etc/notify-discord.env`, `/opt/traefik/acme-dns.env`). Les tâches qui les manipulent sont en `no_log`, pour qu'aucun secret n'apparaisse dans la sortie d'Ansible. Le hash du mot de passe d'admin utilise un sel fixe, stocké dans le vault, pour qu'un run qui ne change rien ne réécrive pas `/etc/shadow`.

**Contre quoi.** La fuite par le dépôt git, par les logs de CI, ou par la lecture d'un fichier par un compte non privilégié.

**Vérifier.**
```bash
git check-ignore inventories/prod/group_vars/vps/secrets.vault.yml   # ignoré
ssh <prefix>-deploy 'cat /opt/apps/*/.env'                           # Permission denied
```

À garder **hors** du serveur et hors de ce dépôt : le mot de passe du vault, et le mot de passe restic (sans lui, les sauvegardes sont illisibles, par conception).
