# 🔄 Variables d'Environnement Partagées

> **Rôle de ce document :** référence des variables d'environnement partagées (clés de `config.yml`, règles d'injection, bonnes pratiques, FAQ). Les exemples complets sont dans [shared-env-examples.md](shared-env-examples.md) ; la documentation générale est dans le [README](../README.md).

## 📋 Vue d'ensemble

Le système de variables d'environnement partagées permet de définir des variables communes qui seront automatiquement injectées dans tous vos services Docker. Ceci est particulièrement utile pour :

- 🌐 **URLs de services externes** - APIs, services d'authentification, passerelles
- 🔧 **Configuration commune** - Log level, timezone, environnement
- 📊 **Paramètres partagés** - Taille de pool, timeouts, limites
- 🔗 **Référencement de variables** - Renommer ou adapter des variables existantes pour un service spécifique

## 🎯 Configuration

### Fichier `config.yml`

Les variables partagées sont définies dans `config.yml` sous la section `shared_env` :

```yaml
shared_env:
  # Variables globales pour tous les services
  global:
    - LOG_LEVEL=info
    - NODE_ENV=development
    - TZ=America/Toronto
  
  # Variables pour des services externes
  external_services:
    - API_GATEWAY_URL=https://api.example.com
    - AUTH_SERVICE_URL=https://auth.example.com
    - MESSAGING_SERVICE_URL=https://messaging.example.com
  
  # Variables personnalisées
  custom:
    - DATABASE_POOL_SIZE=10
    - CACHE_TTL=3600
```

### Configuration de l'injection

```yaml
shared_env_config:
  # Activer/désactiver l'injection automatique
  enabled: true
  
  # Groupes injectés automatiquement dans TOUS les services
  auto_inject:
    - global
    - external_services
  
  # Exclure certains services de l'injection automatique
  exclude_services:
    - traefik
    - dozzle
  
  # Groupes spécifiques pour certains services
  service_specific:
    mon-api:
      - custom
    mon-frontend:
      - custom
```

Règles appliquées à la génération :

| Clé | Effet |
|-----|-------|
| `enabled` | `false` désactive toute injection (défaut : `true`) |
| `auto_inject` | Groupes de `shared_env` injectés dans chaque service issu d'un profil |
| `service_specific` | Groupes ajoutés, après ceux de `auto_inject`, au service dont le `name` de profil correspond |
| `exclude_services` | Services (par `name` de profil) qui ne reçoivent aucune variable partagée, y compris celles de `service_specific` |

Les services intégrés (Traefik, Dozzle, socket-proxy) ne reçoivent jamais de variables partagées.

## 🔗 Référencement de variables existantes

### Utiliser une variable déjà définie

Une valeur peut contenir une référence `${VAR}` ou `${VAR:-défaut}`. Elle est recopiée telle quelle dans `docker-compose.yml`, puis résolue par Docker Compose au démarrage.

**Important :** Docker Compose résout `${VAR}` à partir de son propre environnement — le shell, le fichier `.env` et les secrets de `secrets.env` chargés par les scripts de lancement — et **non** à partir des autres variables de la liste `environment`. Une variable définie uniquement dans `shared_env` ne peut donc pas être référencée par une autre variable partagée : la référence serait remplacée par une chaîne vide, avec un avertissement de Docker Compose.

#### Exemple : Renommer une variable pour un service

```env
# .env
API_GATEWAY_URL=https://api.example.com
AUTH_SERVICE_URL=https://auth.example.com
```

```yaml
shared_env:
  # Variables spécifiques au service 'demo'
  demo_only:
    - DEMO_ONLY_VAR=demo-only-value
    # Référencer une variable de .env sous un autre nom
    - DEMO_API_GATEWAY_URL=${API_GATEWAY_URL}
    # Ou avec une valeur de fallback
    - DEMO_AUTH_URL=${AUTH_SERVICE_URL:-https://auth.fallback.com}

shared_env_config:
  service_specific:
    demo:
      - demo_only
```

**Résultat dans docker-compose.yml :**

```yaml
services:
  demo:
    environment:
      # Variables partagées (depuis config.yml)
      - DEMO_ONLY_VAR=demo-only-value
      - DEMO_API_GATEWAY_URL=${API_GATEWAY_URL}
      - DEMO_AUTH_URL=${AUTH_SERVICE_URL:-https://auth.fallback.com}
      # Variables exclusives du service
      - ENVIRONMENT=docker-compose
```

Docker Compose remplacera `${API_GATEWAY_URL}` par la valeur définie dans `.env` au démarrage du conteneur.

#### Cas d'usage typiques

Dans chaque cas, les variables référencées (`API_GATEWAY_URL`, `DATABASE_HOST`, ...) doivent être définies dans `.env`, le shell ou `secrets.env`.

**1. Adaptation d'URL pour un service legacy :**
```yaml
shared_env:
  legacy_adapter:
    # Le service legacy attend LEGACY_API_URL au lieu de API_GATEWAY_URL
    - LEGACY_API_URL=${API_GATEWAY_URL}
    - LEGACY_DB_HOST=${DATABASE_HOST}
```

**2. Préfixage pour isolation :**
```yaml
shared_env:
  service_a_config:
    # Préfixer toutes les variables pour ce service
    - SERVICE_A_API=${API_GATEWAY_URL}
    - SERVICE_A_AUTH=${AUTH_SERVICE_URL}
```

**3. Override conditionnel avec fallback :**
```yaml
shared_env:
  dev_overrides:
    # Utiliser une variable d'environnement système si définie, sinon une autre
    - MY_API_URL=${OVERRIDE_API_URL:-${API_GATEWAY_URL}}
```

**4. Composition de valeurs :**
```yaml
shared_env:
  composed:
    # Créer une nouvelle variable à partir d'une existante
    - FULL_API_URL=${API_GATEWAY_URL}/v1/api
    - HEALTH_CHECK_URL=${API_GATEWAY_URL}/health
```

### ⚠️ Notes importantes

1. **Ordre d'injection** : Les variables partagées sont injectées AVANT les variables du profil
2. **Résolution Docker Compose** : La substitution `${VAR}` est effectuée par Docker Compose au runtime, à partir de son environnement (shell, `.env`, secrets chargés)
3. **Commentaires** : Les commentaires entre items de liste sont supportés et ignorés lors du parsing

### 💡 Astuce : Voir les valeurs résolues

Pour voir les valeurs finales après substitution :

```bash
# Afficher la configuration résolue d'un service
docker compose config demo

# Ou voir toutes les variables d'environnement dans le conteneur
docker compose exec demo env | sort
```

## 🚀 Utilisation

### 1. Définir des variables partagées

Éditez `config.yml` et ajoutez vos variables dans un groupe :

```yaml
shared_env:
  mon_groupe:
    - MA_VARIABLE=ma_valeur
    - AUTRE_VARIABLE=autre_valeur
```

### 2. Configurer l'injection automatique

Ajoutez votre groupe aux `auto_inject` pour l'appliquer à tous les services :

```yaml
shared_env_config:
  auto_inject:
    - global
    - mon_groupe
```

### 3. Regénérer docker-compose.yml

```powershell
.\manage-profiles.ps1 -Action generate     # ./manage-profiles.sh generate, ou just generate
```

Le script affichera le nombre de variables partagées injectées dans chaque service :

```
✅ Ajout : mon-service
   📌 6 variable(s) partagée(s)
```

Relancez ensuite les services (`just restart`). La séquence complète de commandes est dans [CHEATSHEET.md](../CHEATSHEET.md#-workflows-courants).

## 📝 Exemples d'utilisation

Les exemples complets (URLs de services externes, configuration par environnement, variables spécifiques à certains services, exclusion de services, feature flags, service discovery) sont regroupés dans [shared-env-examples.md](shared-env-examples.md).

## 🔍 Vérification

### Voir les variables injectées

Après génération, vérifiez `docker-compose.yml` :

```yaml
services:
  mon-service:
    image: mon-image
    environment:
      # Variables partagées (depuis config.yml)
      - LOG_LEVEL=info
      - NODE_ENV=development
      - API_GATEWAY_URL=https://api.example.com
      # Variables exclusives du service
      - SERVICE_PORT=8000
```

```powershell
Get-Content docker-compose.yml | Select-String "Variables partagées" -Context 0,10
```

```bash
grep -A 10 "Variables partagées" docker-compose.yml
```

### Tester dans le conteneur

```bash
docker compose exec mon-service env | grep API_GATEWAY_URL
```

### Ordre de priorité

Quand une variable est définie à la fois dans `config.yml` et dans le profil, la valeur du profil l'emporte : elle est écrite après la valeur partagée, et Docker Compose retient la dernière.

```bash
# 1. config.yml shared_env → LOG_LEVEL=info
# 2. profiles/api.yml      → LOG_LEVEL=debug (écrase)
# Résultat final : LOG_LEVEL=debug
```

Une variable du shell ne remplace pas une valeur écrite en dur : `LOG_LEVEL=error docker compose up api` laisse `LOG_LEVEL=debug`. Pour qu'une valeur soit modifiable depuis le shell ou `.env`, déclarez-la avec une référence : `LOG_LEVEL=${LOG_LEVEL:-debug}`.

## 🎨 Bonnes pratiques

### ✅ À faire

1. **Grouper logiquement** - Créez des groupes cohérents (auth, database, logging, etc.)
   ```yaml
   shared_env:
     auth:
       - AUTH_URL=...
       - AUTH_TIMEOUT=...
     
     storage:
       - S3_BUCKET=...
       - S3_REGION=...
   ```
2. **Nommer clairement**
   ```yaml
   # ✅ Bon
   - API_GATEWAY_URL=...
   - AUTH_SERVICE_URL=...
   
   # ❌ Mauvais
   - URL1=...
   - SVC=...
   ```
3. **Documenter** - Ajoutez des commentaires dans `config.yml`
4. **Utiliser des valeurs par défaut** - Raisonnables pour les environnements de développement (`LOG_LEVEL=debug`, `ENABLE_CORS=true`)
5. **Centraliser** - Toutes les URLs externes dans un seul groupe
6. **Versionner** - `config.yml` doit être dans Git

### ❌ À éviter

1. **Secrets** - NE JAMAIS mettre de secrets ici ! Utilisez `secrets.env` avec SOPS
2. **Mélanger** - Ne pas mélanger config dev et prod dans le même groupe
3. **Trop de variables** - Si > 20 variables dans un groupe (en particulier `global`), créer des sous-groupes
   ```yaml
   # ❌ Trop de variables dans global
   global:
     - VAR1=...
     - VAR2=...
     # ... 50 variables ...
   
   # ✅ Mieux : grouper
   database:
     - DB_VAR1=...
     - DB_VAR2=...
   ```
4. **Hardcoder les IPs** - Utiliser des noms DNS ou des variables d'environnement

## 🔐 Secrets vs Variables partagées

| Type | Utilisation | Fichier | Chiffré |
|------|-------------|---------|---------|
| **Variables partagées** | Configuration non-sensible | `config.yml` | ❌ Non |
| **Secrets** | Mots de passe, tokens, clés | `secrets.env` | ✅ Oui (SOPS) |

### Exemple

```yaml
# ✅ BON - config.yml (variables partagées)
shared_env:
  services:
    - AUTH_SERVICE_URL=https://auth.example.com
    - LOG_LEVEL=info

# ❌ MAUVAIS - NE PAS mettre de secrets ici !
shared_env:
  bad_practice:
    - DATABASE_PASSWORD=supersecret123  # ❌ Utiliser secrets.env !
```

La gestion des secrets est décrite dans le [README](../README.md#-gestion-des-secrets-avec-sops).

## ❓ FAQ

### Q: Les variables partagées écrasent-elles les variables spécifiques ?

**R:** Non ! Les variables du profil sont ajoutées APRÈS les variables partagées. Si une variable existe dans les deux, la version du profil prend la priorité.

### Q: Puis-je désactiver temporairement l'injection ?

**R:** Oui, mettez `enabled: false` dans `shared_env_config`.

### Q: Comment voir quelles variables sont injectées ?

**R:** Lors de la génération, le script affiche : `📌 X variable(s) partagée(s)` pour chaque service.

### Q: Puis-je utiliser des variables dans les valeurs ?

**R:** Oui, avec `${VAR}` ou `${VAR:-default}`, à condition que la variable référencée soit définie dans `.env`, le shell ou `secrets.env` — pas seulement dans `shared_env`. Voir [Référencement de variables existantes](#-référencement-de-variables-existantes).

### Q: Les variables partagées sont-elles disponibles au build ?

**R:** Non, seulement au runtime. Pour le build, utilisez `args:` dans votre profil.

## 🔗 Ressources

- [Docker Compose - Environment Variables](https://docs.docker.com/compose/environment-variables/)
- [12 Factor App - Config](https://12factor.net/config)
- [Exemples pratiques](shared-env-examples.md)
- [Documentation Dev.Local - README.md](../README.md)

## 📝 Historique

- 2025-01-03 : Création de la fonctionnalité de variables partagées
- Support de groupes multiples
- Support d'injection sélective par service
- Support d'exclusion de services
