# Dev.Local 2.0 - Justfile
# Command runner simple - délègue aux scripts PS1/SH

set quiet := true
set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

launch := if os() == "windows" { ".\\launch.ps1" } else { "./launch.sh" }
manage := if os() == "windows" { ".\\manage-profiles.ps1" } else { "./manage-profiles.sh" }

@default:
    just --list --unsorted

# Services Docker

[doc("Démarrer tous les services")]
[group("docker")]
start:
    {{launch}} start

[doc("Démarrer avec profils spécifiques")]
[group("docker")]
start-profile profiles:
    {{launch}} -p {{profiles}} start

[doc("Arrêter tous les services")]
[group("docker")]
stop:
    {{launch}} stop

[doc("Redémarrer les services")]
[group("docker")]
restart:
    {{launch}} recreate

[doc("Lister les containers actifs")]
[group("docker")]
ps:
    {{launch}} ps

[doc("Voir les logs d'un service")]
[group("docker")]
logs service="":
    {{launch}} logs {{service}}

# Profils

[doc("Lister les profile dev.local")]
[group("profile")]
profiles:
    {{manage}} list

[doc("Regénérer docker-compose.yml et traefik")]
[group("profile")]
generate:
    {{manage}} generate

[doc("Valider la configuration Docker Compose")]
[group("profile")]
validate:
    docker compose config --quiet && echo "OK" || echo "ERREUR"

# Secrets

[doc("Éditer les secrets SOPS")]
[group("secrets")]
secrets-edit:
    {{launch}} edit-secrets

[doc("Voir les secrets déchiffrés")]
[group("secrets")]
secrets-view:
    {{launch}} view-secrets

# AWS

[doc("Connexion AWS SSO")]
[group("aws")]
aws-sso:
    {{launch}} sso

[doc("Afficher l'identité AWS")]
[group("aws")]
aws-id:
    {{launch}} id

[doc("Connexion Docker à AWS ECR")]
[group("aws")]
ecr-login:
    {{launch}} ecr-login

[doc("Connexion Docker à JFrog")]
[group("utilitaires")]
jfrog-login:
    {{launch}} jfrog-login

[doc("Nettoyer containers et volumes")]
[group("utilitaires")]
clean:
    docker compose down -v

[doc("Lancer le menu interactif")]
[group("utilitaires")]
menu:
    {{ if os() == "windows" { ".\\menu.ps1" } else { "./menu.sh" } }}

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
