# Dev.Local - Gestionnaire de Services Docker Générique

Un système modulaire et générique pour gérer des services Docker avec profils dynamiques et gestion sécurisée des secrets via SOPS.

> **Rôle de ce document :** référence complète de Dev.Local (concepts, configuration, comportement). Pour un premier démarrage, suivez [QUICKSTART.md](QUICKSTART.md) ; pour retrouver une commande, ouvrez [CHEATSHEET.md](CHEATSHEET.md). Les autres guides sont listés dans [Documentation complète](#-documentation-complète).

## 📑 Table des matières

- [💡 À quoi sert Dev.Local ?](#-à-quoi-sert-devlocal-)
- [🎯 Caractéristiques](#-caractéristiques)
- [🚀 Démarrage rapide](#-démarrage-rapide)
- [📁 Structure du projet](#-structure-du-projet)
- [🎮 Utilisation](#-utilisation)
- [📝 Ajouter un nouveau service](#-ajouter-un-nouveau-service)
- [🔄 Variables d'environnement partagées](#-variables-denvironnement-partagées)
- [🔐 Gestion des secrets avec SOPS](#-gestion-des-secrets-avec-sops)
- [📋 Format d'un profil](#-format-dun-profil)
- [🔧 Configuration avancée](#-configuration-avancée)
- [🛠️ Scripts et commandes disponibles](#️-scripts-et-commandes-disponibles)
- [📚 Exemples pratiques](#-exemples-pratiques)
- [☁️ AWS et Docker Registry](#️-aws-et-docker-registry)
- [🐧 Support Linux/macOS](#-support-linuxmacos)
- [📚 Documentation complète](#-documentation-complète)
- [🔒 Sécurité](#-sécurité)
- [🌍 Compatibilité Multiplateforme](#-compatibilité-multiplateforme)
- [🔧 Développement](#-développement)
- [🤝 Contribution](#-contribution)
- [🔧 Dépannage](#-dépannage)
- [🔧 Développeurs Windows : Permissions des fichiers .sh](#-développeurs-windows--permissions-des-fichiers-sh)
- [📄 Licence](#-licence)

## 💡 À quoi sert Dev.Local ?

**Dev.Local** est un environnement de développement local orchestré qui simplifie la gestion de multiples services Docker. Il vous permet de :

- **Démarrer rapidement** un environnement complet avec tous vos services (APIs, bases de données, frontends, etc.)
- **Gérer facilement** plusieurs profils de services selon vos besoins (activer/désactiver des services à la volée)
- **Sécuriser vos secrets** (mots de passe, clés API) avec chiffrement SOPS intégré
- **Accéder simplement** à tous vos services via des URLs propres grâce à Traefik (ex: `http://localhost:8080/api`)
- **Travailler en équipe** avec une configuration partagée et reproductible

**Cas d'usage typiques :**
- Développeur frontend qui a besoin de plusieurs APIs backend
- Développeur fullstack gérant un écosystème de microservices
- Équipe partageant un environnement de développement standardisé
- Tests d'intégration nécessitant plusieurs services interconnectés

## 🎯 Caractéristiques

- **Gestion dynamique des profils** : Ajoutez facilement de nouveaux services
- **Secrets sécurisés** : Intégration SOPS avec AWS KMS ou Age
- **Configuration modulaire** : Chaque service dans son propre fichier
- **Menu interactif** : Interface simple pour toutes les opérations
- **Traefik intégré** : Reverse proxy automatique

## 🚀 Démarrage rapide

### Prérequis

**Obligatoires :**
- Docker & Docker Compose v2+
- PowerShell 5.1+ (Windows) ou Bash (Linux/macOS)
- SOPS (binaire installé et dans le PATH)

**Optionnels :**
- AWS CLI (pour utiliser AWS KMS avec SOPS)
- Just command runner (recommandé pour faciliter l'utilisation)
- Age (alternative à AWS KMS pour SOPS)
- yq v4+ (mikefarah) — optionnel : les scripts Bash l'utilisent pour lire les profils et `config.yml`. S'il n'est pas installé, ils l'exécutent automatiquement depuis son image Docker (`mikefarah/yq`), plus lentement.

Sous PowerShell, les fichiers YAML sont lus avec le module `powershell-yaml` : `manage-profiles.ps1` l'installe pour l'utilisateur courant s'il est absent.

### Installation de SOPS

**Windows (Chocolatey) :**
```powershell
choco install sops
```

**Linux :**
```bash
# Via release GitHub
wget https://github.com/mozilla/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64
sudo mv sops-v3.8.1.linux.amd64 /usr/local/bin/sops
chmod +x /usr/local/bin/sops
```

**macOS (Homebrew) :**
```bash
brew install sops
```

### (Optionnel) Installation de yq (recommandé)

Sans installation locale, les scripts Bash exécutent `yq` via Docker : l'image est téléchargée au premier lancement (connexion requise) et chaque lecture YAML démarre un conteneur. Pour une génération plus rapide et utilisable hors ligne, installez `yq` (mikefarah) :

**Linux (binaire officiel) :**
```bash
sudo wget -q -O /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.50.1/yq_linux_amd64"
sudo chmod +x /usr/local/bin/yq
```

**macOS (Homebrew) :**
```bash
brew install yq
```

Une fois `yq` installé, les scripts l'utiliseront automatiquement à la place de l'image Docker ; le résultat est identique dans les deux cas. La version de l'image peut être changée avec la variable `YQ_IMAGE` (voir `lib/yq.sh`).

### Configuration initiale

Le parcours pas-à-pas (configurer SOPS, initialiser `secrets.env`, créer un premier profil, générer puis démarrer) est décrit dans [QUICKSTART.md](QUICKSTART.md). Chaque étape est détaillée ici :

| Étape | Référence |
|-------|-----------|
| Configurer SOPS (Age ou AWS KMS) | [Configuration SOPS (.sops.yaml)](#configuration-sops-sopsyaml) |
| Initialiser et éditer les secrets | [Gestion des secrets avec SOPS](#-gestion-des-secrets-avec-sops) |
| Créer un profil de service | [Ajouter un nouveau service](#-ajouter-un-nouveau-service) |
| Générer les fichiers | [Génération des fichiers](#génération-des-fichiers) |
| Démarrer les services | [Utilisation](#-utilisation) |

### Génération des fichiers

`docker-compose.yml` et `traefik/dynamic.yml` ne sont pas versionnés : ils sont générés à partir de `profiles/*.yml` et de `config.yml`. Ne les éditez pas à la main, vos modifications seraient écrasées à la génération suivante.

```bash
just generate                             # toutes plateformes
./manage-profiles.sh generate             # Bash
.\manage-profiles.ps1 -Action generate    # PowerShell
```

Les scripts de lancement lancent eux-mêmes la génération si `docker-compose.yml` n'existe pas encore. Sous Bash, `generate` exécute d'abord `validate-profiles.sh` et s'arrête si un profil est invalide.

Contenu de `docker-compose.yml` :

- en en-tête, la clé `name: <namespace>` prise depuis `config.yml` (clé `namespace`, `devlocal` si elle est absente) ;
- `socket-proxy` (`tecnativa/docker-socket-proxy:v0.5.0`) : seul conteneur qui monte le socket Docker, en lecture seule et sans requête d'écriture ;
- `traefik` (`traefik:v3.6.4`), publié sur `127.0.0.1:8080` (HTTP) et `127.0.0.1:8081` (dashboard) ;
- `dozzle` (`amir20/dozzle:v11.5.0`, version épinglée), publié sur `127.0.0.1:<dozzle_port>`, si `dozzle_enabled` vaut `true` ;
- un service par profil activé (voir [Format d'un profil](#-format-dun-profil)) ;
- une section `volumes:` de premier niveau déclarant les volumes nommés utilisés par les profils (voir [Exemple 4](#exemple-4--développement-avec-hot-reload)).

`traefik/dynamic.yml` contient les routers, services et middlewares Traefik de chaque profil dont `traefik.enabled` vaut `true`, ainsi que la route `/logs` vers Dozzle.

Pour vérifier le résultat :

```bash
sed -n '1,40p' docker-compose.yml        # vérifier l'en-tête et la clé `name:`
sed -n '1,240p' traefik/dynamic.yml      # vérifier la config Traefik
just validate                            # docker compose config --quiet
```

### Vérification de l'installation

Après le démarrage, vérifiez que tout fonctionne :

- **Traefik Dashboard :** http://localhost:8081/
- **Dozzle (logs) :** http://localhost:9999/logs ou http://localhost:8080/logs
- **Vos services :** http://localhost:8080/[prefix-du-service]

Ces ports ne sont ouverts que sur `127.0.0.1` : ils ne sont pas joignables depuis une autre machine du réseau.

## 📁 Structure du projet

```
dev.local/
├── profiles/                    # Définitions des profils de services
│   ├── example.yml              # Modèle de profil commenté
│   ├── gulp.example.yml         # Exemple de profil « outil » (gulp, npm)
│   └── <nom-service>.yml        # Vos profils personnalisés
├── traefik/
│   ├── traefik.yml              # Config principale de Traefik
│   └── dynamic.yml              # Routes (généré, non versionné)
├── lib/
│   └── yq.sh                    # yq local ou via Docker (scripts Bash)
├── docs/                        # Guides thématiques
├── tests/                       # Tests des scripts (fixtures, fichiers attendus)
├── docker-compose.yml           # Composition Docker (généré, non versionné)
├── config.yml                   # Configuration globale (Dozzle, registres, AWS, variables partagées)
├── secrets.env                  # Secrets chiffrés SOPS (créé par init-secrets)
├── secrets.env.example          # Modèle de secrets.env
├── .sops.yaml                   # Configuration SOPS (à créer depuis .sops.example.yaml)
├── .env.example                 # Modèle de .env (variables locales non sensibles)
├── justfile                     # Recettes Just
├── menu.ps1 / menu.sh                           # Menu interactif
├── launch.ps1 / launch.sh                       # Cycle de vie des services, secrets, AWS
├── manage-profiles.ps1 / manage-profiles.sh     # Profils, génération, secrets.env
├── validate-profiles.ps1 / validate-profiles.sh # Validation des profils
├── fix-sh-permissions.ps1                       # Bit exécutable des .sh (Windows)
└── README.md                    # Ce fichier
```

## 🎮 Utilisation

Dev.Local offre **trois façons** de gérer vos services Docker. Elles appellent les mêmes scripts ; la liste complète des commandes, avec leurs équivalents Just, PowerShell et Bash, est dans [CHEATSHEET.md](CHEATSHEET.md).

### 1️⃣ Just (Recommandé - Multiplateforme)

[Just](https://github.com/casey/just) est un command runner simple et multiplateforme qui fonctionne sur Windows, Linux et macOS.

```bash
just --list                       # Afficher toutes les commandes disponibles
just start                        # Démarrer les services toujours actifs
just start-profile api,ui         # Démarrer en plus les profils Docker indiqués
just logs api                     # Suivre les logs d'un service
just run gulp npx gulp build      # Exécuter une commande ponctuelle dans un service
just stop                         # Arrêter tous les services
just clean                        # Supprimer containers et volumes de tous les profils
```

À savoir :

- `just start` exécute `docker compose up -d` sans profil : il démarre Traefik, Dozzle et les services dont le profil indique `always_active: true`. Les services rattachés à un profil Docker (`docker_profile`) ne démarrent qu'avec `just start-profile <profil1,profil2>` ou avec l'option 1 du menu, qui inclut tous les profils activés.
- `just restart` arrête tous les services puis relance comme `just start`.
- `just run <service> <commande...>` crée un conteneur ponctuel (`docker compose run --rm`), y charge les secrets SOPS, puis le supprime. Le service est utilisable même si son profil Docker n'est pas démarré, et ses ports ne sont pas publiés. Voir [Exemple 4 bis](#exemple-4-bis--outils-de-build-dans-docker-gulp-npm-).
- `just clean` exécute `docker compose --profile "*" down -v --remove-orphans` : les volumes de tous les profils sont supprimés, y compris leurs données.
- `just validate` vérifie le `docker-compose.yml` généré (`docker compose config --quiet`). La validation des profils eux-mêmes se fait avec `./validate-profiles.sh` ou `.\validate-profiles.ps1` (option 9 du menu).

**Installation de Just :**
- **Windows (Chocolatey):** `choco install just`
- **Windows (Scoop):** `scoop install just`
- **Linux/macOS (Homebrew):** `brew install just`
- **Cargo:** `cargo install just`

### 2️⃣ Menu interactif

Le menu interactif offre une interface simple pour toutes les opérations :

```bash
just menu      # toutes plateformes
.\menu.ps1     # Windows (PowerShell)
./menu.sh      # Linux/macOS (Bash)
```

Il regroupe 17 options numérotées (plus `m` pour démarrer les services minimums, sans profil) en cinq catégories : services Docker, gestion des profils, secrets SOPS, AWS et Docker, documentation. Chaque option affiche la commande qu'elle exécute ; la correspondance complète est dans [CHEATSHEET.md](CHEATSHEET.md#-options-du-menu).

### 3️⃣ Ligne de commande directe

**Windows (PowerShell) :**
```powershell
.\launch.ps1                          # Démarrer les services toujours actifs
.\launch.ps1 -p service1,service2     # Démarrer avec profils spécifiques
.\launch.ps1 logs -service example    # Voir les logs d'un service
.\launch.ps1 stop                     # Arrêter
```

**Linux/macOS (Bash) :**
```bash
./launch.sh start                                # Démarrer les services toujours actifs
./launch.sh --profile service1,service2 start    # Démarrer avec profils spécifiques
./launch.sh logs example                         # Voir les logs d'un service
./launch.sh stop                                 # Arrêter
```

Sous PowerShell, la commande peut être passée en position (`.\launch.ps1 stop`) ou avec `-c` (`.\launch.ps1 -c stop`). Sous Bash, `./launch.sh` sans argument équivaut à `./launch.sh start`.

### Quelle méthode choisir ?

| Méthode | Avantages | Quand utiliser |
|---------|-----------|----------------|
| **Just** | ✅ Syntaxe courte et claire<br>✅ Multiplateforme<br>✅ Autocomplete disponible<br>✅ Commandes mémorisables | Utilisation quotidienne, scripts CI/CD |
| **Menu** | ✅ Interface guidée<br>✅ Pas besoin de mémoriser les commandes<br>✅ Idéal pour les débutants | Découverte, opérations ponctuelles |
| **CLI directe** | ✅ Contrôle total<br>✅ Scriptable<br>✅ Pas de dépendances externes | Scripts automatisés, intégrations custom |

## 📝 Ajouter un nouveau service

### Méthodes disponibles

#### Option 1 : Menu interactif (Recommandé pour débuter)

Lancez le menu (`just menu`, `.\menu.ps1` ou `./menu.sh`), puis choisissez l'option 6 : **"Ajouter un nouveau profil"**.

#### Option 2 : Ligne de commande

```powershell
# Windows
.\manage-profiles.ps1 -Action add

# Linux/macOS
./manage-profiles.sh add
```

#### Option 3 : Copier un modèle

Copiez `profiles/example.yml` (modèle commenté) ou `profiles/gulp.example.yml` (profil « outil ») vers `profiles/<nom-service>.yml`, adaptez-le, passez `enabled` à `true`, puis lancez `just generate`.

Le script vous guidera étape par étape pour configurer :
- ✅ Nom du service
- ✅ Description
- ✅ Image Docker (avec support de variables)
- ✅ Ports (conteneur, service local, publication optionnelle sur l'hôte)
- ✅ Activation : toujours actif ou rattaché à un profil Docker
- ✅ Configuration Traefik (routing HTTP)
- ✅ Variables d'environnement
- ✅ Secrets requis (stockés dans secrets.env chiffré)

Un health check Docker (`curl` sur `/health`) est ajouté automatiquement au profil créé.

### Exemple de création guidée

```
Nom du service (ex: api-backend, frontend): mon-api
Description du service: Mon API REST backend
Image Docker (ex: nginx:latest, registry.io/myapp:v1.0): ${MON_API_IMAGE:-myregistry/api}:${MON_API_TAG:-latest}
Port interne du conteneur (ex: 80, 8000): 8000
Port exposé localement (via Traefik host) (ex: 8001): 8001
Publier aussi un port sur l'hôte (hôte:conteneur, ex: 9000:8000, Entrée pour aucun):
Service toujours actif (démarré par défaut) ? (O/n): o
Activer Traefik ? (o/N): o
Préfixe de route (ex: /api, /app): /api
Supprimer le préfixe avant transmission ? (O/n): o
Variable d'environnement:
Nom du secret:
Regénérer docker-compose.yml maintenant ? (O/n): o
```

Le profil sera créé dans `profiles/mon-api.yml`. Les réponses correspondent aux champs décrits dans [Format d'un profil](#-format-dun-profil) : « Port interne du conteneur » devient `traefik.docker_port`, « Port exposé localement » devient `traefik.local_port`, et la publication d'un port sur l'hôte active `expose_ports`.

## 🔄 Variables d'environnement partagées

Dev.Local supporte l'injection automatique de variables d'environnement communes à tous vos services. Ceci est idéal pour :

- 🌐 URLs de services externes (APIs, passerelles, authentification)
- 🔧 Configuration commune (log level, timezone, environnement)
- 📊 Paramètres partagés entre microservices

Elles se déclarent dans `config.yml` : des groupes de variables sous `shared_env`, et les règles d'injection sous `shared_env_config` (`enabled`, `auto_inject`, `exclude_services`, `service_specific`). Elles sont injectées à la génération, et le script affiche le nombre de variables ajoutées à chaque service :

```
✅ Ajout : mon-service
   📌 6 variable(s) partagée(s)
```

**Note :** Les variables du profil ont priorité sur les variables partagées en cas de conflit. Les secrets n'ont pas leur place ici : ils vont dans `secrets.env`.

- 📚 **Référence (clés, règles d'injection, FAQ) :** [docs/shared-env-guide.md](docs/shared-env-guide.md)
- 🧪 **Exemples complets :** [docs/shared-env-examples.md](docs/shared-env-examples.md)

## 🔐 Gestion des secrets avec SOPS

Les secrets sont stockés dans `secrets.env`, chiffré par SOPS. Au démarrage (`start`, `recreate`, `run`), les scripts de lancement le déchiffrent et exportent chaque variable pour Docker Compose, ce qui résout les références `${VAR}` des profils. Si SOPS est absent, mal configuré ou si le déchiffrement échoue, un avertissement est affiché et les services démarrent sans secrets.

### Configuration SOPS (.sops.yaml)

`.sops.yaml` n'est pas fourni dans le dépôt : créez-le à partir du modèle, puis activez une méthode de chiffrement.

```bash
cp .sops.example.yaml .sops.yaml
```

```yaml
creation_rules:
  - path_regex: secrets\.env$
    # Option 1 : AWS KMS
    kms: 'arn:aws:kms:REGION:ACCOUNT:key/KEY-ID'

    # Option 2 : Age
    # age: 'age1...'
```

- **Age (recommandé pour débuter)** : génération de la clé et configuration dans [docs/sops_age_guide.md](docs/sops_age_guide.md).
- **AWS KMS** : créez une clé KMS dans la console AWS (par exemple région `ca-central-1`, alias `dev-local-sops`), connectez-vous avec `just aws-sso` (voir [Configuration du profil AWS](#configuration-du-profil-aws)), puis renseignez l'ARN de la clé dans `kms:`. La clé optionnelle `aws_profile` indique à SOPS le profil AWS à utiliser :

  ```yaml
  creation_rules:
    - path_regex: secrets\.env$
      kms: 'arn:aws:kms:ca-central-1:123456789012:key/your-key-id'
      aws_profile: <profil-aws>
  ```

Les scripts refusent d'éditer ou de déchiffrer tant qu'aucune ligne `kms:` ou `age:` n'est active (non commentée) dans `.sops.yaml`.

### Initialiser le fichier de secrets

```powershell
.\manage-profiles.ps1 -Action init-secrets   # PowerShell
./manage-profiles.sh init-secrets            # Bash
```

`init-secrets` exige que SOPS soit installé et que `.sops.yaml` existe. Il copie `secrets.env.example` vers `secrets.env`, le chiffre immédiatement (aucun `secrets.env` en clair ne reste sur disque ; en cas d'échec du chiffrement le fichier est supprimé), puis propose d'ouvrir l'éditeur SOPS.

### Éditer et consulter les secrets

```powershell
# Via SOPS directement
sops secrets.env

# Via les scripts
just secrets-edit            # ou .\launch.ps1 -c edit-secrets, ./launch.sh edit-secrets
just secrets-view            # ou .\launch.ps1 -c view-secrets, ./launch.sh view-secrets

# Via le menu : options 10 (éditer) et 11 (voir)
```

`edit-secrets` lance `init-secrets` si `secrets.env` n'existe pas encore. `view-secrets` affiche les secrets en clair dans le terminal.

### Format du fichier secrets.env

```env
# Secrets globaux
DATABASE_PASSWORD=ChangeMe123!
API_KEY=your-api-key-here

# Secrets par service (prefixés)
SERVICE1_SECRET_TOKEN=token123
SERVICE2_DB_PASSWORD=password456
```

### Synchroniser les secrets avec les profils

```powershell
.\manage-profiles.ps1 -Action sync-secrets   # PowerShell
./manage-profiles.sh sync-secrets            # Bash
```

`sync-secrets` déchiffre `secrets.env`, liste les secrets requis par les profils activés qui n'y figurent pas encore et, après confirmation, les ajoute avec leur valeur par défaut avant de rechiffrer le fichier. Les règles de détection sont décrites dans [Section `secrets:`](#section-secrets-recommandée).

Pour afficher uniquement les noms détectés, sans SOPS ni déchiffrement :

```powershell
.\manage-profiles.ps1 -Action list-secrets   # PowerShell
./manage-profiles.sh list-secrets            # Bash
```

## 📋 Format d'un profil

Les profils sont des fichiers YAML dans le dossier `profiles/`. `profiles/example.yml` est un modèle entièrement commenté.

```yaml
# profiles/mon-service.yml
name: mon-service
description: "Description du service"
enabled: true                 # false : le profil est ignoré à la génération
always_active: false          # true : démarré par `just start`, sans profil Docker
docker_profile: mon-service   # profil Docker du service (requis si always_active: false)
expose_ports: false           # true pour publier la section ports (voir ci-dessous)

# Configuration Docker Compose (recopiée dans le service, sauf ports et environment)
docker-compose:
  image: myregistry/service:latest
  container_name: mon-service
  ports:
    - "8000:8000"
  environment:
    - ENV_VAR=value
    - SECRET_KEY=${SECRET_KEY:-changeme}

# Configuration Traefik (optionnel)
traefik:
  enabled: true
  prefix: /mon-service
  strip_prefix: true
  docker_port: 8000     # port du service dans le conteneur
  local_port: 8000      # port du même service lancé sur le poste, hors Docker
  health_path: /health  # chemin du health check (défaut : /health)
  priority: 10

# Documentation des secrets requis (recommandé)
secrets:
  - name: SECRET_KEY
    description: "Clé API secrète"
    default: changeme
  - name: DATABASE_PASSWORD
    description: "Mot de passe de la base de données"
    default: changeme

# Métadonnées (optionnel, informatif)
metadata:
  category: api
  tags:
    - backend
    - production
```

Règles vérifiées par la validation (`validate-profiles.sh` / `validate-profiles.ps1`) :

- `name`, `enabled` (`true` ou `false`) et `docker-compose.image` sont obligatoires ; `docker-compose.container_name` est recommandé et doit être unique entre profils activés ;
- `always_active: false` exige un `docker_profile` ;
- `expose_ports`, s'il est présent, vaut `true` ou `false` ;
- quand `traefik.enabled` vaut `true`, `prefix` est requis et commence par `/`, `docker_port` et `local_port` sont compris entre 1 et 65535.

Dans le service généré, les [variables partagées](#-variables-denvironnement-partagées) sont placées en tête de `environment`, avant celles du profil.

### Routage Traefik et failover

Pour chaque profil dont `traefik.enabled` vaut `true`, la génération crée une route `PathPrefix(<prefix>)` vers un service Traefik en failover :

1. d'abord le service lancé sur le poste, hors Docker, sur le port `local_port` ;
2. à défaut, le conteneur, sur le port `docker_port`.

Les deux cibles sont testées sur `health_path` : un service qui ne répond pas avec succès sur ce chemin n'est pas routé. Ce mécanisme permet de lancer un service en local (débogage) sans arrêter son conteneur.

### Publication des ports (`expose_ports`)

Par défaut, la section `ports:` d'un profil **n'est pas reprise** dans `docker-compose.yml` : le service n'est joignable que via Traefik, ce qui laisse le port local libre pour lancer le même service hors Docker (failover).

Pour publier les ports d'un profil, ajoutez `expose_ports: true` à la racine du profil :

- les ports sont liés à `127.0.0.1` (`"8000:8000"` devient `"127.0.0.1:8000:8000"`) ;
- pour exposer un port sur le réseau local, précisez l'IP : `"0.0.0.0:8000:8000"` ;
- la validation ne signale les conflits de ports qu'entre profils qui les publient.

### Section `secrets:` (recommandée)

Cette section documente explicitement les secrets requis :
- **name** : Nom de la variable (doit correspondre à `${VAR}` dans `environment`)
- **description** : Utilité du secret
- **default** : Valeur par défaut (utilisée lors de la synchronisation)

La commande `sync-secrets` utilise cette section pour mettre à jour automatiquement `secrets.env`.

Si un profil n'a pas de section `secrets:`, `sync-secrets` se rabat sur les variables `${VAR:-défaut}` des entrées de `docker-compose.environment`. Les variables utilisées ailleurs (image, ports) ou dans des commentaires ne sont jamais considérées comme des secrets. Un `${VAR}` sans valeur par défaut n'en est pas un non plus, et une section `secrets:` vide désactive cette détection. La commande `list-secrets` affiche les noms détectés sans SOPS ni déchiffrement (voir [Synchroniser les secrets avec les profils](#synchroniser-les-secrets-avec-les-profils)).

## 🔧 Configuration avancée

### Basculer entre différentes images Docker

Vous pouvez facilement basculer entre différentes versions ou registres d'images pour un service en utilisant des **variables d'environnement**.

#### Méthode 1 : Variables d'environnement dans le profil (Recommandé)

Modifiez votre profil pour utiliser des variables d'environnement (image et tag séparés pour plus de flexibilité) :

```yaml
# profiles/example.yml
docker-compose:
  # Image et tag séparés (recommandé)
  image: ${EXAMPLE_IMAGE:-<id>.dkr.ecr.ca-central-1.amazonaws.com/example}:${EXAMPLE_TAG:-latest}
  container_name: example
  # ... reste de la config
```

Ensuite, basculez entre les images selon vos besoins :

**Avec Just (PowerShell) :**
```powershell
# Utiliser l'image par défaut (production avec tag latest)
just start-profile example

# Utiliser le tag dev
$env:EXAMPLE_TAG="dev"
just start-profile example

# Utiliser une image locale
$env:EXAMPLE_IMAGE="example"
$env:EXAMPLE_TAG="local"
just start-profile example

# Utiliser un autre registre
$env:EXAMPLE_IMAGE="ghcr.io/myorg/example"
$env:EXAMPLE_TAG="v2.0.0"
just start-profile example

# Tester une branche feature
$env:EXAMPLE_TAG="feature-new-api"
just start-profile example
```

**Avec PowerShell :**
```powershell
# Changer uniquement le tag
$env:EXAMPLE_TAG="dev"
.\launch.ps1 -p example

# Changer image et tag
$env:EXAMPLE_IMAGE="example"; $env:EXAMPLE_TAG="local"
.\launch.ps1 -p example
```

**Avec Bash :**
```bash
# Changer uniquement le tag
export EXAMPLE_TAG="dev"
./launch.sh --profile example start

# Changer image et tag en une ligne
EXAMPLE_IMAGE="example" EXAMPLE_TAG="local" ./launch.sh --profile example start
```

#### Méthode 2 : Fichier .env pour une configuration persistante

Créez un fichier `.env` à la racine (non versionné, il est déjà dans `.gitignore`) pour vos variables locales non sensibles ; `.env.example` sert de modèle :

```env
# .env
# Images personnalisées avec tags séparés
EXAMPLE_IMAGE=<id>.dkr.ecr.ca-central-1.amazonaws.com/cgpt-example
EXAMPLE_TAG=dev

FRONTEND_IMAGE=ghcr.io/myorg/frontend
FRONTEND_TAG=feature-xyz

API_IMAGE=myregistry.com/api
API_TAG=v2.0.0

# Registre Docker
DOCKER_REGISTRY=registry.example.com

# Versions spécifiques des dépendances
NODE_VERSION=20-alpine
POSTGRES_VERSION=15.2
```

Les variables seront automatiquement chargées par Docker Compose !

#### Tips et Bonnes Pratiques

1. **Nommage cohérent** : Utilisez `<SERVICE>_IMAGE` (sans tag), `<SERVICE>_TAG`, et optionnellement `<SERVICE>_REGISTRY`
2. **Séparation image/tag** : Préférez séparer l'image et le tag pour faciliter les changements de version
3. **Valeurs par défaut** : Toujours fournir une valeur par défaut avec `${VAR:-default}`
4. **Documentation** : Documentez les variables disponibles dans le profil ou le README
5. **Fichier .env.example** : Créez un exemple pour votre équipe (déjà fourni)
6. **Pas de secrets** : Les secrets vont dans `secrets.env` (chiffré), pas `.env`
7. **Tags explicites** : Évitez `latest` en production, utilisez des versions spécifiques

**Exemples de bons formats :**
```yaml
# ✅ Bon : Image et tag séparés
image: ${SERVICE_IMAGE:-registry.com/service}:${SERVICE_TAG:-v1.0.0}
```

```yaml
# ✅ Bon : Avec registre optionnel
image: ${SERVICE_REGISTRY:-registry.com}/${SERVICE_IMAGE:-service}:${SERVICE_TAG:-v1.0.0}
```

```yaml
# ❌ Moins flexible : Tout dans une variable
image: ${SERVICE_IMAGE:-registry.com/service:v1.0.0}
```

### Configuration globale (config.yml)

Le fichier `config.yml` regroupe la configuration commune à tous les services. Relancez `just generate` après l'avoir modifié.

| Clé | Rôle | Défaut |
|-----|------|--------|
| `namespace` | Nom du projet Docker Compose (clé `name:`) et préfixe des conteneurs Traefik, Dozzle et socket-proxy | `devlocal` |
| `dozzle_enabled` | Active Dozzle (monitoring des logs Docker) | `true` |
| `dozzle_port` | Port local de Dozzle, publié sur `127.0.0.1` | `9999` |
| `registries.ecr.url` | Registre utilisé par `just ecr-login` | — |
| `registries.jfrog.url` | Registre utilisé par `just jfrog-login` | — |
| `aws.profile`, `aws.region` | Voir [Configuration du profil AWS](#configuration-du-profil-aws) | — |
| `shared_env`, `shared_env_config` | Voir [Variables d'environnement partagées](#-variables-denvironnement-partagées) | — |

```yaml
# Dozzle - Monitoring des logs Docker
dozzle_enabled: true   # false pour désactiver Dozzle
dozzle_port: 9999      # Accessible via http://localhost:9999/logs ou http://localhost:8080/logs
```

### Personnalisation Traefik

`traefik/traefik.yml` contient la configuration statique de Traefik (points d'entrée dans le conteneur, dashboard, niveau de log, fournisseurs). Modifiez-le pour :
- Activer HTTPS
- Configurer les certificats
- Changer le niveau de log

Les ports publiés sur l'hôte (`127.0.0.1:8080` pour HTTP, `127.0.0.1:8081` pour le dashboard) sont fixés par les scripts `manage-profiles.*` : modifier `docker-compose.yml` à la main ne suffit pas, le fichier est réécrit à chaque génération. Les middlewares générés (suppression du préfixe) se règlent dans les profils (`strip_prefix`).

## 🛠️ Scripts et commandes disponibles

| Script | Windows | Linux/macOS | Just | Description |
|--------|---------|-------------|------|-------------|
| **Menu interactif** | `.\menu.ps1` | `./menu.sh` | `just menu` | Interface guidée pour toutes les opérations |
| **Lancer services** | `.\launch.ps1` | `./launch.sh start` | `just start` | Orchestration des services Docker, secrets, AWS |
| **Gérer profils** | `.\manage-profiles.ps1` | `./manage-profiles.sh` | `just profiles`, `just generate` | Gestion des profils, génération, `secrets.env` |
| **Valider profils** | `.\validate-profiles.ps1` | `./validate-profiles.sh` | - | Validation des profils |
| **Permissions .sh** | `.\fix-sh-permissions.ps1` | `chmod +x *.sh` | - | Bit exécutable des scripts Bash |

Toutes les commandes, par catégorie (services Docker, profils, secrets, AWS, utilitaires), ainsi que les alias Just et les options du menu, sont dans [CHEATSHEET.md](CHEATSHEET.md).

## 📚 Exemples pratiques

### Exemple 1 : API Backend + Frontend

Créer une stack complète API + Frontend avec routing Traefik :

```powershell
# 1. Ajouter le backend
.\manage-profiles.ps1 -Action add
# Nom: api-backend
# Image: ${API_IMAGE:-myregistry/api}:${API_TAG:-latest}
# Port: 8000 -> 8001
# Traefik: oui, /api, strip_prefix: oui

# 2. Ajouter le frontend
.\manage-profiles.ps1 -Action add
# Nom: frontend
# Image: ${FRONTEND_IMAGE:-myregistry/frontend}:${FRONTEND_TAG:-latest}
# Port: 3000 -> 3001
# Traefik: oui, /, strip_prefix: non

# 3. Configurer les secrets
.\launch.ps1 -c edit-secrets
# Ajouter:
# API_BACKEND_DB_PASSWORD=secret123
# API_BACKEND_API_KEY=mykey456

# 4. Configurer les variables partagées (optionnel)
# Éditer config.yml et ajouter des URLs communes

# 5. Démarrer
.\launch.ps1 -p api-backend,frontend
# OU avec Just:
just start-profile api-backend,frontend

# 6. Tester
# Frontend : http://localhost:8080/
# API : http://localhost:8080/api
# Traefik Dashboard : http://localhost:8081/
# Dozzle (logs) : http://localhost:9999/logs
```

### Exemple 2 : Microservices avec services externes

Déclarez les URLs communes (authentification, paiement, stockage) une seule fois dans `config.yml` : tous vos services y auront automatiquement accès. Les exemples complets sont dans [docs/shared-env-examples.md](docs/shared-env-examples.md).

### Exemple 3 : Basculer entre environnements

Pour passer d'une image locale à une image de staging ou de production, définissez `<SERVICE>_IMAGE` et `<SERVICE>_TAG` dans le shell ou dans `.env` : voir [Basculer entre différentes images Docker](#basculer-entre-différentes-images-docker).

### Exemple 4 : Développement avec hot-reload

Monter un volume local pour le développement :

```yaml
# profiles/mon-service.yml
docker-compose:
  image: node:20-alpine
  volumes:
    - ./src:/app  # Code local monté dans le conteneur
    - /app/node_modules  # node_modules reste dans le conteneur
  environment:
    - NODE_ENV=development
  command: npm run dev
```

Pour conserver des données entre deux démarrages, utiliser un volume nommé
(`node_modules:/app/node_modules`, ou la syntaxe longue `type: volume` avec `source`).
`generate` le déclare automatiquement dans la section `volumes:` de `docker-compose.yml` ;
les dossiers montés (`./`, `/`, `~`, `${VAR}`) et les volumes anonymes ne sont pas déclarés.
Un nom de volume compte au moins deux caractères et ne peut pas être une variable.

### Exemple 4 bis : Outils de build dans Docker (gulp, npm, ...)

Un profil peut servir d'outil : aucun Node.js n'est requis sur le poste.
Un exemple prêt à copier est fourni dans `profiles/gulp.example.yml` (désactivé par défaut, sans port publié) :
copiez-le en `profiles/gulp.yml` et passez `enabled` à `true`. La variante ci-dessous publie en plus le port du serveur de dev.

```yaml
# profiles/gulp.yml
name: gulp
description: "Outils front (gulp) exécutés dans Docker"
enabled: true
always_active: false
docker_profile: tools      # démarré seulement sur demande
expose_ports: true         # publie le port du serveur de dev sur 127.0.0.1

docker-compose:
  image: node:22-alpine
  container_name: gulp
  # Utilisateur courant : les fichiers créés n'appartiennent pas à root (Linux)
  user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
  working_dir: /app
  volumes:
    - ${GULP_SRC:-../mon-projet}:/app   # chemin relatif à dev.local, ou variable dans .env
  environment:
    - HOME=/tmp            # cache npm accessible en écriture pour un utilisateur non root
  ports:
    - "3000:3000"
  command: npx gulp watch  # commande du service longue durée

traefik:
  enabled: false
```

```bash
just generate

# Commandes ponctuelles : conteneur créé puis supprimé, secrets SOPS chargés
just run gulp npm install
just run gulp npx gulp build

# Service longue durée (watch) avec le port 3000 publié
just start-profile tools
```

- `HOST_UID` et `HOST_GID` sont exportés par `launch.sh`.
- `run` ne publie pas les ports du service ; utilisez le profil démarré pour un serveur de dev.
- Sous PowerShell, placez `--` avant la commande : `.\launch.ps1 run gulp -- npx gulp build --production`.

### Exemple 5 : Service avec dépendances

Service nécessitant une base de données :

```yaml
# profiles/api-with-db.yml
docker-compose:
  image: myapi:latest
  depends_on:
    postgres:
      condition: service_healthy
  environment:
    - DATABASE_URL=postgresql://user:${DB_PASSWORD}@postgres:5432/mydb

# Ajouter aussi postgres dans profiles/postgres.yml
```

## ☁️ AWS et Docker Registry

Dev.Local supporte l'authentification AWS SSO et les connexions aux registres Docker privés.

| Action | Just | Windows | Linux/macOS |
|--------|------|---------|-------------|
| Connexion AWS SSO (avant d'utiliser des images AWS ECR) | `just aws-sso` | `.\launch.ps1 sso` | `./launch.sh sso` |
| Vérifier l'identité AWS utilisée | `just aws-id` | `.\launch.ps1 id` | `./launch.sh id` |
| Authentifier Docker auprès d'AWS ECR (une fois connecté à AWS SSO) | `just ecr-login` | `.\launch.ps1 ecr-login` | `./launch.sh ecr-login` |
| Authentifier Docker auprès de JFrog | `just jfrog-login` | `.\launch.ps1 jfrog-login` | `./launch.sh jfrog-login` |

Les adresses des registres viennent de `registries.ecr.url` et `registries.jfrog.url` dans `config.yml`.

### Workflow complet avec AWS

```bash
# 1. Se connecter à AWS SSO
just aws-sso

# 2. Vérifier l'identité (optionnel)
just aws-id

# 3. Se connecter à Docker ECR
just ecr-login

# 4. Démarrer les services avec images ECR
just start
```

### Configuration du profil AWS

Le profil AWS (`just aws-sso`, `just aws-id`, `just ecr-login`) et la région (`just ecr-login`) se règlent dans `config.yml` :

```yaml
aws:
  profile: ESG-DV-PowerUser-SSO
  region: ca-central-1
```

Sans cette section, ces deux valeurs sont utilisées par défaut. La variable d'environnement `AWS_PROFILE`, si elle est définie, a priorité sur `aws.profile`.

Les trois commandes passent toujours `--profile` à AWS CLI : les identifiants par défaut (`[default]` de `~/.aws/credentials`) ne sont donc plus utilisés implicitement. Pour vous en servir, indiquez `profile: default` dans `config.yml` ou exportez `AWS_PROFILE=default`.

## 🐧 Support Linux/macOS

Chaque script PowerShell a son équivalent Bash, qui génère la même configuration :

- `menu.sh` - Menu interactif (équivalent de menu.ps1)
- `manage-profiles.sh` - Gestion des profils (équivalent de manage-profiles.ps1)
- `launch.sh` - Orchestration des services (équivalent de launch.ps1)
- `validate-profiles.sh` - Validation des profils (équivalent de validate-profiles.ps1)

```bash
# Rendre les scripts exécutables (une seule fois)
chmod +x *.sh
```

Les particularités de Linux/macOS (différences avec PowerShell, compatibilité, terminal, migration depuis Windows) sont décrites dans [BASH_README.md](BASH_README.md).

## 📚 Documentation Complète

Chaque document a un rôle précis ; une information n'est décrite qu'à un seul endroit.

| Document | Rôle |
|----------|------|
| [README.md](README.md) | Référence complète : concepts, configuration, comportement |
| [QUICKSTART.md](QUICKSTART.md) | Premier démarrage en quelques minutes (parcours minimal) |
| [CHEATSHEET.md](CHEATSHEET.md) | Aide-mémoire : toutes les commandes, sans explications |
| [BASH_README.md](BASH_README.md) | Particularités Linux/macOS des scripts Bash |
| [docs/shared-env-guide.md](docs/shared-env-guide.md) | Référence des variables d'environnement partagées |
| [docs/shared-env-examples.md](docs/shared-env-examples.md) | Exemples complets de variables partagées |
| [docs/sops_age_guide.md](docs/sops_age_guide.md) | Configurer SOPS avec une clé Age |
| [docs/gitattributes-guide.md](docs/gitattributes-guide.md) | Fins de ligne et `.gitattributes` |

## 🔒 Sécurité

- ✅ Secrets chiffrés avec SOPS (AWS KMS ou Age)
- ✅ `.gitignore` configuré pour exclure les secrets en clair
- ✅ Validation automatique de la configuration SOPS
- ✅ Aucun secret en dur dans les fichiers versionnés
- ✅ Traefik et Dozzle publiés uniquement sur `127.0.0.1`
- ✅ Ports des profils non publiés par défaut, et liés à `127.0.0.1` quand ils le sont (voir [Publication des ports](#publication-des-ports-expose_ports))
- ✅ Socket Docker isolé : seul le service `socket-proxy` le monte ; Traefik et Dozzle passent par lui en lecture seule, sur un réseau interne inaccessible aux services des profils

## 🌍 Compatibilité Multiplateforme

| Fonctionnalité | Windows | Linux | macOS | WSL2 |
|----------------|---------|-------|-------|------|
| Menu interactif | ✅ | ✅ | ✅ | ✅ |
| Gestion profils | ✅ | ✅ | ✅ | ✅ |
| SOPS secrets | ✅ | ✅ | ✅ | ✅ |
| Docker profiles | ✅ | ✅ | ✅ | ✅ |
| Traefik | ✅ | ✅ | ✅ | ✅ |
| AWS CLI | ✅ | ✅ | ✅ | ✅ |

**Fichiers 100% compatibles** entre plateformes :
- `profiles/*.yml`
- `docker-compose.yml`
- `traefik/dynamic.yml`
- `secrets.env` (chiffré SOPS)
- `config.yml`

## 🔧 Développement

### Tests et analyse statique

```bash
just test   # tests des scripts Bash (génération, validation)
just lint   # ShellCheck via Docker
```

- `tests/run-tests.sh` copie les scripts et les fixtures de `tests/fixtures/` dans un répertoire temporaire, génère `docker-compose.yml` et `traefik/dynamic.yml`, puis les compare aux fichiers de `tests/expected/`. Il vérifie aussi que chaque profil de `tests/fixtures/invalid/` est rejeté par la validation.
- Après un changement volontaire de la génération, mettez à jour les fichiers attendus avec `tests/run-tests.sh --update` et relisez le diff avant de commiter.
- `tests/compare-shells.sh` exécute `manage-profiles.ps1` et `validate-profiles.ps1` sur les mêmes fixtures, puis vérifie que la génération PowerShell produit la même configuration que `manage-profiles.sh` (prérequis : `pwsh` et le module `powershell-yaml`).

La CI (`.github/workflows/ci.yml`) exécute ces vérifications sur chaque pull request, avec yq local puis via Docker, ainsi que PSScriptAnalyzer. Bash et PowerShell doivent générer la même configuration.

### Conventional Commits

**TOUS les commits doivent respecter la spécification [Conventional Commits](https://www.conventionalcommits.org/).**

#### Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

#### Types de commits

- **feat**: Nouvelle fonctionnalité
- **fix**: Correction de bug
- **docs**: Modifications de documentation uniquement
- **style**: Changements de style (formatage, point-virgules manquants, etc.)
- **refactor**: Refactorisation sans ajout de fonctionnalité ni correction de bug
- **perf**: Amélioration des performances
- **test**: Ajout ou modification de tests
- **build**: Modifications du système de build ou des dépendances
- **ci**: Modifications de la configuration CI/CD
- **chore**: Autres modifications (maintenance, configuration, etc.)

#### Exemples

```bash
feat(profiles): add support for custom healthcheck configuration
fix(traefik): correct routing priority for dynamic routes
docs(readme): update installation instructions for Linux
refactor(launch): simplify service orchestration logic
chore(deps): update Docker Compose to v2.24.0
```

#### Breaking Changes

Pour les changements incompatibles, ajouter `BREAKING CHANGE:` dans le footer ou utiliser `!` après le type :

```
feat(api)!: remove deprecated v1 profile format

BREAKING CHANGE: Profile format v1 is no longer supported.
Users must migrate to v2 format using the migration script.
```

## 🤝 Contribution

### Workflow de contribution

1. Créer un nouveau profil dans `profiles/`
2. Tester :
   - Windows : `.\launch.ps1 -p mon-nouveau-service`
   - Linux : `./launch.sh --profile mon-nouveau-service start`
3. **Important** : Les secrets doivent TOUJOURS être placés dans `secrets.env` (chiffré avec SOPS), jamais dans les profils ou autres fichiers versionnés
4. Committer le profil en respectant le format Conventional Commits

## 🔧 Dépannage

Commencez par le menu (`just menu`) : chaque option affiche la commande exécutée. Les commandes de diagnostic générales sont :

```bash
docker compose config --quiet        # valider docker-compose.yml (aucune sortie = OK)
./validate-profiles.sh               # valider les profils (.\validate-profiles.ps1 sous Windows)
docker compose logs -f               # logs de tous les services
docker compose logs -f service-name  # logs d'un service
sops -d secrets.env                  # tester le déchiffrement SOPS
```

### Erreur : "command not found" ou "Permission denied"

Sous Linux/macOS, ajoutez le bit exécutable : `chmod +x *.sh`. Sous Windows, voir [Développeurs Windows : Permissions des fichiers .sh](#-développeurs-windows--permissions-des-fichiers-sh).

### Erreur : "bad interpreter: /bin/bash^M"

Le fichier utilise des fins de ligne CRLF au lieu de LF.

```bash
# Solution 1 : Utiliser dos2unix
dos2unix launch.sh

# Solution 2 : Avec sed
sed -i 's/\r$//' launch.sh

# Prévention : .gitattributes est configuré pour forcer LF
git check-attr -a launch.sh
```

Voir [docs/gitattributes-guide.md](docs/gitattributes-guide.md).

### Erreur : "SOPS n'est pas installé"

Voir [Installation de SOPS](#installation-de-sops).

### SOPS ne fonctionne pas

Messages typiques : « .sops.yaml non trouvé », « Aucune méthode de chiffrement configurée », « no key found », échec du déchiffrement.

```powershell
# Vérifier que SOPS est installé
sops --version

# Vérifier la config : une ligne kms: ou age: doit être active
Get-Content .sops.yaml          # cat .sops.yaml sous Bash

# Pour Age, vérifier la clé
$env:SOPS_AGE_KEY_FILE          # echo $SOPS_AGE_KEY_FILE sous Bash
Get-Content $env:SOPS_AGE_KEY_FILE

# Pour KMS, vérifier AWS
.\launch.ps1 -c id              # ./launch.sh id sous Bash
```

Si `.sops.yaml` n'existe pas ou ne contient aucune clé active, reprenez [Configuration SOPS (.sops.yaml)](#configuration-sops-sopsyaml). Pour Age, voir aussi le dépannage de [docs/sops_age_guide.md](docs/sops_age_guide.md#5-dépannage).

### Les secrets ne se chargent pas

```powershell
# Vérifier que secrets.env existe
Test-Path secrets.env           # ls secrets.env sous Bash

# Tester le déchiffrement
sops -d secrets.env

# PowerShell : vérifier une variable après un démarrage
$env:MON_SECRET
```

Sous Bash, les secrets ne sont exportés que pour la durée de `launch.sh` : ils n'apparaissent pas dans votre shell. Vérifiez-les dans le conteneur avec `docker compose exec <service> env`.

### Erreur : "Docker Compose v2+ requis"

```bash
# Vérifier la version
docker compose version
```

Si vous avez docker-compose v1, installez la v2 : https://docs.docker.com/compose/install/

### Docker Compose ne trouve pas les services

```powershell
# Regénérer docker-compose.yml
.\manage-profiles.ps1 -Action generate    # ou just generate

# Vérifier le fichier
Get-Content docker-compose.yml
```

Un profil dont `enabled` vaut `false` n'est pas généré, et un service rattaché à un profil Docker ne démarre qu'avec `just start-profile <profil>` (voir [Utilisation](#-utilisation)).

### Un service ne répond pas sur son port

Les ports d'un profil ne sont publiés que si `expose_ports: true` (voir [Publication des ports](#publication-des-ports-expose_ports)) ; sinon, passez par Traefik : `http://localhost:8080/<prefix>`. Si Traefik ne route pas le service, vérifiez que celui-ci répond sur `health_path` (voir [Routage Traefik et failover](#routage-traefik-et-failover)).

### yq : échec du téléchargement de l'image

Sans `yq` local, les scripts Bash téléchargent l'image `mikefarah/yq` au premier lancement. Hors ligne, installez `yq` : voir [(Optionnel) Installation de yq](#optionnel-installation-de-yq-recommandé).

### Erreurs d'encodage UTF-8 (Linux/macOS)

```bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

## 🔧 Développeurs Windows : Permissions des fichiers .sh

Si vous travaillez sur Windows et contribuez au projet, assurez-vous que les fichiers `.sh` ont le bit exécutable pour les utilisateurs Linux/macOS.

### Vérification automatique

Utilisez le script fourni pour vérifier et corriger les permissions :

```powershell
.\fix-sh-permissions.ps1
```

Ce script :
- ✅ Vérifie tous les fichiers `.sh` du projet
- ✅ Affiche leur statut (exécutable ou non)
- ✅ Corrige automatiquement les permissions si nécessaire

### Correction manuelle

```powershell
# Rendre un fichier .sh exécutable
git update-index --chmod=+x fichier.sh

# Vérifier les permissions
git ls-files -s *.sh
# 100755 = exécutable ✅
# 100644 = non exécutable ❌
```

### Automatisation avec .gitattributes

Le fichier `.gitattributes` est déjà configuré pour :
- Assurer que les `.sh` utilisent LF (fins de ligne Unix)
- Normaliser les fins de ligne selon le type de fichier

Le détail des règles est dans [docs/gitattributes-guide.md](docs/gitattributes-guide.md).

**Important :** Après modification des permissions, committez les changements :
```powershell
git add <fichiers>
git commit -m "fix(scripts): add executable bit to .sh files"
```

## 📄 Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

Copyright (c) 2025 Dev.Local Contributors
