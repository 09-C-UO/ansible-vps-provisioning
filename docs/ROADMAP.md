# Feuille de route de sécurité

État de chaque couche de défense, en place ou envisagée. Le principe : pour chaque phase d'une attaque, se demander si elle est **empêchée** et si elle est **vue**. Les phases suivent [MITRE ATT&CK](https://attack.mitre.org/matrices/enterprise/linux/) (matrice Linux).

Légende : ✅ en place · 📐 conçu, documenté, pas activé · ⏳ décision en attente · ⬜ à faire

## Vue par phase d'attaque

| Phase | Empêcher | Voir |
|---|---|---|
| Reconnaissance | ✅ DROP silencieux, port SSH non standard | — |
| Accès initial | ✅ clés SSH seules, fail2ban, conteneurs durcis · 📐 FIDO2, WireGuard · ⬜ WAF, 2FA sudo | ✅ alerte connexion admin |
| Exécution, persistance | ✅ AppArmor, `no-new-privileges`, lint compose | ✅ AIDE, rkhunter, auditd · ⬜ Falco |
| Élévation de privilèges | ✅ sudo sur mot de passe, sysctl, `cap_drop: ALL` · ⬜ sandbox systemd, Livepatch | ✅ auditd `root_commands` |
| Vol d'identifiants | ✅ vault, fichiers root 0600 · ⬜ secrets à durée de vie courte | ✅ canary tokens |
| Exfiltration, commande à distance | ⬜ **filtrage sortant** | ⬜ logs externes |
| Effacement des traces | ✅ journald persistant | ⏳ **logs externes** |
| Impact | ✅ sauvegardes chiffrées, immuables, restauration testée | ✅ alertes d'échec de sauvegarde |

Les deux cases vides les plus coûteuses sont l'**exfiltration** (rien n'empêche un intrus de parler à l'extérieur) et l'**effacement des traces** (un root efface tout ce qui est local).

## Mesures

### 1. Comptes hors du serveur

| Mesure | État | Pourquoi |
|---|---|---|
| 2FA (clé matérielle ou TOTP) sur le provider, le registrar, GitHub, Discord, le stockage S3 et la boîte e-mail d'alerte | ⬜ | l'accès au panneau du provider donne la console du serveur ; l'accès au DNS détourne le domaine ; aucun durcissement du serveur ne protège de ça |
| Verrou registrar (« domain lock ») | ⬜ | empêche le transfert du domaine |
| Poste d'administration : disque chiffré, gestionnaire de mots de passe | ⬜ | il détient le mot de passe du vault et les clés SSH |

Aucun code : c'est le meilleur rapport valeur/effort de cette liste.

### 2. Réseau et bordure

| Mesure | État | Notes |
|---|---|---|
| UFW DROP, `DOCKER-USER`, fail2ban | ✅ | [HARDENING.md §3-4](HARDENING.md#3-pare-feu) |
| Cloudflare en proxy, 80/443 limités à Cloudflare | ✅ (option `edge_proxy`) | [HARDENING.md §10](HARDENING.md#10-bordure-cloudflare-et-certificats) |
| **Filtrage sortant** | ⬜ | liste des destinations autorisées (apt, Let's Encrypt, S3, Discord, registry) ; pour les conteneurs, règles dans `DOCKER-USER`. Coupe le téléchargement d'outils, le serveur de commande de l'attaquant, l'exfiltration et le minage |
| CrowdSec + bouncer Traefik | ⬜ | fail2ban collaboratif : réputation d'IP partagée |
| WAF (plugin Coraza dans Traefik, ou WAF Cloudflare) | ⬜ | injections SQL, XSS, scanners connus ; à régler contre les faux positifs |
| WireGuard, admin uniquement par le tunnel | 📐 | [OPTIONS.md](OPTIONS.md) |

### 3. Accès et identité

| Mesure | État | Notes |
|---|---|---|
| Clés SSH seules, un compte par rôle, sudo sur mot de passe | ✅ | |
| Clés FIDO2 `ed25519-sk` pour admin | 📐 | [OPTIONS.md](OPTIONS.md) ; protège contre le vol de clé sur le poste |
| Second facteur sur sudo (`pam_u2f`) | ⬜ | clé physique exigée pour devenir root ; demande d'adapter l'usage d'Ansible |
| Certificats SSH à durée courte (CA SSH, `step-ca`) | ⬜ | modèle d'entreprise ; surdimensionné pour un serveur, formateur |

### 4. Système

| Mesure | État | Notes |
|---|---|---|
| sysctl, modules, AppArmor, auditd, mises à jour automatiques | ✅ | [HARDENING.md §5-7](HARDENING.md#5-noyau-sysctl-et-modules) |
| Livepatch (Ubuntu Pro, gratuit jusqu'à 5 machines) | ⬜ | correctifs noyau sans redémarrage, alors que `automatic_reboot` vaut `false` |
| Ubuntu Security Guide (CIS) | ⬜ | audit et remédiation CIS automatisés (Ubuntu Pro) |
| Sandbox systemd des unités du dépôt | ⬜ | `systemd-analyze security <unité>` ; `ProtectSystem=strict`, `SystemCallFilter=`, `CapabilityBoundingSet=` |
| `/tmp` en `noexec,nosuid`, `/proc` en `hidepid=2` | ⬜ | réduit l'exécution depuis `/tmp` et la vue sur les processus des autres |
| Journal scellé (`journalctl --setup-keys`) | ⬜ | `Seal=yes` est configuré mais sans effet sans cette clé, qui doit rester hors du serveur |

### 5. Conteneurs et chaîne d'approvisionnement

| Mesure | État | Notes |
|---|---|---|
| Conteneurs non-root, lecture seule, `cap_drop: ALL`, lint compose | ✅ | [HARDENING.md §11](HARDENING.md#11-applications-et-déploiement) |
| Déploiement par digest, dépôts autorisés, rollback | ✅ | [DEPLOYMENT.md](DEPLOYMENT.md) |
| Scan d'images (Trivy, Grype) dans la CI | ⬜ | bloque une image qui contient une CVE critique |
| **Signature des images (cosign), vérifiée par `app-deploy`** | ⬜ | un accès au registry ne suffit plus à faire déployer une image piégée : prolongement direct du mécanisme actuel |
| Images distroless | ⬜ | pas de shell ni d'outils pour un intrus dans le conteneur |
| Renovate ou Dependabot | ⬜ | mises à jour des versions épinglées (Traefik, PostgreSQL) par pull request |
| Actions CI épinglées par SHA, OIDC au lieu de secrets permanents | ⬜ | protège la CI, qui a le droit de déployer |

### 6. Détection

| Mesure | État | Notes |
|---|---|---|
| AIDE, rkhunter, alerte connexion admin, canary tokens | ✅ | [HARDENING.md §12, §14](HARDENING.md#12-intégrité-aide-et-rkhunter), [CANARY.md](CANARY.md) |
| Métriques serveur | ✅ | disque, inodes, mémoire, charge |
| **Logs externes** | ⏳ | comparatif dans [README.md](README.md) ; recommandation : Vector |
| Alertes d'intrusion qui sonnent (ntfy, priorité urgente) | ⬜ | les notifications Discord ne garantissent pas la sonnerie sur le téléphone |
| Falco (détection comportementale eBPF) | ⬜ | « un shell s'ouvre dans un conteneur nginx » ; le meilleur outil pour apprendre ce qu'est un comportement anormal |
| Laurel (auditd en JSON) | ⬜ | utile une fois auditd envoyé vers les logs externes |
| Wazuh (SIEM/HIDS) | ⬜ | complet mais lourd pour un seul VPS |

### 7. Contrôle continu

| Mesure | État | Notes |
|---|---|---|
| Labo Docker : provision, idempotence, tests d'attaque | ✅ | `just lab` |
| Scan externe périodique (`nmap` depuis une autre machine) | ⬜ | un port inattendu doit être découvert par l'administrateur en premier |
| Lynis, `ssh-audit`, `testssl.sh` suivis dans le temps | ⬜ | noter les scores à chaque évolution (Lynis : 72 → 78 lors du premier durcissement) |
| Exercices : reconstruction complète, déclenchement d'un canary, disque plein | ⬜ | une procédure jamais répétée ne fonctionne pas le jour venu |

## Ordre conseillé

1. 2FA et verrous sur les comptes externes.
2. Logs externes : trancher la destination, puis implémenter.
3. FIDO2 pour admin.
4. Filtrage sortant.
5. Signature des images vérifiée par `app-deploy`, dès la première application en CI.
6. Livepatch, sandbox systemd, journal scellé.
7. Falco.

## Références

- **ANSSI**, *Recommandations de configuration d'un système GNU/Linux* : en français, organisé par niveaux (minimal, intermédiaire, renforcé, élevé). Permet de situer chaque mesure de ce dépôt.
- **CIS Benchmarks** Ubuntu Linux et Docker : la base des contrôles de Lynis et des audits de conformité.
- **OWASP** *Docker Security Cheat Sheet*.
- **MITRE ATT&CK**, matrice Linux : raisonner par phases d'attaque.
- Point de vue offensif : **HackTricks** (élévation de privilèges Linux), salles Linux de **TryHackMe** et **HackTheBox**. Comprendre l'attaque est ce qui fait le plus progresser en défense.
