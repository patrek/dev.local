# Scripts Bash pour Dev.Local 2.0

> **Rôle de ce document :** ce qui est propre à Linux/macOS (différences avec PowerShell, compatibilité, terminal, migration depuis Windows). Tout le reste est commun aux deux plateformes : référence dans [README.md](README.md), commandes dans [CHEATSHEET.md](CHEATSHEET.md), premier démarrage dans [QUICKSTART.md](QUICKSTART.md).

## ✅ Scripts Créés

Versions bash complètes des scripts PowerShell :

1. **menu.sh** - Menu interactif TUI
2. **manage-profiles.sh** - Gestion des profils et génération
3. **launch.sh** - Orchestration des services Docker
4. **validate-profiles.sh** - Validation des profils
5. **lib/yq.sh** - Fournit `yq` aux scripts ci-dessus (installation locale ou image Docker)

## 🚀 Utilisation sous Linux/macOS

### Prérequis

Les prérequis sont ceux du [README](README.md#prérequis). Pour les vérifier ou les installer :

```bash
# Docker & Docker Compose v2+
docker --version
docker compose version

# SOPS (pour les secrets)
brew install sops  # macOS
# ou télécharger depuis https://github.com/mozilla/sops/releases

# AWS CLI (optionnel, pour ECR)
brew install awscli
```

`yq` est optionnel : voir [(Optionnel) Installation de yq](README.md#optionnel-installation-de-yq-recommandé).

### Rendre les scripts exécutables

```bash
chmod +x *.sh
```

### Commandes

Toutes les commandes Bash, avec leurs équivalents Just et PowerShell, sont dans [CHEATSHEET.md](CHEATSHEET.md). Le menu se lance avec `./menu.sh`.

## 🔄 Équivalences PowerShell ↔ Bash

Les deux familles de scripts acceptent les mêmes actions ; seule la syntaxe des arguments change :

| | PowerShell | Bash |
|---|------------|------|
| Action de `manage-profiles` | `.\manage-profiles.ps1 -Action add` | `./manage-profiles.sh add` |
| Commande de `launch` | `.\launch.ps1 -c edit-secrets` | `./launch.sh edit-secrets` |
| Profils à démarrer | `.\launch.ps1 -p api,ui` | `./launch.sh --profile api,ui start` |
| Commande ponctuelle | `.\launch.ps1 run gulp -- npx gulp build` | `./launch.sh run gulp npx gulp build` |
| Menu | `.\menu.ps1` | `./menu.sh` |

## 📝 Différences avec PowerShell

### Fonctionnalités identiques
- ✅ Menu interactif complet (17 options)
- ✅ Création de profils avec prompts
- ✅ Génération docker-compose.yml et traefik/dynamic.yml (résultat identique, vérifié par `tests/compare-shells.sh`)
- ✅ Filtrage des ports (`expose_ports`)
- ✅ Support docker profiles (always_active/docker_profile)
- ✅ Synchronisation des secrets avec section `secrets:`
- ✅ Intégration SOPS complète
- ✅ Support Traefik failover
- ✅ Configuration Dozzle
- ✅ Variables d'environnement partagées (`config.yml`)

### Différences de comportement
- **Validation avant génération** : `manage-profiles.sh generate` exécute d'abord `validate-profiles.sh` et s'arrête en cas d'erreur.
- **`HOST_UID` / `HOST_GID`** : exportés par `launch.sh` pour les profils « outils » (voir [Exemple 4 bis](README.md#exemple-4-bis--outils-de-build-dans-docker-gulp-npm-)).
- **Secrets** : `launch.sh` n'exporte les secrets que pour sa propre exécution ; ils n'apparaissent pas dans votre shell.

### Adaptations techniques
- **Couleurs** : ANSI escape codes au lieu de `Write-Host -ForegroundColor`
- **Pause** : `read -n 1 -s` au lieu de `$Host.UI.RawUI.ReadKey()`
- **Arrays associatifs** : `declare -A` au lieu de `@{}`
- **Regex** : `sed`/`grep` au lieu de `-match`
- **YAML parsing** : `yq` (mikefarah v4+, local ou via Docker, voir `lib/yq.sh`) au lieu du module `powershell-yaml`

## 🐧 Compatibilité

- ✅ Linux (Ubuntu, Debian, RHEL, etc.)
- ✅ macOS (Intel & Apple Silicon)
- ✅ WSL2 (Windows Subsystem for Linux)
- ✅ Git Bash (Windows, avec limitations)

## 🎨 Caractères spéciaux

Les scripts bash utilisent les mêmes caractères UTF-8 que PowerShell :
- ╔═╗║└┘┌┐│ (box drawing)
- ✅❌🚀📋🔧 (emojis)

Assurez-vous que votre terminal supporte UTF-8 :

```bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

## 📦 Structure des fichiers

Les scripts bash créent exactement les mêmes fichiers que PowerShell :
- `docker-compose.yml`
- `traefik/dynamic.yml`
- `profiles/*.yml`
- `secrets.env` (chiffré avec SOPS)

Ils lisent le même `config.yml`.

## 🐛 Dépannage

Voir [Dépannage](README.md#-dépannage) dans le README, notamment :

- ["command not found" ou "Permission denied"](README.md#erreur--command-not-found-ou-permission-denied)
- ["bad interpreter: /bin/bash^M"](README.md#erreur--bad-interpreter-binbashm)
- ["SOPS n'est pas installé"](README.md#erreur--sops-nest-pas-installé)
- ["Docker Compose v2+ requis"](README.md#erreur--docker-compose-v2-requis)
- [Erreurs d'encodage UTF-8](README.md#erreurs-dencodage-utf-8-linuxmacos)

## 🔄 Migration Windows → Linux

1. Copiez tout le dossier `Dev.Local.2.0`
2. Rendez les scripts bash exécutables : `chmod +x *.sh`
3. Vérifiez SOPS : `sops --version`
4. Lancez le menu : `./menu.sh`

Les profils et secrets sont 100% compatibles entre les deux plateformes.

## 📚 Ressources

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [SOPS GitHub](https://github.com/mozilla/sops)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Age Encryption](https://github.com/FiloSottile/age)
