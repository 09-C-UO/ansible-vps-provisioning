# Infrastructure Scaleway (OpenTofu)

`infra/` crée la couche provider : VPS Ubuntu, IP fixe, pare-feu cloud, et si
`backup_enabled` le bucket Object Storage + la paire de clés dédiée de restic.
Tout le reste (comptes, durcissement, Traefik, apps, sauvegardes, intégrité)
reste la charge d'Ansible, inchangé.

## Répartition

| Couche | Outil | Ressources |
|---|---|---|
| Infrastructure | OpenTofu (`infra/`) | `scaleway_instance_server`, `instance_ip`, `instance_security_group`, `object_bucket`, `iam_application/policy/api_key` |
| Bootstrap OS | Ansible (`bootstrap.yml`) | comptes admin/deploy, SSH 22 → `ssh_port`, root verrouillé |
| Configuration | Ansible (`site.yml`) | durcissement, Traefik, apps, restic, AIDE |

Le point de collage est volontairement minimal : OpenTofu rend l'IP en sortie
(`tofu output -raw vps_ip`), et `provision.sh` accepte déjà cette IP en
argument. Aucun inventaire dynamique n'est nécessaire.

## Séquence

```bash
cp infra/prod.tfvars.example infra/prod.tfvars   # à compléter
just infra-plan prod                              # vérifier
just infra-provision prod                         # tofu apply + provision.sh
# compléter le vault avec just infra-outputs (restic_s3_*), puis :
just site prod $(tofu -chdir=infra output -raw vps_ip)
just close-ssh-22 prod                            # pare-feu : 22 fermé
```

`infra/provision.sh <env>` fait la première ligne complète : `tofu apply` puis
`provision.sh -i inventories/<env> <IP>` avec les options passées telles
quelles ( `-c <cidr>` restreint SSH côté sshd, `trusted_ssh_cidr` le fait
côté pare-feu).

## Pare-feu et port 22

`inbound_rule` du security group : 22 et `ssh_port` (restreignables à
`trusted_ssh_cidr`), 80 et 443 ouverts. Le 22 n'existe que pour le bootstrap
(`ssh-copy-id`) ; une fois sshd déplacé et root verrouillé par
`bootstrap.yml`, `just close-ssh-22 <env>` bascule `ssh_22_open = false`.
`ssh_port` doit valoir le `ssh_port` de l'inventaire Ansible.

## Secrets et state

- Les secrets Ansible restent dans `ansible-vault` : OpenTofu ne fournit que
  la paire de clés S3 (`restic_access_key`, `restic_secret_key`) à coller dans
  `secrets.vault.yml` (`restic_s3_access_key`, `restic_s3_secret_key`), et
  `restic_repository` dans `group_vars/vps/main.yml`.
- La secret key S3 est en clair dans le state Tofu : utiliser un backend
  distant (bloc `backend "s3"` commenté dans `main.tf`) et ne jamais committer
  `*.tfstate` (déjà ignorés).
- Les tfvars réels (`infra/prod.tfvars`) sont ignorés par git ; seul
  `prod.tfvars.example` est versionné.
- Les clés SSH admin/deploy restent générées hors Tofu (`ssh_key_dir`) :
  des clés privées n'ont rien à faire dans un state.

## Recettes

`just infra-plan`, `just infra-apply`, `just infra-provision`,
`just close-ssh-22`, `just infra-outputs` (voir `just --list`).
