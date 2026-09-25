# Secrets pièges (canary tokens)

Rôle `canary`. Un canary token est un faux secret (clés d'API, fichier de configuration, URL) posé sur le serveur, que rien ni personne n'utilise légitimement. S'il est utilisé, quelqu'un a fouillé le serveur et tente de réutiliser ce qu'il y a trouvé : c'est une intrusion, pas une fausse alerte.

## Comment ça marche

```
 intrus sur le serveur (root)
   │ 1. fouille : cat /root/.aws/credentials        → auditd note qui a lu (auid)
   │ 2. réutilise : aws s3 ls avec ces clés
   ▼
 AWS refuse, mais le compte AWS de Thinkst voit la tentative
   │
   ▼
 canarytokens.org → e-mail d'alerte (IP source, heure, user-agent)
```

L'alerte part **de l'extérieur**. Un intrus devenu root peut couper `notify-discord`, arrêter auditd ou vider les journaux : il ne peut pas empêcher Thinkst d'envoyer l'e-mail, puisque c'est son propre usage des clés qui le déclenche.

| Couche | Détecte | Ne détecte pas |
|---|---|---|
| alerte de connexion admin | une session admin ouverte | un intrus entré par une application |
| AIDE | un fichier système **modifié** | un fichier **lu** |
| canary token | un secret **lu puis réutilisé** | un intrus qui ne fouille pas (robot de minage : voir la surveillance de charge) |

## Créer un token

1. Aller sur [canarytokens.org](https://canarytokens.org) (Thinkst, gratuit, sans compte).
2. Choisir **AWS keys** : c'est le plus crédible sur un serveur, et le plus systématiquement essayé par un attaquant.
3. Renseigner :
   - l'**e-mail** qui recevra l'alerte, de préférence consulté sur le téléphone ;
   - une **note** qui identifie le token sans ambiguïté, par exemple `app-prod /root/.aws/credentials`. C'est elle qui dira, dans l'e-mail, **quel** serveur et **quel** fichier ont été compromis.
4. Le site affiche un bloc `[default]` avec `aws_access_key_id` et `aws_secret_access_key`. Le copier tel quel.
5. Garder le lien de gestion du token (il permet de consulter l'historique et de désactiver le token) dans le gestionnaire de mots de passe, **pas** dans le dépôt.

Un token par serveur : si deux serveurs partagent le même, l'alerte ne dira pas lequel est compromis.

## Le déposer

Dans le vault de l'environnement (le contenu d'un canary token est un secret : il ne doit jamais apparaître dans git, sinon n'importe quel lecteur du dépôt peut le déclencher) :

```bash
just vault-edit prod
```

```yaml
canary_files:
  - path: /root/.aws/credentials
    content: |
      [default]
      aws_access_key_id = AKIA...
      aws_secret_access_key = ...
```

Puis :

```bash
just tags prod <IP> canary      # dépose le fichier (root, 0600) et la règle auditd
just aide-accept prod <IP>      # le nouveau fichier apparaît une fois dans AIDE : l'accepter
```

### Choisir l'emplacement

Un bon emplacement est **plausible** (c'est là qu'un attaquant cherche en premier) et **inutilisé** (aucun programme légitime ne le lit) :

| Emplacement | Pourquoi |
|---|---|
| `/root/.aws/credentials` | premier réflexe de tout outil de post-exploitation ; aucun outil AWS sur ce serveur |
| `/root/.config/rclone/rclone.conf` (avec un token AWS au format rclone) | ressemble à une configuration de sauvegarde |

À éviter : un chemin lu par un vrai service (le token se déclencherait ou casserait le service), et un fichier lisible par deploy (le compromis d'une clé deploy déclencherait l'alerte, alors que le périmètre est justement root).

## Tester

Depuis le poste d'administration, jamais depuis le serveur (un test lancé depuis le serveur ferait croire à une intrusion dans l'historique du token) :

```bash
AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... \
    uvx --from awscli aws sts get-caller-identity
```

La commande échoue (`InvalidClientTokenId` ou similaire) ; l'e-mail doit arriver en quelques minutes. S'il n'arrive pas : dossier spam, puis adresse saisie sur canarytokens.org.

Vérification sur le serveur :

```bash
sudo ls -l /root/.aws/credentials      # root root, -rw-------
sudo ausearch -k canary -i             # lectures par un humain connecté (vide en temps normal)
```

## Quand l'alerte arrive

L'e-mail indique l'IP qui a utilisé les clés et l'heure. Considérer le serveur comme **compromis** : l'intrus avait les droits root, puisque le fichier n'est lisible que par root.

1. **Ne pas se connecter au serveur avec l'agent SSH ou une clé réutilisée ailleurs.** Un root malveillant peut détourner ce qui transite par la session.
2. **Couper l'accès sans détruire les preuves** : dans l'interface du provider, faire un **snapshot** du disque, puis retirer le serveur du réseau (firewall cloud : tout bloquer) ou l'éteindre.
3. **Révoquer tout ce que le serveur connaissait** :
   - les clés SSH admin, deploy et CI (générer de nouvelles paires) ;
   - le mot de passe sudo d'admin ;
   - les secrets des applications (`app_secrets`), les identifiants S3 de restic, les webhooks Discord, le jeton du registry, les jetons DNS ou Cloudflare ;
   - le mot de passe restic **ne suffit pas** à révoquer l'accès aux sauvegardes déjà faites : changer la clé S3, et vérifier que la rétention du bucket (versioning, Object Lock) a protégé l'historique.
4. **Comprendre**, sur le snapshot ou le serveur isolé :
   - `ausearch -k canary -i` : quel compte a lu le fichier (l'`auid` survit à sudo) ;
   - `ausearch -k root_commands -i` : ce qui a été exécuté en root avant et après ;
   - `journalctl -u ssh` : connexions et empreintes des clés utilisées ;
   - le dernier rapport AIDE : ce qui a été modifié.
5. **Reconstruire, ne pas nettoyer** : un nouveau VPS, `./provision.sh`, les données restaurées depuis une sauvegarde **antérieure** à l'intrusion ([BACKUP.md](BACKUP.md)). Un serveur où un intrus a été root ne redevient pas digne de confiance.

## Retirer ou remplacer un token

- Retirer : enlever l'entrée de `canary_files`, supprimer le fichier sur le serveur (`sudo rm /root/.aws/credentials`), relancer `just tags prod <IP> canary` (la règle auditd suit la liste), puis désactiver le token sur canarytokens.org via son lien de gestion.
- Remplacer : nouveau token, nouveau contenu dans le vault, relancer, accepter la modification dans AIDE.

## Limites

- Un intrus prudent peut reconnaître un canary token : les clés AWS de canarytokens.org appartiennent à un compte identifiable. Contre un attaquant ciblé et expérimenté, c'est un filet, pas une garantie ; contre l'essentiel des intrusions (automatisées ou opportunistes), il fonctionne.
- L'alerte dépend d'un service tiers (Thinkst). Le service est ouvert : il peut être auto-hébergé ([canarytokens sur GitHub](https://github.com/thinkst/canarytokens)) si cette dépendance pose problème.
