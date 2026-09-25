# Sauvegardes

Rôle `backup`, activé par `backup_enabled: true`. Outil : [restic](https://restic.net). Il chiffre côté serveur avant l'envoi (le stockage ne voit que des blocs chiffrés), déduplique (une nuit sans changement ne coûte presque rien), et sait vérifier ses propres données.

## Ce qui est sauvegardé

| Élément | Comment |
|---|---|
| bases PostgreSQL (`postgres.enabled`) | `pg_dump -Fc` dans le conteneur, écrit dans `/var/backups/postgres/<app>.dump` puis inclus dans le snapshot |
| `/etc` | configuration système complète |
| `/opt/apps` | compose et secrets des applications (chiffrés dans le dépôt) |
| `/srv/apps` | contenu publié par deploy |
| `/opt/traefik/acme` | certificats (évite de repasser par Let's Encrypt, et ses quotas, après une restauration) |
| `/var/lib/aide` | base AIDE, pour comparer avec une copie ancienne en cas de doute |

`pg_dump` lit un instantané cohérent de la base sans l'arrêter. Le dump est d'abord écrit dans un fichier : si `pg_dump` échoue, la sauvegarde échoue et alerte, au lieu d'enregistrer un dump tronqué. Copier les fichiers de `/var/lib/postgresql/data` d'une base en marche donnerait une copie incohérente, souvent inutilisable.

## Calendrier

| Timer | Quand | Rôle |
|---|---|---|
| `backup-run` | chaque nuit (03:15 ± 15 min) | dumps + snapshot, puis rétention si `backup_prune_on_server` |
| `backup-check` | dimanche | `restic check --read-data-subset=5%` : structure et 5 % des données relues |
| `backup-restore-test` | le 1er du mois | restaure chaque dump dans un PostgreSQL jetable, sans réseau, et compte les tables |

Chaque échec envoie une alerte au canal Discord `infra`. Le test de restauration est ce qui distingue une sauvegarde d'un espoir : il prouve que le dump est lisible et que le mot de passe restic est le bon.

## Configuration

Inventaire :

```yaml
backup_enabled: true
restic_repository: s3:https://s3.eu-central-003.backblazeb2.com/mon-bucket/app-prod
restic_extra_env: {}          # ex. { AWS_DEFAULT_REGION: eu-central-003 }
backup_prune_on_server: true  # voir « Protection contre la suppression »
```

Vault :

```yaml
restic_password: "..."        # 20 caractères minimum ; SANS LUI, LES SAUVEGARDES SONT PERDUES
restic_s3_access_key: "..."
restic_s3_secret_key: "..."
```

Le mot de passe restic est la clé de chiffrement. Il doit exister ailleurs que dans le vault (gestionnaire de mots de passe) : si le poste d'administration et le serveur disparaissent ensemble, c'est la seule chose qui permet de relire les sauvegardes.

Choix du stockage : un fournisseur **différent** de celui du VPS (un incident de compte ou de datacenter ne doit pas emporter les deux). Tout stockage compatible S3 convient : Backblaze B2, Scaleway Object Storage, OVH Object Storage (dans ce cas, choisir une autre région que celle du VPS).

## Protection contre la suppression (rançongiciel)

Un intrus devenu root sur le serveur a les identifiants S3. S'ils permettent de supprimer, il peut effacer l'historique avant de chiffrer les données. Deux parades, au choix :

1. **Versioning ou Object Lock sur le bucket (recommandé)**, avec une rétention de 30 jours ou plus. Le serveur garde une clé normale et fait lui-même la rétention (`backup_prune_on_server: true`) ; une suppression malveillante reste récupérable pendant la durée de rétention. B2 : « Object Lock » ou « Keep prior versions for N days » ; S3 : versioning + Object Lock en mode *governance* ou *compliance*.
2. **Clé serveur sans droit de suppression** (`backup_prune_on_server: false`). Le serveur ne peut qu'ajouter. La rétention se fait depuis le poste d'administration, avec une autre clé :
   ```bash
   RESTIC_REPOSITORY=s3:https://.../mon-bucket/app-prod \
   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
   scripts/backup-prune.sh
   ```
   Contrepartie : restic ne peut pas supprimer ses fichiers de verrou. Ils s'accumulent jusqu'au prochain `backup-prune.sh`, qui commence par `restic unlock`.

## Restauration

### Une base, sur le serveur existant

```bash
sudo -i
backup-restic snapshots                               # choisir un snapshot (ou latest)
backup-restic dump latest /var/backups/postgres/monapp.dump > /root/monapp.dump
docker cp /root/monapp.dump monapp-db-1:/tmp/monapp.dump
docker exec -u postgres monapp-db-1 pg_restore --clean --if-exists -d monapp /tmp/monapp.dump
```

### Un serveur entier

1. Créer un VPS neuf, puis `./provision.sh -i inventories/prod <nouvelle IP>` : comptes, durcissement, Traefik et applications (vides) reviennent à l'identique, puisque tout est décrit dans le dépôt.
2. Mettre à jour l'enregistrement DNS vers la nouvelle IP.
3. Sur le serveur, restaurer les données :
   ```bash
   sudo backup-restic restore latest --target / --include /srv/apps --include /opt/traefik/acme
   # puis chaque base, comme ci-dessus
   ```
4. Ne **pas** restaurer `/etc` en bloc sur le nouveau serveur (clés hôte SSH, identifiants machine, UUID de disques) : y piocher les fichiers utiles.
5. `ssh-keygen -R <ancienne IP>` sur le poste d'administration, et reconstruire la base AIDE (`-e aide_accept=true`).

`backup-restic` est `restic` avec le dépôt et les identifiants du serveur (lus dans `/etc/restic/`, root uniquement).

## Vérifier

```bash
ssh <prefix>-admin
sudo systemctl list-timers 'backup-*'
sudo journalctl -u backup-run -n 30
sudo backup-restic snapshots
```
