# Héberger et déployer une application

Une application est une **donnée** de l'inventaire, pas du code : une entrée de la liste `apps`, plus un fichier compose dans `apps/<nom>/`. Traefik est toujours l'unique point d'entrée ; l'application ne publie aucun port.

## 1. Déclarer l'application

Dans `inventories/<env>/group_vars/vps/main.yml` (par défaut la liste est vide : serveur prêt, sans application) :

```yaml
apps:
  - name: monapp                      # [a-z][a-z0-9-], sert de nom de projet compose
    domains: [app.exemple.fr]         # enregistrement A vers le serveur, avant le run
    compose_template: apps/monapp/compose.yml.j2
    web:
      service: web                    # service branché sur Traefik
      port: 8000                      # port d'écoute DANS le conteneur
      healthcheck_path: /healthz
      healthcheck_status: 200
    auth: none                        # ou basic : BasicAuth de Traefik devant l'app
    image_repos: [ghcr.io/moi/monapp] # dépôts que deploy a le droit de demander
    initial_image: ghcr.io/moi/monapp@sha256:...   # image avant le premier déploiement
    migrate_command: [python, manage.py, migrate]  # optionnel
    postgres:
      enabled: true                   # dump quotidien par le rôle backup
      service: db
      image: postgres:17-alpine
      user: monapp                    # défaut : le nom de l'application
      database: monapp
    allowed_cap_add:
      db: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
```

Les valeurs par défaut sont dans `roles/apps/defaults/main.yml`. Les secrets vont dans le vault de l'environnement, et finissent dans `/opt/apps/<app>/.env` (root, 0600) :

```yaml
app_secrets:
  monapp:
    POSTGRES_USER: monapp
    POSTGRES_DB: monapp
    POSTGRES_PASSWORD: "..."
    DATABASE_URL: "postgresql://monapp:...@db:5432/monapp"
```

## 2. Écrire le compose

Partir de [`apps/demo/compose.yml.j2`](../apps/demo/compose.yml.j2) : service web, PostgreSQL sur un réseau interne, ancre `x-hardening` commune. Règles, vérifiées par Ansible avant chaque déploiement (la liste exacte est dans [HARDENING.md §11.1](HARDENING.md#111-lint-du-fichier-compose)) :

- chaque service : `cap_drop: [ALL]`, et les capacités ajoutées déclarées dans `allowed_cap_add` ;
- pas de `ports`, `privileged`, `network_mode: host`, `devices`, `container_name` ;
- montages de l'hôte seulement sous `/opt/apps/<app>` (chemins relatifs) ou `/srv/apps/<app>` ; volumes nommés libres ;
- ne pas déclarer le réseau `edge` : Ansible y attache le service web lui-même (`compose.edge.yml`), sous l'alias `<app>-<service>` ;
- l'image du service web est `${APP_IMAGE}`, lue dans `release.env`, que le worker de déploiement réécrit ;
- un `healthcheck` sur le service web : le déploiement attend qu'il passe (`docker compose up --wait`).

Le template est rendu par Jinja : `{{ app.web.port }}`, `{{ deploy_uid }}` et les variables de l'inventaire y sont disponibles. Les `${...}` sont laissés à compose.

Appliquer :

```bash
ansible-playbook site.yml -i inventories/prod/hosts.ini -e ansible_host=<IP> --ask-vault-pass --tags apps
```

## 3. Déployer une nouvelle version

### Principe

```
 deploy (sans privilège)                    root
 ───────────────────────                    ────────────────────────────────────────
 deploy-request monapp <image@sha256>
   └─ écrit inbox/monapp.request ──────►  app-deploy@monapp.path (systemd) le voit
                                           └─ app-deploy monapp :
                                               1. lit la demande (O_NOFOLLOW, propriétaire,
                                                  taille), la supprime
                                               2. revalide : dépôt autorisé, digest obligatoire
                                               3. docker pull
                                               4. migrate_command avec la nouvelle image
                                               5. compose up --wait + contrôle HTTPS via Traefik
                                               6. échec → image précédente remise en service
                                               7. status/monapp.json + alerte Discord
   ◄── lit status/monapp.json ────────────
   code de sortie 0 = succès
```

Pourquoi ce détour plutôt qu'un accès direct :

| Option | Problème |
|---|---|
| deploy dans le groupe `docker` | équivaut à root (`docker run -v /:/host`) |
| `sudo` pour deploy sur un script | casse la règle « deploy n'a aucun sudo » ; les arguments passés à un script root sont une surface d'injection |
| Docker rootless pour deploy | second démon, réseau séparé de Traefik, et deploy déciderait lui-même des montages |
| **demande / exécution (retenu)** | deploy choisit **quelle** image, parmi les dépôts autorisés ; root décide **comment** elle tourne |

Le digest `sha256` est obligatoire : un tag (`:latest`, `:v2`) peut être déplacé sur le registry après coup, un digest désigne une image précise et immuable.

### À la main

```bash
ssh <prefix>-deploy deploy-request monapp ghcr.io/moi/monapp@sha256:4f1c...
ssh <prefix>-deploy deploy-request status monapp
```

### Depuis la CI

1. Générer une clé dédiée : `ssh-keygen -t ed25519 -N '' -C ci-monapp -f ci-monapp`.
2. Ajouter la clé **publique** à l'inventaire :
   ```yaml
   deploy_ci_public_keys:
     - "ssh-ed25519 AAAA... ci-monapp"
   ```
   Ansible l'installe avec `restrict,command="/usr/local/bin/deploy-request --ssh"` : cette clé ne peut **que** demander un déploiement ou lire un statut ; pas de shell, pas de tunnel. Le même run gère la clé de deploy : ne jamais ajouter de clé à `authorized_keys` à la main, elle serait effacée au run suivant.
3. Mettre la clé **privée**, l'adresse, le port et l'empreinte du serveur (`ssh-keyscan -p 22222 <IP>`) dans les secrets de la CI.
4. Exemple GitHub Actions : [`examples/github-actions-deploy.yml`](../examples/github-actions-deploy.yml).

Registry privé : un jeton **en lecture seule** dans le vault :

```yaml
registry_auths:
  - { registry: ghcr.io, username: moi, password: "<jeton read:packages>" }
```

### Résultats possibles

| `state` | Signification | Service en place |
|---|---|---|
| `success` | nouvelle image saine | nouvelle image |
| `rolled_back` | nouvelle image en échec, précédente restaurée | ancienne image |
| `failed` | échec avant bascule (pull, migration) | ancienne image |
| `rollback_failed` | la précédente ne repart pas non plus | **à traiter** |
| `refused` | demande invalide, rien n'a été touché | inchangé |

**Limite.** Une migration de base de données n'est pas annulée par le rollback. Les migrations doivent rester compatibles avec la version précédente du code (ajouter une colonne, puis supprimer l'ancienne dans une version suivante), sinon le rollback remet en service un code qui ne comprend plus le schéma.

## 4. Contenu statique

Pour une application sans image à déployer (`image_repos` vide), deploy publie directement les fichiers dans `/srv/apps/<app>/`. Exemple complet : `apps/coucou` (nginx non-root, BasicAuth), à déclarer ainsi :

```yaml
apps:
  - name: coucou
    domains: ["{{ traefik_effective_domain }}"]
    compose_template: apps/coucou/compose.yml.j2
    auth: basic
    seed_files:
      - { src: apps/coucou/index.html, dest: public/index.html }
```

Publication :

```bash
rsync -av --delete public/ <prefix>-deploy:/srv/apps/coucou/public/
```

## 5. Retirer une application

Retirer l'entrée de `apps` n'arrête rien (Ansible ne supprime pas ce qu'il ne connaît plus). Sur le serveur :

```bash
sudo docker compose -p monapp --project-directory /opt/apps/monapp -f compose.yml -f compose.edge.yml down
sudo systemctl disable --now app-deploy@monapp.path
sudo rm /opt/traefik/dynamic/app-monapp.yml /etc/app-deploy/monapp.json
# données : volume monapp_pgdata, /srv/apps/monapp, /opt/apps/monapp (après sauvegarde)
```
