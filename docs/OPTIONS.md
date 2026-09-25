# Options non activées : WireGuard et clés FIDO2

Deux renforcements de l'accès administrateur, conçus mais pas encore codés. Chacun ferme une porte supplémentaire ; aucun n'est indispensable avec la configuration actuelle (clés SSH seules, sudo sur mot de passe).

## WireGuard : admin joignable seulement par le tunnel

### Idée

Le port SSH reste ouvert pour `deploy` (la CI doit pouvoir s'y connecter depuis des adresses imprévisibles), mais `admin` n'est plus accepté que s'il arrive par un tunnel WireGuard. Une clé `admin` volée ne suffit plus : il faut aussi la clé privée WireGuard du poste.

### Pourquoi c'est possible sans deux ports SSH

`AllowUsers` accepte la forme `utilisateur@adresse`, où l'adresse est celle **du client** :

```
AllowUsers admin@10.66.66.0/24 deploy
```

Connexion d'`admin` depuis Internet : refusée ; depuis le tunnel (10.66.66.x) : acceptée. `deploy` : inchangé.

WireGuard lui-même n'apparaît pas aux scanners : il ne répond à aucun paquet qui n'est pas signé par une clé connue. Le port UDP ouvert ne se distingue pas d'un port fermé.

### Bascule sans lock-out (même logique que le passage 22 → 22222)

1. Installer WireGuard sur le serveur, ouvrir le port UDP (51820), générer les clés ; la clé privée du serveur ne quitte pas le serveur.
2. Monter le tunnel depuis le poste (`sudo apt install wireguard-tools`, puis `wg-quick up`), et **prouver** une connexion `ssh admin@10.66.66.1` par le tunnel.
3. Seulement alors, écrire `AllowUsers admin@10.66.66.0/24 deploy`, valider avec `sshd -t`, recharger sshd.
4. Garder une session admin ouverte jusqu'à ce qu'une **nouvelle** connexion par le tunnel ait réussi.

Recours en cas de problème : la console web du provider (root est verrouillé mais admin peut se connecter à la console avec son mot de passe).

### Points à trancher avant de coder

- Plage d'adresses du tunnel et nombre de postes (un pair par poste).
- `ssh_allowed_cidrs` devient redondant pour admin ; le garder pour deploy si la CI a des IP fixes.
- Ansible passe alors par le tunnel : `ansible_host` = adresse du serveur dans le tunnel.

## Clés FIDO2 (`ed25519-sk`) pour admin

### Idée

La clé privée d'admin vit dans une clé matérielle (YubiKey, SoloKey, Nitrokey...) et ne peut pas en sortir. Chaque connexion exige un **contact physique** (et un PIN avec `verify-required`). Un logiciel malveillant sur le poste peut voler un fichier de clé, pas une clé matérielle.

Le serveur accepte déjà ce type de clé (`PubkeyAcceptedAlgorithms` contient `sk-ssh-ed25519@openssh.com`) ; il ne reste qu'à l'installer pour admin.

### Mise en place

Sur le poste (OpenSSH ≥ 8.2 et `libfido2`, déjà présents sur Ubuntu récent) :

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required -C admin-fido \
    -f ~/.ssh/ansible/app-prod/admin-fido
```

- `resident` : la clé est stockée dans le périphérique, récupérable sur un autre poste avec `ssh-keygen -K`.
- `verify-required` : PIN exigé en plus du contact.

### Ne jamais s'enfermer dehors

- **Deux clés matérielles**, enregistrées toutes les deux, dont une rangée ailleurs. Une clé perdue ou cassée ne doit pas couper l'accès.
- Pendant la transition, garder aussi la clé logicielle actuelle ; la retirer seulement quand les deux clés matérielles ont été testées.
- Côté Ansible, `authorized_key` doit alors recevoir **toutes** les clés d'admin dans une seule tâche avec `exclusive: true`, sinon chaque run effacerait les autres. C'est le même piège que la clé CI de deploy (voir `roles/app_deploy/tasks/main.yml`).

### Contrainte avec Ansible

Chaque nouvelle connexion SSH demande un contact. Ansible réutilise une connexion ouverte (`ControlPersist`, 60 s par défaut) : un run demande donc un contact au début, puis un autre à chaque pause de plus d'une minute. `ssh_args = -o ControlMaster=auto -o ControlPersist=30m` dans `ansible.cfg` réduit ça à un contact par run.

## Ordre conseillé

FIDO2 d'abord : peu de changements côté serveur, et protège contre le vol de clé sur le poste, qui est le risque le plus probable. WireGuard ensuite, quand le nombre de postes d'administration est connu.
