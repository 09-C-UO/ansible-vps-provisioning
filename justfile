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
    for f in provision.sh tests/lab/*.sh scripts/*.sh files/edge-firewall; do bash -n "$f"; done
    rm -rf filter_plugins/__pycache__

# Labo Docker complet : conteneur neuf, provision, idempotence, tests
lab:
    tests/lab/run.sh all

# Tests seuls, sur le labo en place
lab-test:
    tests/lab/run.sh test

# Supprime le conteneur du labo
lab-down:
    tests/lab/run.sh down
