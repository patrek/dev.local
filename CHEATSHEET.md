# 📋 Dev.Local 2.0 - Aide-Mémoire Rapide

## 🚀 Commandes Essentielles

### Windows (PowerShell)

```powershell
# Menu interactif
.\menu.ps1

# Gestion des profils
.\manage-profiles.ps1 list                    # Lister
.\manage-profiles.ps1 -Action add             # Ajouter
.\manage-profiles.ps1 -Action generate        # Regénérer compose

# Services
.\launch.ps1                                  # Démarrer tout
.\launch.ps1 -p andoc,recpro                  # Profils spécifiques
.\launch.ps1 -c stop                          # Arrêter
.\launch.ps1 -c recreate                      # Recréer

# Secrets
.\manage-profiles.ps1 -Action init-secrets    # Initialiser
.\manage-profiles.ps1 -Action sync-secrets    # Synchroniser
.\launch.ps1 -c edit-secrets                  # Éditer
.\launch.ps1 -c view-secrets                  # Voir

# AWS
.\launch.ps1 -c sso                           # Connexion SSO
.\launch.ps1 -c id                            # Identité
.\launch.ps1 -c ecr-login                     # Docker ECR
```

### Linux/macOS (Bash)

```bash
# Menu interactif
./menu.sh

# Gestion des profils
./manage-profiles.sh list                     # Lister
./manage-profiles.sh add                      # Ajouter
./manage-profiles.sh generate                 # Regénérer compose

# Services
./launch.sh                                   # Démarrer tout
./launch.sh --profile andoc,recpro start      # Profils spécifiques
./launch.sh stop                              # Arrêter
./launch.sh recreate                          # Recréer

# Secrets
./manage-profiles.sh init-secrets             # Initialiser
./manage-profiles.sh sync-secrets             # Synchroniser
./launch.sh edit-secrets                      # Éditer
./launch.sh view-secrets                      # Voir

# AWS
./launch.sh sso                               # Connexion SSO
./launch.sh id                                # Identité
./launch.sh ecr-login                         # Docker ECR
```

## 📂 Structure des Fichiers

```
Dev.Local.2.0/
├── menu.ps1 / menu.sh                 # Menu principal
├── manage-profiles.ps1 / .sh          # Gestion profils
├── launch.ps1 / .sh                   # Orchestration
├── docker-compose.yml                 # Généré automatiquement
├── config.yml                         # Config globale + vars partagées
├── secrets.env                        # Chiffré SOPS
├── .sops.yaml                         # Config SOPS
├── profiles/                          # Profils de services
│   ├── andoc.yml
│   ├── recpro.yml
│   └── example.yml
├── traefik/
│   ├── traefik.yml                    # Config Traefik
│   └── dynamic.yml                    # Routes (généré)
└── docs/
    ├── README.md
    ├── BASH_README.md
    ├── shared-env-guide.md            # Guide vars partagées
    └── ...
```

## 🔄 Variables d'Environnement Partagées

### Configuration (config.yml)

```yaml
shared_env:
  global:
    - LOG_LEVEL=info
    - API_URL=https://api.example.com
  
shared_env_config:
  enabled: true
  auto_inject:
    - global
```

### Utilisation

```powershell
# Éditer les variables partagées
notepad config.yml

# Regénérer avec les nouvelles variables
.\manage-profiles.ps1 -Action generate

# Vérifier l'injection
Get-Content docker-compose.yml | Select-String "Variables partagées"
```

**💡 Astuce :** Les variables partagées sont injectées automatiquement dans tous les services. Parfait pour les URLs de services externes !

📚 **Guide complet :** [docs/shared-env-guide.md](docs/shared-env-guide.md)

## 🎯 Workflows Courants

### 1️⃣ Premier Démarrage

```bash
# 1. Initialiser secrets
./manage-profiles.sh init-secrets
sops secrets.env

# 2. Créer un profil
./manage-profiles.sh add

# 3. Démarrer
./launch.sh
```

### 2️⃣ Ajouter un Service

```bash
# 1. Créer le profil
./manage-profiles.sh add
# Répondre aux questions interactives

# 2. Synchroniser secrets
./manage-profiles.sh sync-secrets

# 3. Démarrer le nouveau service
./launch.sh --profile nom-service start
```

### 3️⃣ Modifier un Profil

```bash
# 1. Éditer manuellement
vi profiles/mon-service.yml

# 2. Regénérer compose
./manage-profiles.sh generate

# 3. Valider
docker compose config --quiet

# 4. Redémarrer
./launch.sh recreate
```

### 4️⃣ Gérer les Secrets

```bash
# Voir les secrets manquants
./manage-profiles.sh sync-secrets

# Éditer
./launch.sh edit-secrets
# ou directement
sops secrets.env

# Vérifier
./launch.sh view-secrets

# Appliquer
./launch.sh recreate
```

### 5️⃣ Déploiement AWS

```bash
# 1. SSO
./launch.sh sso

# 2. Vérifier
./launch.sh id

# 3. ECR
./launch.sh ecr-login

# 4. Démarrer
./launch.sh
```

## 📋 Options du Menu (1-16)

| # | Action | Équivalent CLI |
|---|--------|---------------|
| **1** | Démarrer tous | `./launch.sh` |
| **2** | Profils spécifiques | `./launch.sh --profile X,Y start` |
| **3** | Recréer | `./launch.sh recreate` |
| **4** | Arrêter | `./launch.sh stop` |
| **5** | Lister containers | `./launch.sh ps` |
| **6** | Ajouter profil | `./manage-profiles.sh add` |
| **7** | Lister profils | `./manage-profiles.sh list` |
| **8** | Regénérer compose | `./manage-profiles.sh generate` |
| **9** | Éditer secrets | `./launch.sh edit-secrets` |
| **10** | Voir secrets | `./launch.sh view-secrets` |
| **11** | Initialiser secrets | `./manage-profiles.sh init-secrets` |
| **12** | Synchroniser secrets | `./manage-profiles.sh sync-secrets` |
| **13** | AWS SSO | `./launch.sh sso` |
| **14** | AWS Identity | `./launch.sh id` |
| **15** | ECR Login | `./launch.sh ecr-login` |
| **16** | README | `cat README.md` |
| **0/q** | Quitter | - |

## 🔧 Dépannage Express

### Erreur : "command not found" ou "Permission denied"
```bash
# Linux/macOS : Ajouter permissions exécutables
chmod +x *.sh

# Windows : Vérifier et corriger automatiquement
.\fix-sh-permissions.ps1
```

### Vérifier les permissions des fichiers .sh
```bash
# Voir les permissions Git
git ls-files -s *.sh
# 100755 = exécutable ✅
# 100644 = non exécutable ❌

# Corriger manuellement
git update-index --chmod=+x fichier.sh
```

### Erreur : "bad interpreter: /bin/bash^M"
```bash
# Problème : Fichier utilise CRLF au lieu de LF
# Solution 1 : Utiliser dos2unix
dos2unix launch.sh

# Solution 2 : Avec sed
sed -i 's/\r$//' launch.sh

# Prévention : .gitattributes est configuré pour forcer LF
git check-attr -a launch.sh
```

### Erreur : "SOPS n'est pas installé"
```bash
# macOS
brew install sops

# Linux
wget https://github.com/mozilla/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64
sudo mv sops-v3.8.1.linux.amd64 /usr/local/bin/sops
chmod +x /usr/local/bin/sops
```

### Erreur : "Docker Compose v2+ requis"
```bash
# Vérifier
docker compose version

# Installer v2
https://docs.docker.com/compose/install/
```

### Erreur SOPS : "no key found"
```bash
# Configurer .sops.yaml
vi .sops.yaml

# Pour Age
creation_rules:
  - age: 'age1...'

# Pour AWS KMS
creation_rules:
  - kms: 'arn:aws:kms:ca-central-1:123456789012:key/...'
```

### Validation docker-compose.yml
```bash
docker compose config --quiet
# Aucune sortie = OK
```

### Logs Docker
```bash
docker compose logs -f
docker compose logs -f service-name
```

### Encodage UTF-8 (Linux)
```bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

## 🔐 Configuration SOPS

### Option 1 : Age (Recommandé pour développement)

```bash
# 1. Générer une clé
age-keygen -o ~/.config/sops/age/keys.txt

# 2. Copier la clé publique
cat ~/.config/sops/age/keys.txt | grep "public key"

# 3. Configurer .sops.yaml
cat > .sops.yaml << EOF
creation_rules:
  - age: 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p'
EOF
```

### Option 2 : AWS KMS (Production)

```bash
# 1. Créer une clé KMS dans AWS Console
# Region: ca-central-1
# Alias: dev-local-sops

# 2. Configurer .sops.yaml
cat > .sops.yaml << EOF
creation_rules:
  - kms: 'arn:aws:kms:ca-central-1:237029655182:key/your-key-id'
    aws_profile: ESG-DV-PowerUser-SSO
EOF

# 3. Tester
sops -e secrets.env.example > secrets.env
sops -d secrets.env
```

## 🐳 Docker Compose Avancé

### Voir la configuration finale
```bash
docker compose config
```

### Démarrer un seul service
```bash
docker compose up -d service-name
```

### Logs en temps réel
```bash
docker compose logs -f
```

### Rebuild un service
```bash
docker compose up -d --build service-name
```

### Forcer recréation
```bash
docker compose up -d --force-recreate
```

### Nettoyer tout
```bash
docker compose down -v
docker system prune -a
```

## 📊 Variables d'Environnement

### Docker Compose

```bash
# Profils actifs (sans lancer de services)
export COMPOSE_PROFILES=andoc,recpro

# Fichier de projet custom
export COMPOSE_FILE=docker-compose.custom.yml

# Nom du projet
export COMPOSE_PROJECT_NAME=devlocal
```

### SOPS

```bash
# Clé Age custom
export SOPS_AGE_KEY_FILE=/path/to/keys.txt

# AWS Profile
export AWS_PROFILE=ESG-DV-PowerUser-SSO
```

## 🎨 Personnalisation

### Changer le port Dozzle

```yaml
# config.yml
dozzle_enabled: true
dozzle_port: 9999  # Modifier ici
```

### Désactiver Dozzle

```yaml
# config.yml
dozzle_enabled: false
```

### Changer les ports Traefik

```yaml
# docker-compose.yml (après génération, éditer manuellement)
traefik:
  ports:
    - "127.0.0.1:8080:80"    # HTTP
    - "127.0.0.1:8081:8080"  # Dashboard
```

## 📖 Documentation Complète

| Fichier | Description |
|---------|-------------|
| `README.md` | Documentation principale |
| `BASH_README.md` | Guide Linux/macOS |
| `MIGRATION_GUIDE.md` | Migration Windows ↔ Linux |
| `BASH_CONVERSION_REPORT.md` | Détails techniques |
| `BASH_COMPLETION.md` | Résumé de la conversion |
| `QUICKSTART.md` | Démarrage rapide |

## 🆘 Aide Rapide

```bash
# Bash
./menu.sh                    # Menu interactif
./manage-profiles.sh --help  # Aide (si implémenté)
./launch.sh --help           # Aide (si implémenté)
./test-bash-scripts.sh       # Tester l'installation

# Docker
docker compose --help
docker compose ps
docker compose logs -f

# SOPS
sops --help
sops -d secrets.env
sops secrets.env
```

## ✅ Checklist Déploiement

- [ ] Docker & Docker Compose v2+ installés
- [ ] SOPS installé et configuré
- [ ] `.sops.yaml` créé avec clé Age ou KMS
- [ ] Scripts bash exécutables (`chmod +x *.sh`)
- [ ] `secrets.env` initialisé et édité
- [ ] Au moins un profil créé dans `profiles/`
- [ ] `docker-compose.yml` généré
- [ ] Validation réussie : `docker compose config --quiet`
- [ ] Services démarrés : `./launch.sh`
- [ ] Traefik accessible : `http://localhost:8081/dashboard/`
- [ ] Dozzle accessible : `http://localhost:9999/` (si activé)

---

**💡 Conseil** : Ajoutez cette page aux favoris de votre navigateur ou épinglez ce fichier pour un accès rapide !

**🔗 Liens Utiles** :
- Docker : https://docs.docker.com/
- SOPS : https://github.com/mozilla/sops
- Traefik : https://doc.traefik.io/traefik/
- Age : https://github.com/FiloSottile/age
