# Dev.Local 2.0 - Justfile
# Command runner simple - délègue aux scripts PS1/SH

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

@default:
    just --list --unsorted

# Services Docker

[doc("Démarrer tous les services")]
[group("docker")]
start: (_run_script "launch" "start")

[windows]
[doc("Démarrer avec profils spécifiques")]
[group("docker")]
start-profile profiles:
    .\launch.ps1 -p {{profiles}} start

[unix]
[doc("Démarrer avec profils spécifiques")]
[group("docker")]
start-profile profiles:
    ./launch.sh --profile {{profiles}} start

[doc("Arrêter tous les services")]
[group("docker")]
stop: (_run_script "launch" "stop")

[doc("Redémarrer les services")]
[group("docker")]
restart: (_run_script "launch" "recreate")

[doc("Lister les containers actifs")]
[group("docker")]
ps: (_run_script "launch" "ps")

[windows]
[doc("Voir les logs d'un service")]
[group("docker")]
logs service="":
    .\launch.ps1 logs -service {{service}}

[unix]
[doc("Voir les logs d'un service")]
[group("docker")]
logs service="":
    ./launch.sh logs {{service}}

# Profils

[doc("Lister les profile dev.local")]
[group("profile")]
profiles: (_run_script "manage-profiles" "list")

[doc("Regénérer docker-compose.yml et traefik")]
[group("profile")]
generate: (_run_script "manage-profiles" "generate")

[doc("Valider la configuration Docker Compose")]
[group("profile")]
validate:
    @docker compose config --quiet && echo "OK" || echo "ERREUR"

# Secrets

[windows]
[doc("Éditer les secrets SOPS")]
[group("secrets")]
secrets-edit:
    .\launch.ps1 -c edit-secrets

[unix]
[doc("Éditer les secrets SOPS")]
[group("secrets")]
secrets-edit:
    ./launch.sh edit-secrets

[windows]
[doc("Voir les secrets déchiffrés")]
[group("secrets")]
secrets-view:
    .\launch.ps1 -c view-secrets

[unix]
[doc("Voir les secrets déchiffrés")]
[group("secrets")]
secrets-view:
    ./launch.sh view-secrets

# AWS

[windows]
[doc("Connexion AWS SSO")]
[group("aws")]
aws-sso:
    .\launch.ps1 -c sso

[unix]
[doc("Connexion AWS SSO")]
[group("aws")]
aws-sso:
    ./launch.sh sso

[windows]
[doc("Afficher l'identité AWS")]
[group("aws")]
aws-id:
    .\launch.ps1 -c id

[unix]
[doc("Afficher l'identité AWS")]
[group("aws")]
aws-id:
    ./launch.sh id

[windows]
[doc("Connexion Docker à AWS ECR")]
[group("aws")]
ecr-login:
    .\launch.ps1 -c ecr-login

[unix]
[doc("Connexion Docker à AWS ECR")]
[group("aws")]
ecr-login:
    ./launch.sh ecr-login

[windows]
[doc("Connexion Docker à JFrog")]
jfrog-login:
    .\launch.ps1 -c jfrog-login

[unix]
[doc("Connexion Docker à JFrog")]
[group("utilitaires")]
jfrog-login:
    ./launch.sh jfrog-login

[doc("Nettoyer containers et volumes")]
[group("utilitaires")]
clean:
    docker compose down -v

[doc("Lancer le menu interactif")]
[group("utilitaires")]
menu: (_run_script "menu")

[doc("Afficher la configuration Docker Compose")]
[group("utilitaires")]
config:
    docker compose config

# Fonction interne pour déléguer aux scripts

[windows]
_run_script script *args:
    .\{{script}}.ps1 {{args}}

[unix]
_run_script script *args:
    ./{{script}}.sh {{args}}

# Aliases
alias up := start
alias down := stop
alias s := start
alias st := stop
alias r := restart
alias p := ps
alias g := generate
alias v := validate
