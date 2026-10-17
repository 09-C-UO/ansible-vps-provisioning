# Raccourcis du dépôt. `just` seul liste les recettes.
# <env> = un dossier de inventories/ (test, prod, lab).

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list --unsorted

# Serveur neuf, une seule fois : just provision prod 203.0.113.25 -u ubuntu
provision env ip *args:
    ./provision.sh -i inventories/{{env}} {{args}} {{ip}}

# Réapplique toute la configuration (idempotent) : just site prod 203.0.113.25
site env ip *args:
    ansible-playbook site.yml -i inventories/{{env}}/hosts.ini -e ansible_host={{ip}} --ask-vault-pass {{args}}

# Montre ce qui changerait, sans rien modifier
diff env ip *args:
    ansible-playbook site.yml -i inventories/{{env}}/hosts.ini -e ansible_host={{ip}} --ask-vault-pass --check --diff {{args}}

# Une partie seulement : just tags prod 203.0.113.25 apps,backup
tags env ip tags *args:
    ansible-playbook site.yml -i inventories/{{env}}/hosts.ini -e ansible_host={{ip}} --ask-vault-pass --tags {{tags}} {{args}}

# Accepte l'état actuel comme base AIDE, après lecture du dernier rapport
aide-accept env ip:
    ansible-playbook site.yml -i inventories/{{env}}/hosts.ini -e ansible_host={{ip}} --ask-vault-pass --tags integrity -e aide_accept=true

# Crée le vault d'un environnement (modèle : secrets.example.yml)
vault-create env:
    ansible-vault create inventories/{{env}}/group_vars/vps/secrets.vault.yml

# Modifie le vault d'un environnement
vault-edit env:
    ansible-vault edit inventories/{{env}}/group_vars/vps/secrets.vault.yml

# Déploie une image : just deploy app-prod monapp ghcr.io/moi/monapp@sha256:...
deploy prefix app image:
    ssh {{prefix}}-deploy deploy-request {{app}} {{image}}

# Résultat du dernier déploiement : just status app-prod monapp
status prefix app:
    ssh {{prefix}}-deploy deploy-request status {{app}}

# Contrôles locaux rapides (sans serveur)
check:
    python3 tests/test_compose_lint.py
    ansible-playbook --syntax-check -i inventories/test/hosts.ini bootstrap.yml site.yml
    for f in provision.sh tests/lab/*.sh scripts/*.sh roles/traefik/files/edge-firewall; do bash -n "$f"; done
    rm -rf roles/apps/filter_plugins/__pycache__

# Labo Docker complet : conteneur neuf, provision, idempotence, tests
lab:
    tests/lab/run.sh all

# Tests seuls, sur le labo en place
lab-test:
    tests/lab/run.sh test

# Supprime le conteneur du labo
lab-down:
    tests/lab/run.sh down

# Infrastructure Scaleway (OpenTofu). Rend le nom du tfvars d'un environnement
# (infra/<env>.tfvars, sinon infra/prod.tfvars).
scw_env env:
    @f="{{env}}.tfvars"; [ -f "infra/$f" ] || f="prod.tfvars"; echo "$f"

# Crée/met à jour le VPS et son pare-feu : just infra-apply prod
infra-apply env:
    #!/usr/bin/env bash
    set -euo pipefail
    tofu -chdir=infra apply -var-file="$(just scw_env {{env}})"

# Montre ce qui changerait côté infra : just infra-plan prod
infra-plan env:
    #!/usr/bin/env bash
    set -euo pipefail
    tofu -chdir=infra plan -var-file="$(just scw_env {{env}})"

# Crée l'infra puis provisionne avec Ansible : just infra-provision prod
infra-provision env *args:
    ./infra/provision.sh {{env}} {{args}}

# Ferme le port 22 du pare-feu après le bootstrap : just close-ssh-22 prod
close-ssh-22 env:
    #!/usr/bin/env bash
    set -euo pipefail
    tfvars="$(just scw_env {{env}})"
    tofu -chdir=infra apply -var-file="$tfvars" -var ssh_22_open=false

# Affiche les sorties (IP, identifiants restic pour le vault)
infra-outputs:
    tofu -chdir=infra output
