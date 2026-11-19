# 📋 Dev.Local 2.0 - Aide-Mémoire Rapide

> **Rôle de ce document :** retrouver une commande. Tableaux et commandes en une ligne, sans explications : le comportement de chaque commande est décrit dans [README.md](README.md), le premier démarrage dans [QUICKSTART.md](QUICKSTART.md).

## 🚀 Commandes Essentielles

### Services Docker

| Action | Just | PowerShell | Bash |
|--------|------|------------|------|
| Démarrer (services toujours actifs) | `just start` | `.\launch.ps1` | `./launch.sh start` |
| Démarrer des profils | `just start-profile api,ui` | `.\launch.ps1 -p api,ui` | `./launch.sh --profile api,ui start` |
| Arrêter | `just stop` | `.\launch.ps1 stop` | `./launch.sh stop` |
| Redémarrer (recréer) | `just restart` | `.\launch.ps1 recreate` | `./launch.sh recreate` |
| Statut | `just ps` | `.\launch.ps1 ps` | `./launch.sh ps` |
| Logs tous | `just logs` | `.\launch.ps1 logs` | `./launch.sh logs` |
| Logs service | `just logs api` | `.\launch.ps1 logs -service api` | `./launch.sh logs api` |
| Commande ponctuelle | `just run gulp npx gulp build` | `.\launch.ps1 run gulp -- npx gulp build` | `./launch.sh run gulp npx gulp build` |
| Nettoyer (containers et volumes) | `just clean` | `docker compose --profile "*" down -v --remove-orphans` | `docker compose --profile "*" down -v --remove-orphans` |

### Profils de services

| Action | Just | PowerShell | Bash |
|--------|------|------------|------|
| Lister | `just profiles` | `.\manage-profiles.ps1 -Action list` | `./manage-profiles.sh list` |
| Ajouter | - | `.\manage-profiles.ps1 -Action add` | `./manage-profiles.sh add` |
| Générer compose et Traefik | `just generate` | `.\manage-profiles.ps1 -Action generate` | `./manage-profiles.sh generate` |
| Valider les profils | - | `.\validate-profiles.ps1` | `./validate-profiles.sh` |
| Valider docker-compose.yml | `just validate` | `docker compose config --quiet` | `docker compose config --quiet` |

### Secrets (SOPS)

| Action | Just | PowerShell | Bash |
|--------|------|------------|------|
| Initialiser | - | `.\manage-profiles.ps1 -Action init-secrets` | `./manage-profiles.sh init-secrets` |
| Éditer | `just secrets-edit` | `.\launch.ps1 -c edit-secrets` | `./launch.sh edit-secrets` |
| Voir | `just secrets-view` | `.\launch.ps1 -c view-secrets` | `./launch.sh view-secrets` |
| Synchroniser avec les profils | - | `.\manage-profiles.ps1 -Action sync-secrets` | `./manage-profiles.sh sync-secrets` |
| Lister les secrets détectés | - | `.\manage-profiles.ps1 -Action list-secrets` | `./manage-profiles.sh list-secrets` |

### AWS et Docker Registry

| Action | Just | PowerShell | Bash |
|--------|------|------------|------|
| AWS SSO Login | `just aws-sso` | `.\launch.ps1 -c sso` | `./launch.sh sso` |
| AWS Identity | `just aws-id` | `.\launch.ps1 -c id` | `./launch.sh id` |
| ECR Login | `just ecr-login` | `.\launch.ps1 -c ecr-login` | `./launch.sh ecr-login` |
| JFrog Login | `just jfrog-login` | `.\launch.ps1 -c jfrog-login` | `./launch.sh jfrog-login` |

### Utilitaires

| Action | Just | PowerShell | Bash |
|--------|------|------------|------|
| Menu interactif | `just menu` | `.\menu.ps1` | `./menu.sh` |
| Config finale | `just config` | `docker compose config` | `docker compose config` |
| Lister les recettes Just | `just --list` | - | - |
| Vérifier perms .sh | - | `.\fix-sh-permissions.ps1` | `chmod +x *.sh` |
| Tests des scripts Bash | `just test` | - | `tests/run-tests.sh` |
| ShellCheck (via Docker) | `just lint` | - | - |

### Raccourcis Just (aliases)

| Alias | Recette |
|-------|---------|
| `just s`, `just up` | `start` |
| `just st`, `just down` | `stop` |
| `just r` | `restart` |
| `just p` | `ps` |
| `just g` | `generate` |
| `just v` | `validate` |

## 📋 Options du Menu

| # | Action | Équivalent CLI |
|---|--------|---------------|
| **1** | Démarrer tous les services (tous les profils activés) | `./launch.sh --profile X,Y up` |
| **m** | Démarrer services minimums (sans profils) | `./launch.sh up` |
| **2** | Profils spécifiques | `./launch.sh --profile X,Y up` |
| **3** | Recréer | `./launch.sh recreate` |
| **4** | Arrêter | `./launch.sh down` |
| **5** | Lister containers | `docker compose ps` |
| **6** | Ajouter profil | `./manage-profiles.sh add` |
| **7** | Lister profils | `./manage-profiles.sh list` |
| **8** | Regénérer compose | `./manage-profiles.sh generate` |
| **9** | Valider les profils | `./validate-profiles.sh` |
| **10** | Éditer secrets | `./launch.sh edit-secrets` |
| **11** | Voir secrets | `./launch.sh view-secrets` |
| **12** | Initialiser secrets | `./manage-profiles.sh init-secrets` |
| **13** | Synchroniser secrets | `./manage-profiles.sh sync-secrets` |
| **14** | AWS SSO | `./launch.sh sso` |
| **15** | AWS Identity | `./launch.sh id` |
| **16** | ECR Login | `./launch.sh ecr-login` |
| **17** | Ouvrir README.md | - |
| **0/q** | Quitter | - |

## 🌐 URLs locales

| Service | URL |
|---------|-----|
| Vos services (via Traefik) | `http://localhost:8080/<prefix>` |
| Traefik Dashboard | `http://localhost:8081/` |
| Dozzle (logs) | `http://localhost:9999/logs` ou `http://localhost:8080/logs` |

## 🎯 Workflows Courants

### 1️⃣ Premier Démarrage

Voir [QUICKSTART.md](QUICKSTART.md).

### 2️⃣ Ajouter un Service

```bash
./manage-profiles.sh add                    # 1. Créer le profil (questions interactives)
./manage-profiles.sh sync-secrets           # 2. Synchroniser secrets
./launch.sh edit-secrets                    # 3. Renseigner les valeurs
./manage-profiles.sh generate               # 4. Regénérer
./launch.sh --profile nom-service start     # 5. Démarrer le nouveau service
```

```powershell
.\manage-profiles.ps1 -Action add
.\manage-profiles.ps1 -Action sync-secrets
.\launch.ps1 -c edit-secrets
.\manage-profiles.ps1 -Action generate
.\launch.ps1 -p nouveau-service
```

### 3️⃣ Modifier un Profil

```bash
vi profiles/mon-service.yml         # 1. Éditer manuellement
./manage-profiles.sh generate       # 2. Regénérer compose
docker compose config --quiet       # 3. Valider
./launch.sh recreate                # 4. Redémarrer
```

### 4️⃣ Gérer les Secrets

```bash
./manage-profiles.sh sync-secrets   # Voir (et ajouter) les secrets manquants
./launch.sh edit-secrets            # Éditer (ou directement : sops secrets.env)
./launch.sh view-secrets            # Vérifier
./launch.sh recreate                # Appliquer
```

### 5️⃣ Déploiement AWS

```bash
./launch.sh sso          # 1. SSO
./launch.sh id           # 2. Vérifier
./launch.sh ecr-login    # 3. ECR
./launch.sh              # 4. Démarrer
```

### 6️⃣ Développement quotidien

```powershell
just start                     # Matin - Démarrer
$env:API_TAG="feature-xyz"     # Changer de branche/version (export API_TAG=feature-xyz sous Bash)
just restart
just logs api                  # Voir les logs
just stop                      # Soir - Arrêter
```

### 7️⃣ Modifier les variables partagées

```powershell
notepad config.yml                                                  # 1. Éditer (nano config.yml sous Bash)
.\manage-profiles.ps1 -Action generate                              # 2. Regénérer
Get-Content docker-compose.yml | Select-String "Variables partagées"  # 3. Vérifier l'injection
.\launch.ps1 -c recreate                                            # 4. Relancer
```

### 8️⃣ Partager avec l'équipe

```powershell
# 1. Commiter les profils (sans secrets!)
git add profiles/nouveau-service.yml
git commit -m "feat(profiles): add nouveau-service profile"

# 2. Les secrets requis sont documentés dans le profil (section secrets:)

# 3. L'équipe renseigne ses valeurs avec :
.\manage-profiles.ps1 -Action sync-secrets
.\launch.ps1 -c edit-secrets
```

## 🐳 Docker Compose Avancé

| Action | Commande |
|--------|----------|
| Voir la configuration finale | `docker compose config` |
| Démarrer un seul service | `docker compose up -d service-name` |
| Logs en temps réel | `docker compose logs -f` |
| Logs d'un service | `docker compose logs -f service-name` |
| Rebuild un service | `docker compose up -d --build service-name` |
| Forcer recréation | `docker compose up -d --force-recreate` |
| Variables d'un conteneur | `docker compose exec service-name env` |
| Nettoyer tout (containers et volumes) | `docker compose --profile "*" down -v --remove-orphans` |
| Supprimer toutes les images Docker inutilisées du poste | `docker system prune -a` |

Ces commandes n'ont pas accès aux secrets SOPS : seuls les scripts `launch.*` les chargent.

## 📊 Variables d'Environnement

| Variable | Effet |
|----------|-------|
| `COMPOSE_PROFILES=api,ui` | Profils actifs pour les commandes `docker compose` directes |
| `COMPOSE_FILE=docker-compose.custom.yml` | Fichier de projet custom |
| `COMPOSE_PROJECT_NAME=devlocal` | Nom du projet |
| `SOPS_AGE_KEY_FILE=/path/to/keys.txt` | Clé Age custom |
| `AWS_PROFILE=<profil>` | Profil AWS, prioritaire sur `aws.profile` de `config.yml` |
| `YQ_IMAGE=mikefarah/yq:<version>` | Image Docker de `yq` utilisée par les scripts Bash |
| `HOST_UID`, `HOST_GID` | Utilisateur des conteneurs « outils », exportés par `launch.sh` |
| `<SERVICE>_IMAGE`, `<SERVICE>_TAG` | Image et tag d'un service, selon le profil |

## 💡 Astuces

### Alias PowerShell

Ajoutez à votre profil PowerShell (`$PROFILE`) :

```powershell
# Raccourcis Dev.Local 2.0
Set-Location "C:\Src\Dev.Local.2.0"
function menu { .\menu.ps1 }
function start { .\launch.ps1 }
function stop { .\launch.ps1 -c stop }
function secrets { .\launch.ps1 -c edit-secrets }
```

Ensuite, utilisez simplement :
```powershell
menu      # Ouvre le menu
start     # Démarre tout
stop      # Arrête tout
secrets   # Édite les secrets
```

## 📖 Où trouver le reste

| Sujet | Document |
|-------|----------|
| Structure des fichiers | [README.md](README.md#-structure-du-projet) |
| Format d'un profil, ports, Traefik | [README.md](README.md#-format-dun-profil) |
| Configuration de SOPS et des secrets | [README.md](README.md#-gestion-des-secrets-avec-sops), [docs/sops_age_guide.md](docs/sops_age_guide.md) |
| Variables d'environnement partagées | [docs/shared-env-guide.md](docs/shared-env-guide.md), [docs/shared-env-examples.md](docs/shared-env-examples.md) |
| Dozzle, registres, AWS (`config.yml`) | [README.md](README.md#configuration-globale-configyml) |
| Ports et configuration de Traefik | [README.md](README.md#personnalisation-traefik) |
| Dépannage | [README.md](README.md#-dépannage) |
| Checklist de démarrage | [QUICKSTART.md](QUICKSTART.md#-checklist-de-démarrage) |
| Linux/macOS | [BASH_README.md](BASH_README.md) |
| Tous les documents | [README.md](README.md#-documentation-complète) |

---

**💡 Conseil** : Ajoutez cette page aux favoris de votre navigateur ou épinglez ce fichier pour un accès rapide !

**🔗 Liens Utiles** :
- Docker : https://docs.docker.com/
- SOPS : https://github.com/mozilla/sops
- Traefik : https://doc.traefik.io/traefik/
- Age : https://github.com/FiloSottile/age
