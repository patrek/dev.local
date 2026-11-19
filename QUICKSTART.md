# 🚀 Guide de Démarrage Rapide - Dev.Local 2.0

> **Guide pas-à-pas** pour démarrer avec Dev.Local en moins de 10 minutes !
>
> **Rôle de ce document :** le parcours minimal d'un premier démarrage, rien de plus. Le détail de chaque étape est dans [README.md](README.md), toutes les commandes dans [CHEATSHEET.md](CHEATSHEET.md).

## 📑 Table des matières

1. [Prérequis](#prérequis)
2. [Installation rapide](#installation-rapide)
   1. [Configuration SOPS](#1-configuration-sops)
   2. [Initialiser les secrets](#2-initialiser-les-secrets)
   3. [Ajouter votre premier service](#3-ajouter-votre-premier-service)
   4. [Démarrer les services](#4-démarrer-les-services)
   5. [Vérifier](#5-vérifier)
3. [Checklist de démarrage](#-checklist-de-démarrage)
4. [Prochaines étapes](#-prochaines-étapes)

## Prérequis

1. ✅ Docker & Docker Compose v2+ installés
2. ✅ PowerShell 5.1+ (Windows) ou Bash (Linux/macOS)
3. ✅ SOPS installé (binaire dans le PATH)
4. ⚠️  AWS CLI (optionnel, pour KMS uniquement)

Installation de SOPS, de `yq` (optionnel) et de Just (optionnel) : voir [README.md](README.md#prérequis). Sous Linux/macOS, rendez les scripts exécutables une fois : `chmod +x *.sh`.

## Installation rapide

Chaque étape donne la commande PowerShell (Windows) et la commande Bash (Linux/macOS).

### 1. Configuration SOPS

Créez `.sops.yaml` à partir du modèle :

```bash
cp .sops.example.yaml .sops.yaml     # PowerShell : Copy-Item .sops.example.yaml .sops.yaml
```

Choisissez ensuite une méthode de chiffrement :

#### Option A : Age (recommandé pour débuter)

```powershell
# Générer une clé Age
age-keygen -o age-key.txt

# Afficher la clé publique (commence par "age1...")
Get-Content age-key.txt | Select-String "public key"     # Bash : grep "public key" age-key.txt

# Éditer .sops.yaml : décommenter la ligne age: et y mettre votre clé publique

# Indiquer la clé privée à SOPS
$env:SOPS_AGE_KEY_FILE = "$(Get-Location)\age-key.txt"   # Bash : export SOPS_AGE_KEY_FILE="$PWD/age-key.txt"
```

Emplacement par défaut de la clé, variable persistante et dépannage : [docs/sops_age_guide.md](docs/sops_age_guide.md).

#### Option B : AWS KMS

```powershell
# Se connecter à AWS
.\launch.ps1 -c sso      # Bash : ./launch.sh sso

# Éditer .sops.yaml : décommenter la ligne kms: et y mettre l'ARN de votre clé
```

Détails : [README.md](README.md#configuration-sops-sopsyaml).

### 2. Initialiser les secrets

```powershell
.\manage-profiles.ps1 -Action init-secrets     # Bash : ./manage-profiles.sh init-secrets
```

`secrets.env` est créé et chiffré, puis l'éditeur SOPS s'ouvre : ajoutez vos secrets, sauvegardez et fermez.

### 3. Ajouter votre premier service

```powershell
# Via le menu interactif
.\menu.ps1                              # Bash : ./menu.sh
# Choisir option 6 : Ajouter un nouveau profil

# OU en ligne de commande
.\manage-profiles.ps1 -Action add       # Bash : ./manage-profiles.sh add
```

Exemple de réponses (les autres questions peuvent rester vides) :
```
Nom du service: mon-api
Description: Mon API backend
Image Docker: myregistry/api:latest
Port interne du conteneur: 8000
Port exposé localement: 8001
Service toujours actif: O
Activer Traefik: o
Préfixe de route: /api
Supprimer le préfixe: o
Regénérer docker-compose.yml maintenant: O
```

Le service doit répondre sur `/health` pour être routé par Traefik. Signification de chaque question : [README.md](README.md#exemple-de-création-guidée).

### 4. Démarrer les services

```powershell
.\launch.ps1         # Bash : ./launch.sh start

# OU via le menu (option 1)
.\menu.ps1           # Bash : ./menu.sh

# OU avec Just (si installé)
just start
```

Si vous avez répondu « n » à « Service toujours actif », le service est rattaché à un profil Docker : démarrez-le avec `just start-profile mon-api` (`.\launch.ps1 -p mon-api`, `./launch.sh --profile mon-api start`).

### 5. Vérifier

- Votre service : http://localhost:8080/api
- Traefik Dashboard : http://localhost:8081/
- Dozzle (logs) : http://localhost:9999/ ou http://localhost:8080/logs

Un problème ? Voir [Dépannage](README.md#-dépannage).

## ✅ Checklist de démarrage

- [ ] Docker & Docker Compose v2+ installés
- [ ] SOPS installé
- [ ] Scripts Bash exécutables (`chmod +x *.sh`, Linux/macOS)
- [ ] Clé Age générée OU AWS KMS configuré
- [ ] `.sops.yaml` créé et configuré
- [ ] `secrets.env` créé et chiffré
- [ ] Au moins un profil créé dans `profiles/`
- [ ] `docker-compose.yml` généré
- [ ] Validation réussie : `docker compose config --quiet`
- [ ] Services démarrés avec succès
- [ ] Traefik accessible sur http://localhost:8081/
- [ ] Dozzle accessible sur http://localhost:9999/ (si activé)

## 📚 Prochaines étapes

### Documentation approfondie

1. **README principal** - [README.md](README.md)
   - Toutes les fonctionnalités détaillées
   - Configuration avancée
   - Dépannage

2. **Aide-mémoire** - [CHEATSHEET.md](CHEATSHEET.md)
   - Toutes les commandes (Just, PowerShell, Bash)
   - Workflows courants (développement quotidien, ajout d'un service, partage avec l'équipe)
   - Alias PowerShell

3. **Variables partagées** - [docs/shared-env-guide.md](docs/shared-env-guide.md)
   - Centraliser les configurations communes (URLs d'APIs, log level, etc.) dans `config.yml`
   - Exemples complets dans [docs/shared-env-examples.md](docs/shared-env-examples.md)

4. **Support Linux/macOS** - [BASH_README.md](BASH_README.md)
   - Particularités des scripts Bash

### Personnalisation

1. **Profils personnalisés** - [Format d'un profil](README.md#-format-dun-profil)
   - Ajoutez vos services dans `profiles/`
   - Utilisez `profiles/example.yml` comme template
   - Documentation inline dans les profils

2. **Configuration Traefik** - [Personnalisation Traefik](README.md#personnalisation-traefik)
   - Éditez `traefik/traefik.yml`
   - Activez HTTPS

3. **Variables partagées** - [docs/shared-env-guide.md](docs/shared-env-guide.md)
   - Éditez `config.yml` pour centraliser vos URLs
   - Créez des groupes logiques (auth, database, external)
   - Activez/désactivez par service

4. **Secrets** - [Gestion des secrets avec SOPS](README.md#-gestion-des-secrets-avec-sops)
   - Ajoutez vos secrets dans `secrets.env` (chiffré)
   - Synchronisez automatiquement avec `sync-secrets`
   - Utilisez Age ou AWS KMS selon vos besoins

Bonne utilisation ! 🚀
