#!/usr/bin/env bash
# Gestionnaire de profils pour Dev.Local 2.0
# Script pour ajouter, modifier, supprimer et lister des profils de services
# Génère automatiquement docker-compose.yml et la configuration Traefik

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

show_usage() {
    cat << EOF
Usage: $0 <action> [options]

Actions:
    list [--json]                   Lister les profils
    generate [--dry-run [--json]]   Générer docker-compose.yml et traefik/dynamic.yml
                                    (--dry-run : rien n'est écrit, indique ce qui changerait)
    add                             Ajouter un profil (questions interactives)
    add --name <nom> --image <image> [options]
                                    Ajouter un profil sans aucune question
    init-secrets                    Créer secrets.env chiffré
    sync-secrets                    Ajouter à secrets.env les variables manquantes
    list-secrets                    Noms des variables de secrets, un par ligne

Options de add (toutes sauf --name et --image sont facultatives) :
    --description <texte>           Description du service
    --docker-port <port>            Port interne du conteneur (défaut : 80)
    --local-port <port>             Port du service lancé sur l'hôte (défaut : --docker-port)
    --publish <hôte:conteneur>      Publier un port sur 127.0.0.1 (active expose_ports)
    --docker-profile <profil>       Démarrage à la demande (défaut : service toujours actif)
    --traefik-prefix </préfixe>     Activer la route Traefik sur ce préfixe
    --keep-prefix                   Ne pas retirer le préfixe avant de transmettre la requête
    --env <NOM=valeur>              Variable d'environnement (répétable)
    --secret <NOM>                  Variable de secret (répétable)
    --no-generate                   Ne pas regénérer docker-compose.yml après la création

Codes de sortie : 0 succès, 1 erreur.
EOF
}

ACTION="${1:-list}"
[ $# -gt 0 ] && shift

JSON_OUTPUT=false
DRY_RUN=false
ADD_OPTIONS_GIVEN=false
ADD_NAME=""
ADD_IMAGE=""
ADD_DESCRIPTION=""
ADD_DOCKER_PORT=""
ADD_LOCAL_PORT=""
ADD_PUBLISH=""
ADD_DOCKER_PROFILE=""
ADD_TRAEFIK_PREFIX=""
ADD_KEEP_PREFIX=false
ADD_NO_GENERATE=false
ADD_ENV=()
ADD_SECRETS=()

usage_error() {
    echo -e "\033[91m$1\033[0m" >&2
    show_usage >&2
    exit 1
}

case "$ACTION" in
    -h|--help)
        show_usage
        exit 0
        ;;
esac

# Options : chacune n'est acceptée que par l'action qu'elle concerne
while [ $# -gt 0 ]; do
    option="$1"
    case "$ACTION:$option" in
        *:-h|*:--help)
            show_usage
            exit 0
            ;;
        list:--json|generate:--json)
            JSON_OUTPUT=true
            shift
            ;;
        generate:--dry-run)
            DRY_RUN=true
            shift
            ;;
        add:--keep-prefix)
            ADD_OPTIONS_GIVEN=true
            ADD_KEEP_PREFIX=true
            shift
            ;;
        add:--no-generate)
            ADD_OPTIONS_GIVEN=true
            ADD_NO_GENERATE=true
            shift
            ;;
        add:--name|add:--image|add:--description|add:--docker-port|add:--local-port|add:--publish|add:--docker-profile|add:--traefik-prefix|add:--env|add:--secret)
            [ $# -ge 2 ] || usage_error "Valeur manquante pour l'option $option"
            ADD_OPTIONS_GIVEN=true
            case "$option" in
                --name) ADD_NAME="$2" ;;
                --image) ADD_IMAGE="$2" ;;
                --description) ADD_DESCRIPTION="$2" ;;
                --docker-port) ADD_DOCKER_PORT="$2" ;;
                --local-port) ADD_LOCAL_PORT="$2" ;;
                --publish) ADD_PUBLISH="$2" ;;
                --docker-profile) ADD_DOCKER_PROFILE="$2" ;;
                --traefik-prefix) ADD_TRAEFIK_PREFIX="$2" ;;
                --env) ADD_ENV+=("$2") ;;
                --secret) ADD_SECRETS+=("$2") ;;
            esac
            shift 2
            ;;
        *)
            usage_error "Argument inconnu pour l'action $ACTION: $option"
            ;;
    esac
done
if [ "$JSON_OUTPUT" = true ] && [ "$ACTION" = "generate" ] && [ "$DRY_RUN" != true ]; then
    usage_error "generate --json demande --dry-run"
fi

PROFILES_DIR="profiles"
DOCKER_COMPOSE_FILE="docker-compose.yml"
TRAEFIK_DYNAMIC_FILE="traefik/dynamic.yml"
SECRETS_FILE="secrets.env"
CONFIG_FILE="config.yml"

# Configuration par défaut
DOZZLE_ENABLED=true
DOZZLE_PORT=9999
NAMESPACE="devlocal"

# yq local ou via Docker (voir lib/yq.sh)
source "lib/yq.sh"
source "lib/json.sh"

# Configuration des variables partagées (chargée par load_config)
SHARED_ENV_ENABLED=true
SHARED_ENV_EXCLUDED=()

# Retourne $1, ou $2 si $1 est vide ou "null" (champ YAML absent)
# Ne pas utiliser l'opérateur yq '//' pour cela : il remplace aussi 'false'
value_or_default() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        echo "$2"
    else
        echo "$1"
    fi
}

# Expression yq : noms des volumes nommés de la section docker-compose.volumes d'un profil,
# un par ligne. Un volume nommé doit être déclaré dans la section volumes: de premier
# niveau, sinon docker compose refuse le fichier.
#   - syntaxe courte "nom:/chemin[:mode]" : la source est un nom de volume (au moins deux
#     caractères, sinon Compose y voit une lettre de lecteur Windows), pas un chemin
#     (./, /, ~, C:\) ni une variable (${VAR}) ;
#   - syntaxe longue : type: volume avec une source.
# Les montages de dossiers et les volumes anonymes ne sont pas retournés.
NAMED_VOLUMES_EXPR='(.["docker-compose"].volumes | select(tag == "!!seq") | .[] | (
    (select(tag == "!!str") | select(test("^[a-zA-Z0-9][a-zA-Z0-9_.-]+:")) | sub(":.*$"; "")),
    (select(tag == "!!map" and .type == "volume") | .source
        | select(tag == "!!str" and test("^[a-zA-Z0-9][a-zA-Z0-9_.-]*$")))
))'

# Expression yq : section docker-compose d'un profil, réécrite par yq pour être traitée
# ligne par ligne dans generate_docker_compose, quelle que soit l'écriture du profil :
#   - indentation de 2 espaces et style bloc pour la section, ports et environment
#     (jamais [..] ni {..} sur une ligne), clés de la section sans guillemets ;
#   - environment toujours en liste : la forme map (CLE: valeur) devient CLE=valeur, dans
#     l'ordre du fichier et avec le texte tel qu'il est écrit (CLE: sans valeur donne CLE=) ;
#     une liste vide est créée si la clé est absente ;
#   - ancres et alias résolus, commentaires retirés ;
#   - ports en syntaxe longue (target / published) : host_ip: 127.0.0.1 ajouté s'il est absent,
#     comme bind_port_to_localhost le fait pour la syntaxe courte ;
#   - ports et volumes absents (null) retirés : yq crée ces clés à la lecture d'un chemin
#     absent, ici et dans NAMED_VOLUMES_EXPR.
COMPOSE_SECTION_EXPR='(.["docker-compose"] | select(tag == "!!map") | explode(.)
    | (.[] | key) style = ""
    | with(.environment | select(tag == "!!null"); . = [])
    | with(.environment | select(tag == "!!map");
        . = (to_entries | map((.key | tostring) + "=" + (.value | with(select(tag == "!!null"); . = "") | tostring))))
    | with(.ports | select(tag == "!!seq") | .[] | select(tag == "!!map" and (has("host_ip") | not));
        .host_ip = "127.0.0.1")
    | (., (.ports, .environment | select(tag == "!!seq"))) style = ""
    | ... comments = ""
    | del((.ports, .volumes) | select(tag == "!!null")))'
# Ligne qui précède la section docker-compose dans la sortie de yq (jamais un nom de volume)
COMPOSE_SECTION_MARKER='#--docker-compose--'

# Lie une entrée de port (syntaxe courte) à 127.0.0.1 si elle ne précise pas d'IP hôte.
#   "8090:80" -> "127.0.0.1:8090:80"      "80" -> "127.0.0.1::80"
# Les entrées avec IP explicite (ex: "0.0.0.0:8090:80") et la syntaxe longue sont conservées.
bind_port_to_localhost() {
    local line="$1"
    local pattern='^([[:space:]]*-[[:space:]]*["'"'"']?)([^"'"'"'#[:space:]]+)(.*)$'

    if [[ "$line" =~ $pattern ]]; then
        local prefix="${BASH_REMATCH[1]}" spec="${BASH_REMATCH[2]}" rest="${BASH_REMATCH[3]}"
        if [[ "$spec" != *: ]]; then
            # Compter les ':' en ignorant ceux des ${VAR:-defaut}
            local outside_vars
            outside_vars=$(echo "$spec" | sed 's/\${[^}]*}//g')
            local colons="${outside_vars//[^:]/}"
            case "${#colons}" in
                0) spec="127.0.0.1::$spec" ;;
                1) spec="127.0.0.1:$spec" ;;
            esac
        fi
        line="${prefix}${spec}${rest}"
    fi
    echo "$line"
}

# Charger la configuration
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0

    read_yaml_fields "$CONFIG_FILE" .dozzle_enabled .dozzle_port .namespace .shared_env_config.enabled
    DOZZLE_ENABLED=$(value_or_default "${YAML_FIELDS[0]}" true)
    DOZZLE_PORT=$(value_or_default "${YAML_FIELDS[1]}" 9999)
    NAMESPACE=$(value_or_default "${YAML_FIELDS[2]}" devlocal)
    SHARED_ENV_ENABLED=$(value_or_default "${YAML_FIELDS[3]}" true)

    mapfile -t SHARED_ENV_EXCLUDED < <(yq e '.shared_env_config.exclude_services[]' "$CONFIG_FILE" 2>/dev/null)
}

# Fonction pour charger les variables d'environnement partagées
# Nécessite load_config. Retourne une variable par ligne : les groupes auto_inject,
# puis les groupes service_specific du service, chaque groupe une seule fois.
# Rien si le service est exclu.
get_shared_env_vars() {
    local service_name="$1"

    [ -f "$CONFIG_FILE" ] || return 0
    [ "$SHARED_ENV_ENABLED" = "false" ] && return 0

    local excluded
    for excluded in "${SHARED_ENV_EXCLUDED[@]}"; do
        [ "$excluded" = "$service_name" ] && return 0
    done

    yq e ".shared_env as \$env
        | (((.shared_env_config.auto_inject // []) + (.shared_env_config.service_specific[\"$service_name\"] // [])) | unique)
        | .[] as \$group
        | \$env[\$group]
        | .[]" "$CONFIG_FILE" 2>/dev/null || true
}

# Fonction pour lister les profils
show_profiles() {
    echo -e "\n\033[96m📋 PROFILS DISPONIBLES\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    
    if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/*.yml 2>/dev/null)" ]; then
        echo -e "\033[93mAucun profil trouvé dans $PROFILES_DIR\033[0m"
        return
    fi
    
    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue
        local basename
        basename=$(basename "$profile")
        # description en dernier : seule sa première ligne est lue si elle est multi-ligne
        read_yaml_fields "$profile" .name .enabled .description
        local name
        name=$(value_or_default "${YAML_FIELDS[0]}" "${basename%.yml}")
        local enabled
        enabled=$(value_or_default "${YAML_FIELDS[1]}" true)
        local description
        description=$(value_or_default "${YAML_FIELDS[2]}" "Sans description")

        if [ "$enabled" = "true" ]; then
            echo -e "  \033[97m$name\033[0m - \033[92m✅ Activé\033[0m"
        else
            echo -e "  \033[97m$name\033[0m - \033[91m❌ Désactivé\033[0m"
        fi
        echo -e "    \033[90m📝 $description\033[0m"
        echo -e "    \033[90m📁 $basename\033[0m"
        echo ""
    done
}

# Signale une option de add invalide (stderr) ; retourne 1
add_option_error() {
    echo -e "\033[91m$1\033[0m" >&2
    return 1
}

# Ajoute un secret au profil en cours de création (variables secrets et secrets_doc)
# Usage : add_secret_entry <nom du profil> <nom du secret> [description]
add_secret_entry() {
    local secret_var
    secret_var=$(echo "$2" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]/_/g')
    local secret_desc="${3:-Secret pour $1}"
    secret_desc="${secret_desc//\\/\\\\}"
    secret_desc="${secret_desc//\"/\\\"}"

    secrets="${secrets}    - ${secret_var}=\${${secret_var}:-changeme}"$'\n'
    secrets_doc="${secrets_doc}  - name: ${secret_var}"$'\n'"    description: \"${secret_desc}\""$'\n'"    default: changeme"$'\n'
}

# Renseigne les variables du profil à créer depuis les options de la ligne de commande
# (add sans question). Retourne 1 si une valeur est invalide.
read_add_options() {
    local port_pattern='^[0-9]{1,5}$'

    image="$ADD_IMAGE"
    [ -n "$image" ] || { add_option_error "L'option --image est requise"; return 1; }
    [[ "$image" =~ ^[^[:space:]\"\'#]+$ ]] || { add_option_error "Image invalide: $image"; return 1; }

    description="$ADD_DESCRIPTION"
    [[ "$description" != *$'\n'* ]] || { add_option_error "La description doit tenir sur une ligne"; return 1; }

    docker_port="${ADD_DOCKER_PORT:-80}"
    local_port="${ADD_LOCAL_PORT:-$docker_port}"
    [[ "$docker_port" =~ $port_pattern ]] || { add_option_error "Port invalide pour --docker-port: $docker_port"; return 1; }
    [[ "$local_port" =~ $port_pattern ]] || { add_option_error "Port invalide pour --local-port: $local_port"; return 1; }

    host_binding="$ADD_PUBLISH"
    if [ -n "$host_binding" ] && ! [[ "$host_binding" =~ ^[^[:space:]\"\'#]+$ ]]; then
        add_option_error "Port invalide pour --publish: $host_binding"
        return 1
    fi

    always_active="true"
    docker_profile="null"
    if [ -n "$ADD_DOCKER_PROFILE" ]; then
        [[ "$ADD_DOCKER_PROFILE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] \
            || { add_option_error "Profil Docker invalide: $ADD_DOCKER_PROFILE"; return 1; }
        always_active="false"
        docker_profile="$ADD_DOCKER_PROFILE"
    fi

    enable_traefik="false"
    traefik_prefix="/"
    strip_prefix="false"
    if [ -n "$ADD_TRAEFIK_PREFIX" ]; then
        [[ "$ADD_TRAEFIK_PREFIX" =~ ^/[a-zA-Z0-9/_.-]*$ ]] \
            || { add_option_error "Préfixe Traefik invalide (doit commencer par /): $ADD_TRAEFIK_PREFIX"; return 1; }
        enable_traefik="true"
        traefik_prefix="$ADD_TRAEFIK_PREFIX"
        [ "$ADD_KEEP_PREFIX" = true ] || strip_prefix="true"
    fi

    # Entre apostrophes dans le profil : la valeur est du texte, quel que soit son contenu
    env_vars=""
    local env_var
    for env_var in "${ADD_ENV[@]}"; do
        if ! [[ "$env_var" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || [[ "$env_var" == *$'\n'* ]]; then
            add_option_error "Variable invalide pour --env (format NOM=valeur): $env_var"
            return 1
        fi
        env_vars="${env_vars}    - '${env_var//\'/\'\'}'"$'\n'
    done

    secrets=""
    secrets_doc=""
    local secret
    for secret in "${ADD_SECRETS[@]}"; do
        [[ "$secret" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
            || { add_option_error "Nom de secret invalide pour --secret: $secret"; return 1; }
        add_secret_entry "$name" "$secret"
    done
}

# Fonction pour ajouter un profil : questions interactives, ou sans aucune question si des
# options sont passées sur la ligne de commande (voir show_usage)
add_profile() {
    local interactive=true
    [ "$ADD_OPTIONS_GIVEN" = true ] && interactive=false

    if [ "$interactive" = true ]; then
        echo -e "\n\033[96m➕ AJOUTER UN NOUVEAU PROFIL\033[0m"
        echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        read -p $'\nNom du service (ex: api-backend, frontend): ' name
    else
        name="$ADD_NAME"
    fi
    if [ -z "$name" ]; then
        echo -e "\033[91mLe nom est requis\033[0m" >&2
        return 1
    fi

    # Nettoyer le nom
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    filename="$PROFILES_DIR/$name.yml"

    if [ -f "$filename" ]; then
        echo -e "\033[91mUn profil '$name' existe déjà !\033[0m" >&2
        return 1
    fi

    if [ "$interactive" = true ]; then
        read -p "Description du service: " description
        read -p "Image Docker (ex: nginx:latest, registry.io/myapp:v1.0): " image
        read -p "Port interne du conteneur (ex: 80, 8000): " docker_port
        read -p "Port exposé localement (via Traefik host) (ex: 8001): " local_port
        [ -z "$docker_port" ] && docker_port="80"
        [ -z "$local_port" ] && local_port=$docker_port

        # Par défaut le service n'est joignable que via Traefik ; publier un port est optionnel
        read -p "Publier aussi un port sur l'hôte (hôte:conteneur, ex: 9000:$docker_port, Entrée pour aucun): " host_binding
        [ "$host_binding" = "none" ] && host_binding=""

        echo -e "\n\033[93m🔑 Activation du service\033[0m"
        read -p "Service toujours actif (démarré par défaut) ? (O/n): " always_active_input
        always_active="true"
        docker_profile="null"
        if [ "$always_active_input" = "n" ]; then
            always_active="false"
            read -p "Nom du profil Docker (pour démarrage conditionnel, ex: $name): " docker_profile
            [ -z "$docker_profile" ] && docker_profile=$name
        fi

        echo -e "\n\033[93m🔧 Configuration Traefik\033[0m"
        read -p "Activer Traefik ? (o/N): " enable_traefik_input
        enable_traefik="false"
        traefik_prefix="/"
        strip_prefix="false"

        if [ "$enable_traefik_input" = "o" ]; then
            enable_traefik="true"
            read -p "Préfixe de route (ex: /api, /app): " traefik_prefix
            [ -z "$traefik_prefix" ] && traefik_prefix="/$name"
            read -p "Supprimer le préfixe avant transmission ? (O/n): " strip_prefix_input
            [ "$strip_prefix_input" != "n" ] && strip_prefix="true"
        fi

        echo -e "\n\033[93m🔐 Variables d'environnement\033[0m"
        echo "Entrez les variables (format: NOM=valeur), ligne vide pour terminer"
        env_vars=""
        while true; do
            read -p "Variable d'environnement: " env_var
            [ -z "$env_var" ] && break
            env_vars="${env_vars}    - ${env_var}"$'\n'
        done

        echo -e "\n\033[93m🔑 Secrets depuis secrets.env\033[0m"
        echo "Entrez les secrets (format: SECRET_NAME), ligne vide pour terminer"
        secrets=""
        secrets_doc=""
        while true; do
            read -p "Nom du secret: " secret
            [ -z "$secret" ] && break
            read -p "  Description (optionnel): " secret_desc
            add_secret_entry "$name" "$secret" "$secret_desc"
        done
    else
        read_add_options || return 1
    fi

    expose_ports="false"
    ports_section=""
    if [ -n "$host_binding" ]; then
        expose_ports="true"
        ports_section=$'\n'"  ports:"$'\n'"    - \"$host_binding\""
    fi

    # La description est écrite entre guillemets dans le profil
    description="${description//\\/\\\\}"
    description="${description//\"/\\\"}"

    # Combiner env vars et secrets
    all_env="${env_vars}${secrets}"
    all_env="${all_env%$'\n'}"
    [ -z "$all_env" ] && all_env="    # Aucune variable d'environnement"
    
    # Section secrets si nécessaire
    secrets_section=""
    if [ -n "$secrets_doc" ]; then
        secrets_section=$'\n'"# Variables de secrets requises (à définir dans secrets.env)"$'\n'"secrets:"$'\n'"${secrets_doc}"
    fi
    
    # Générer le fichier YAML
    mkdir -p "$PROFILES_DIR"
    cat > "$filename" << EOF
# yaml-language-server: \$schema=../schemas/profile.schema.json
# Profil généré automatiquement
name: $name
description: "$description"
enabled: true
always_active: $always_active
docker_profile: $docker_profile
expose_ports: $expose_ports

docker-compose:
  image: $image
  container_name: $name$ports_section
  environment:
$all_env
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:$docker_port/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 10s

traefik:
  enabled: $enable_traefik
  prefix: $traefik_prefix
  strip_prefix: $strip_prefix
  local_port: $local_port
  docker_port: $docker_port
  priority: 10
$secrets_section
metadata:
  category: custom
  tags:
    - $name
EOF
    
    echo -e "\n\033[92m✅ Profil créé : $filename\033[0m"
    echo -e "\033[90m📝 Vous pouvez éditer ce fichier pour personnaliser davantage\033[0m"

    # Regénérer docker-compose.yml : proposé en mode interactif, fait d'office sinon
    local regen=""
    if [ "$interactive" = true ]; then
        read -p $'\nRegénérer docker-compose.yml maintenant ? (O/n): ' regen
    elif [ "$ADD_NO_GENERATE" = true ]; then
        regen="n"
    fi
    if [ "$regen" != "n" ]; then
        generate_docker_compose
    fi
}

# Liste des profils en JSON : un objet par fichier, avec les valeurs par défaut appliquées
# comme le fait la génération
show_profiles_json() {
    local items=()
    local profile

    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue

        # description en dernier : si elle est multi-ligne, ses lignes suivent
        read_yaml_fields "$profile" .name .enabled .always_active .docker_profile .expose_ports \
            '.["docker-compose"].image' .traefik.enabled .traefik.prefix .description
        if [ "${#YAML_FIELDS[@]}" -lt 9 ]; then
            echo -e "\033[91mProfil illisible (YAML invalide): $profile\033[0m" >&2
            return 1
        fi

        local name
        name=$(value_or_default "${YAML_FIELDS[0]}" "$(basename "$profile" .yml)")
        local description
        description=$(printf '%s\n' "${YAML_FIELDS[@]:8}")
        local traefik_enabled
        traefik_enabled=$(value_or_default "${YAML_FIELDS[6]}" false)
        local url="null"
        if [ "$traefik_enabled" = "true" ]; then
            url=$(json_string "http://localhost:8080$(value_or_default "${YAML_FIELDS[7]}" "/$name")")
        fi

        items+=("$(printf '{"name":%s,"file":%s,"description":%s,"enabled":%s,"always_active":%s,"docker_profile":%s,"expose_ports":%s,"image":%s,"traefik_enabled":%s,"url":%s}' \
            "$(json_string "$name")" \
            "$(json_string "$profile")" \
            "$(json_string_or_null "$description")" \
            "$(json_bool "$(value_or_default "${YAML_FIELDS[1]}" true)")" \
            "$(json_bool "${YAML_FIELDS[2]}")" \
            "$(json_string_or_null "${YAML_FIELDS[3]}")" \
            "$(json_bool "${YAML_FIELDS[4]}")" \
            "$(json_string_or_null "${YAML_FIELDS[5]}")" \
            "$(json_bool "$traefik_enabled")" \
            "$url")")
    done

    local IFS=,
    echo "[${items[*]}]"
}

# generate --dry-run : génère dans un dossier temporaire et indique, pour chaque fichier,
# s'il serait créé (new), modifié (changed) ou identique (unchanged). Rien n'est écrit dans
# le projet. Avec --json, seul le résultat est écrit sur stdout ; le reste va sur stderr.
generate_dry_run() {
    local real_files=("$DOCKER_COMPOSE_FILE" "$TRAEFIK_DYNAMIC_FILE")
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT
    DOCKER_COMPOSE_FILE="$tmp_dir/docker-compose.yml"
    TRAEFIK_DYNAMIC_FILE="$tmp_dir/dynamic.yml"
    local new_files=("$DOCKER_COMPOSE_FILE" "$TRAEFIK_DYNAMIC_FILE")

    if [ "$JSON_OUTPUT" = true ]; then
        generate_docker_compose >&2 || return 1
    else
        generate_docker_compose || return 1
    fi

    local items=()
    local index status
    [ "$JSON_OUTPUT" = true ] || echo -e "\n\033[96m🔎 Simulation : aucun fichier n'a été écrit\033[0m"
    for index in 0 1; do
        # La ligne d'horodatage change à chaque génération : ignorée
        if [ ! -f "${real_files[$index]}" ]; then
            status="new"
        elif diff -q <(grep -v '^# Dernière génération' "${real_files[$index]}") \
                     <(grep -v '^# Dernière génération' "${new_files[$index]}") > /dev/null; then
            status="unchanged"
        else
            status="changed"
        fi
        items+=("{\"file\":$(json_string "${real_files[$index]}"),\"status\":\"$status\"}")
        [ "$JSON_OUTPUT" = true ] || echo "  ${real_files[$index]} : $status"
    done

    if [ "$JSON_OUTPUT" = true ]; then
        local IFS=,
        echo "[${items[*]}]"
    fi
}

# Fonction pour générer docker-compose.yml
generate_docker_compose() {
    echo -e "\n\033[96m🔧 GÉNÉRATION DE docker-compose.yml\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/*.yml 2>/dev/null)" ]; then
        echo -e "\033[93mAucun profil trouvé\033[0m"
        return 1
    fi

    # Validation des profils avant génération
    if [ -f "./validate-profiles.sh" ]; then
        echo -e "\n\033[96m🔍 Validation des profils...\033[0m"
        if ! bash ./validate-profiles.sh; then
            echo -e "\n\033[91m❌ La validation a échoué. Corrigez les erreurs avant de générer.\033[0m"
            return 1
        fi
        echo ""
    fi

    load_config
    
    # Header avec timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$DOCKER_COMPOSE_FILE" << EOF
# Généré automatiquement par manage-profiles.sh
# NE PAS ÉDITER MANUELLEMENT - Vos modifications seront écrasées
# Dernière génération : $timestamp
name: $NAMESPACE

services:
  # Proxy du socket Docker : seul conteneur qui monte le socket.
  # Traefik et Dozzle passent par lui et n'ont accès qu'à des requêtes de lecture
  # (conteneurs, événements, infos) ; aucune requête d'écriture n'est acceptée.
  socket-proxy:
    image: tecnativa/docker-socket-proxy:v0.5.0
    container_name: ${NAMESPACE}_socket_proxy
    environment:
      - CONTAINERS=1  # liste, logs et stats des conteneurs (Traefik, Dozzle)
      - INFO=1        # requis par Dozzle pour se connecter
      - POST=0        # refuse toute requête d'écriture
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - socket-proxy

  # Reverse Proxy Traefik
  traefik:
    image: traefik:v3.6.4
    container_name: ${NAMESPACE}_traefik
    ports:
      - "127.0.0.1:8080:80"
      - "127.0.0.1:8081:8080"
    extra_hosts:
      - "external-ip:host-gateway"
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro
    networks:
      - traefik-network
      - socket-proxy
    depends_on:
      - socket-proxy
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3

EOF
    
    # Ajouter Dozzle si activé
    if [ "$DOZZLE_ENABLED" = "true" ]; then
        cat >> "$DOCKER_COMPOSE_FILE" << EOF
  # Monitoring des logs
  dozzle:
    image: amir20/dozzle:v11.5.0
    container_name: ${NAMESPACE}_dozzle
    ports:
      - "127.0.0.1:$DOZZLE_PORT:8080"
    environment:
      - DOZZLE_TIMEOUT=15s
      - DOZZLE_BASE=/logs
      - DOCKER_HOST=tcp://socket-proxy:2375
    extra_hosts:
      - "external-ip:host-gateway"
    networks:
      - traefik-network
      - socket-proxy
    depends_on:
      - socket-proxy
    healthcheck:
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 3s
      timeout: 30s

EOF
    fi
    
    # Ajouter chaque service
    local named_volumes=()
    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue

        # Les volumes nommés puis la section docker-compose normalisée suivent les cinq
        # champs scalaires (même appel yq) ; un marqueur sépare ces deux listes de lignes
        read_yaml_fields "$profile" .enabled .name .always_active .docker_profile .expose_ports \
            "$NAMED_VOLUMES_EXPR" "\"$COMPOSE_SECTION_MARKER\"" "$COMPOSE_SECTION_EXPR"
        local enabled
        enabled=$(value_or_default "${YAML_FIELDS[0]}" true)
        if [ "$enabled" != "true" ]; then
            echo -e "  \033[90m⏭️  Ignoré (désactivé) : $(basename "$profile" .yml)\033[0m"
            continue
        fi

        local name
        name=$(value_or_default "${YAML_FIELDS[1]}" "$(basename "$profile" .yml)")
        local always_active
        always_active=$(value_or_default "${YAML_FIELDS[2]}" false)
        # Chaîne vide si docker_profile est absent ou null
        local docker_profile
        docker_profile=$(value_or_default "${YAML_FIELDS[3]}" "")
        # Sans expose_ports, la section ports est retirée : le service passe par Traefik
        local expose_ports
        expose_ports=$(value_or_default "${YAML_FIELDS[4]}" false)
        echo -e "  \033[92m✅ Ajout : $(basename "$profile" .yml)\033[0m"

        # Charger les variables partagées pour ce service
        local shared_env_vars
        shared_env_vars=$(get_shared_env_vars "$name")
        local shared_count=0
        if [ -n "$shared_env_vars" ]; then
            shared_count=$(echo "$shared_env_vars" | grep -c "^" || echo 0)
            echo -e "    \033[90m📌 $shared_count variable(s) partagée(s)\033[0m"
        fi

        # La section docker-compose normalisée par yq suit le marqueur, les volumes nommés le précèdent
        local compose_lines=()
        local field_index
        for field_index in "${!YAML_FIELDS[@]}"; do
            if [ "$field_index" -ge 5 ] && [ "${YAML_FIELDS[$field_index]}" = "$COMPOSE_SECTION_MARKER" ]; then
                named_volumes+=("${YAML_FIELDS[@]:5:$((field_index - 5))}")
                compose_lines=("${YAML_FIELDS[@]:$((field_index + 1))}")
                break
            fi
        done

        # Recopier la section dans le service. Une ligne non indentée est une clé de la section ;
        # les lignes indentées qui la suivent sont sa valeur.
        local service_body=""
        local current_key=""
        local ports_ignored=false
        local line
        for line in "${compose_lines[@]}"; do
            if [ -n "$line" ] && [[ "$line" != " "* ]]; then
                current_key="${line%%:*}"

                if [ "$current_key" = "ports" ] && [ "$expose_ports" != "true" ]; then
                    ports_ignored=true
                fi

                # environment est toujours une liste : "environment:" suivi de ses éléments,
                # ou "environment: []" si le profil n'a aucune variable
                if [ "$line" = "environment:" ] || [ "$line" = "environment: []" ]; then
                    # Sans variable d'aucune sorte, le service n'a pas de clé environment
                    [ "$line" = "environment: []" ] && [ -z "$shared_env_vars" ] && continue

                    service_body+="    environment:"$'\n'
                    if [ -n "$shared_env_vars" ]; then
                        service_body+="      # Variables partagées (depuis config.yml)"$'\n'
                        local var
                        while IFS= read -r var; do
                            [ -n "$var" ] && service_body+="      - ${var}"$'\n'
                        done <<< "$shared_env_vars"
                        if [ "$line" = "environment:" ]; then
                            service_body+="      # Variables exclusives du service"$'\n'
                        fi
                    fi
                    continue
                fi
            fi

            # Section ports : publiée sur 127.0.0.1 si expose_ports, retirée sinon
            if [ "$current_key" = "ports" ]; then
                [ "$expose_ports" = "true" ] || continue
                # Éléments de la liste ; les lignes plus indentées (syntaxe longue) sont conservées
                if [[ "$line" == "  - "* ]]; then
                    line=$(bind_port_to_localhost "$line")
                fi
            fi

            if [ -n "$line" ]; then
                service_body+="    ${line}"$'\n'
            else
                service_body+=$'\n'
            fi
        done

        if [ "$ports_ignored" = true ]; then
            echo -e "    \033[90m🔒 Ports non publiés (expose_ports: true pour les publier sur 127.0.0.1)\033[0m"
        fi

        local indented="${service_body%$'\n'}"

        # Section profiles si not always_active ET docker_profile n'est pas null/vide
        local profiles_section=""
        if [ "$always_active" != "true" ] && [ -n "$docker_profile" ] && [ "$docker_profile" != "null" ]; then
            profiles_section=$'\n'"    profiles:"$'\n'"      - $docker_profile"
        fi
        
        cat >> "$DOCKER_COMPOSE_FILE" << EOF
  # Service: $name
  $name:
$indented
    extra_hosts:
      - "external-ip:host-gateway"
    networks:
      - traefik-network$profiles_section

EOF
    done
    
    # Networks
    cat >> "$DOCKER_COMPOSE_FILE" << 'EOF'

networks:
  traefik-network:
    driver: bridge
  # Réseau interne réservé à socket-proxy, Traefik et Dozzle :
  # les services des profils ne peuvent pas joindre l'API Docker
  socket-proxy:
    driver: bridge
    internal: true
EOF

    # Volumes nommés utilisés par les profils activés : déclarés une fois, triés
    if [ "${#named_volumes[@]}" -gt 0 ]; then
        {
            printf '\nvolumes:\n'
            printf '%s\n' "${named_volumes[@]}" | LC_ALL=C sort -u | sed 's/.*/  &:/'
        } >> "$DOCKER_COMPOSE_FILE"
    fi

    echo -e "\n\033[92m✅ docker-compose.yml généré\033[0m"
    
    # Générer aussi la config Traefik
    generate_traefik_dynamic
}

# Fonction pour générer traefik/dynamic.yml
generate_traefik_dynamic() {
    echo -e "\n\033[96m🔧 GÉNÉRATION DE traefik/dynamic.yml\033[0m"
    
    mkdir -p "$(dirname "$TRAEFIK_DYNAMIC_FILE")"

    # Buffers
    local routers=""
    local middlewares=""
    local services=""
    
    # Générer les services pour chaque profil
    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue

        read_yaml_fields "$profile" .enabled .traefik.enabled .name \
            .traefik.local_port .traefik.docker_port .traefik.health_path \
            .traefik.prefix .traefik.strip_prefix .traefik.priority

        local enabled
        enabled=$(value_or_default "${YAML_FIELDS[0]}" true)
        local traefik_enabled
        traefik_enabled=$(value_or_default "${YAML_FIELDS[1]}" false)
        if [ "$enabled" != "true" ] || [ "$traefik_enabled" != "true" ]; then
            continue
        fi

        local name
        name=$(value_or_default "${YAML_FIELDS[2]}" "$(basename "$profile" .yml)")
        local local_port
        local_port=$(value_or_default "${YAML_FIELDS[3]}" 80)
        local docker_port
        docker_port=$(value_or_default "${YAML_FIELDS[4]}" 80)
        local health_path
        health_path=$(value_or_default "${YAML_FIELDS[5]}" /health)
        local prefix
        prefix=$(value_or_default "${YAML_FIELDS[6]}" "/$name")
        local strip_prefix
        strip_prefix=$(value_or_default "${YAML_FIELDS[7]}" false)
        local priority
        priority=$(value_or_default "${YAML_FIELDS[8]}" 10)

        # --- Middleware ---
        local middleware_ref=""
        if [ "$strip_prefix" = "true" ]; then
             middleware_ref=$'\n'"      middlewares:"$'\n'"        - ${name}-strip"
             middlewares="${middlewares}"$'\n'"    ${name}-strip:"$'\n'"      stripPrefix:"$'\n'"        prefixes:"$'\n'"          - \"$prefix\""
        fi

        # --- Router ---
        # Utilisation de backticks escaped pour la règle PathPrefix
        routers="${routers}"$'\n'"    ${name}:"$'\n'"      rule: \"PathPrefix(\`$prefix\`)\""$'\n'"      service: ${name}"$'\n'"      priority: $priority${middleware_ref}"

        # --- Service ---
        services="${services}"$'\n'"    ${name}:"$'\n'"      failover:"$'\n'"        service: ${name}-host"$'\n'"        fallback: ${name}-docker"
        services="${services}"$'\n'"    ${name}-host:"$'\n'"      loadBalancer:"$'\n'"        healthCheck:"$'\n'"          path: $health_path"$'\n'"          interval: 5s"$'\n'"          timeout: 1s"$'\n'"        servers:"$'\n'"          - url: \"http://external-ip:${local_port}\""$'\n'"        passHostHeader: true"
        services="${services}"$'\n'"    ${name}-docker:"$'\n'"      loadBalancer:"$'\n'"        healthCheck:"$'\n'"          path: $health_path"$'\n'"          interval: 5s"$'\n'"          timeout: 1s"$'\n'"        servers:"$'\n'"          - url: \"http://${name}:${docker_port}\""$'\n'"        passHostHeader: true"
    done
    
    # Écriture du fichier header
    cat > "$TRAEFIK_DYNAMIC_FILE" << EOF
# Généré automatiquement par manage-profiles.sh
# NE PAS ÉDITER MANUELLEMENT - Vos modifications seront écrasées
http:
EOF

    # Ajout des routers
    if [ -n "$routers" ] || [ "$DOZZLE_ENABLED" = "true" ]; then
        echo "  routers:$routers" >> "$TRAEFIK_DYNAMIC_FILE"

        # Ajouter le router Dozzle si activé
        if [ "$DOZZLE_ENABLED" = "true" ]; then
            echo "    dozzle-logs:" >> "$TRAEFIK_DYNAMIC_FILE"
            echo '      rule: "PathPrefix(`/logs`)"' >> "$TRAEFIK_DYNAMIC_FILE"
            echo "      service: dozzle" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "      priority: 10" >> "$TRAEFIK_DYNAMIC_FILE"
        fi
    fi
    
    # Ajout des middlewares
    if [ -n "$middlewares" ]; then
        echo "" >> "$TRAEFIK_DYNAMIC_FILE"
        echo "  middlewares:$middlewares" >> "$TRAEFIK_DYNAMIC_FILE"
    fi

    # Ajout des services
    if [ -n "$services" ] || [ "$DOZZLE_ENABLED" = "true" ]; then
        echo "" >> "$TRAEFIK_DYNAMIC_FILE"
        echo "  services:$services" >> "$TRAEFIK_DYNAMIC_FILE"

        # Ajouter le service Dozzle si activé
        if [ "$DOZZLE_ENABLED" = "true" ]; then
            echo "    dozzle:" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "      loadBalancer:" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "        healthCheck:" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "          path: /logs" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "          interval: 5s" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "          timeout: 2s" >> "$TRAEFIK_DYNAMIC_FILE"
            echo "        servers:" >> "$TRAEFIK_DYNAMIC_FILE"
            echo '          - url: "http://dozzle:8080"' >> "$TRAEFIK_DYNAMIC_FILE"
            echo "        passHostHeader: true" >> "$TRAEFIK_DYNAMIC_FILE"
        fi
    fi

    echo -e "\033[92m✅ traefik/dynamic.yml généré\033[0m"
}

# Détecte les variables de secrets des profils activés, sans SOPS ni déchiffrement.
# Résultat dans le tableau associatif global SECRET_VARS (nom -> valeur par défaut).
detect_secret_vars() {
    declare -gA SECRET_VARS=()
    local profile

    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue
        
        read_yaml_fields "$profile" .enabled .name
        local enabled
        enabled=$(value_or_default "${YAML_FIELDS[0]}" true)
        [ "$enabled" != "true" ] && continue

        local profile_name
        profile_name=$(value_or_default "${YAML_FIELDS[1]}" "$(basename "$profile" .yml)")

        # Méthode 1 : section secrets: (même vide, elle désactive l'auto-détection)
        if grep -q "^secrets:" "$profile"; then
            # Un secret par ligne : nom, valeur par défaut, description, type YAML de la
            # valeur par défaut (séparateur US, \x1f). Une valeur par défaut présente est
            # conservée telle quelle, même 0, false ou "" ; absente ou null : "changeme".
            # (pas d'opérateur yq '//' ici : il remplacerait aussi false)
            local sep=$'\x1f'
            local secret_name secret_default secret_desc default_tag
            while IFS="$sep" read -r secret_name secret_default secret_desc default_tag; do
                [ "$default_tag" = "!!null" ] && secret_default="changeme"

                if [ -n "$secret_name" ] && [ -z "${SECRET_VARS[$secret_name]+x}" ]; then
                    SECRET_VARS["$secret_name"]="$secret_default"
                    echo -e "  \033[90m📌 [$profile_name] $secret_name ($secret_desc)\033[0m"
                fi
            done < <(yq e ".secrets[] | [.name, .default, .description, (.default | tag)] | (.[] | select(tag == \"!!null\")) = \"\" | join(\"$sep\")" "$profile" 2>/dev/null || true)
        else
            # Méthode 2 (fallback, profil sans section secrets:) : variables ${VAR:-defaut}
            # des entrées de docker-compose.environment uniquement.
            # L'image, les ports et les commentaires ne sont pas des secrets.
            while IFS= read -r match; do
                local var_name
                var_name=$(echo "$match" | sed 's/.*\${\([A-Z_][A-Z0-9_]*\).*/\1/')
                local default_value
                default_value=$(echo "$match" | sed 's/.*:-\([^}]*\)}.*/\1/')
                [ -z "$default_value" ] && default_value="changeme"
            
                if [ -n "$var_name" ] && [ -z "${SECRET_VARS[$var_name]+x}" ]; then
                    SECRET_VARS["$var_name"]="$default_value"
                    echo -e "  \033[90m📌 [$profile_name] $var_name (auto-détecté)\033[0m"
                fi
            done < <(yq e '.docker-compose.environment[]' "$profile" 2>/dev/null | grep -o '\${[A-Z_][A-Z0-9_]*:-[^}]*}' || true)
        fi
    done
}

# Affiche les noms des variables de secrets détectées, triés, un par ligne
list_secret_vars() {
    detect_secret_vars > /dev/null
    [ ${#SECRET_VARS[@]} -eq 0 ] && return 0
    printf '%s\n' "${!SECRET_VARS[@]}" | LC_ALL=C sort
}

# Fonction pour synchroniser secrets.env
sync_secrets() {
    echo -e "\n\033[96m🔄 SYNCHRONISATION DES SECRETS\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    
    # Vérifier SOPS
    if ! command -v sops &> /dev/null; then
        echo -e "\033[91mSOPS n'est pas installé. Cette fonctionnalité nécessite SOPS.\033[0m"
        echo -e "\n  \033[93m💡 Installez SOPS : https://github.com/mozilla/sops/releases\033[0m"
        return 1
    fi
    
    # Vérifier la configuration SOPS
    if [ ! -f ".sops.yaml" ]; then
        echo -e "\033[91mFichier .sops.yaml introuvable. Configurez SOPS d'abord.\033[0m"
        return 1
    fi
    
    if ! grep -qE '(kms:|age:)' ".sops.yaml"; then
        echo -e "\033[93mSOPS n'est pas configuré avec une clé KMS ou Age.\033[0m"
        echo -e "\n  \033[93m💡 Éditez .sops.yaml et configurez :\033[0m"
        echo -e "     \033[90m- AWS KMS : kms: 'arn:aws:kms:...'\033[0m"
        echo -e "     \033[90m- Age : age: 'age1...'\033[0m"
        echo -e "\n  \033[93mPour générer une clé Age :\033[0m"
        echo -e "     \033[90mage-keygen -o age-key.txt\033[0m"
        return 1
    fi
    
    # Récupérer toutes les variables des profils
    detect_secret_vars
    
    if [ ${#SECRET_VARS[@]} -eq 0 ]; then
        echo -e "  \033[93mℹ️  Aucune variable de secrets trouvée dans les profils\033[0m"
        return 0
    fi
    
    echo -e "\n  \033[96mTotal: ${#SECRET_VARS[@]} variable(s) trouvée(s)\033[0m"
    
    # Lire le fichier secrets.env existant
    declare -A existing_secrets
    local secrets_content=""
    
    if [ -f "$SECRETS_FILE" ]; then
        # Ne pas continuer si le déchiffrement échoue : le fichier existant serait écrasé
        if ! secrets_content=$(sops -d "$SECRETS_FILE"); then
            echo -e "\033[91mImpossible de déchiffrer $SECRETS_FILE - aucune modification effectuée.\033[0m"
            echo -e "\033[93mVérifiez votre clé SOPS, ou supprimez le fichier pour repartir de zéro.\033[0m"
            return 1
        fi

        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                existing_secrets["$key"]="$value"
            fi
        done <<< "$secrets_content"
        echo -e "\n  \033[92m✅ Fichier secrets.env déchiffré (${#existing_secrets[@]} variables existantes)\033[0m"
    fi

    # Identifier les nouvelles variables
    declare -A new_vars
    for var in "${!SECRET_VARS[@]}"; do
        # ${...+x} : une variable présente avec une valeur vide (FOO=) existe déjà
        if [ -z "${existing_secrets[$var]+x}" ]; then
            new_vars["$var"]="${SECRET_VARS[$var]}"
        fi
    done
    
    if [ ${#new_vars[@]} -eq 0 ]; then
        echo -e "\n  \033[92m✅ Toutes les variables sont déjà présentes dans secrets.env\033[0m"
        return 0
    fi
    
    echo -e "\n  \033[93m📝 Variables manquantes à ajouter:\033[0m"
    for var in "${!new_vars[@]}"; do
        echo -e "     \033[90m- $var\033[0m"
    done
    
    # Demander confirmation
    read -p $'\n  Ajouter ces variables à secrets.env ? (o/N): ' confirm
    if [ "$confirm" != "o" ]; then
        echo -e "  \033[93m⏭️  Annulé\033[0m"
        return 0
    fi
    
    # Construire le nouveau contenu
    local new_content="$secrets_content"
    [ -n "$new_content" ] && new_content="${new_content}"$'\n'
    new_content="${new_content}"$'\n'"# Variables ajoutées automatiquement le $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    while IFS= read -r var; do
        new_content="${new_content}${var}=${new_vars[$var]}"$'\n'
    done < <(printf '%s\n' "${!new_vars[@]}" | LC_ALL=C sort)
    
    # Chiffrer via stdin : le contenu en clair n'est jamais écrit sur disque.
    # --filename-override fait appliquer à SOPS les règles .sops.yaml de secrets.env
    local encrypted
    if encrypted=$(printf '%s' "$new_content" | sops -e --filename-override "$SECRETS_FILE" /dev/stdin); then
        printf '%s\n' "$encrypted" > "$SECRETS_FILE"
        echo -e "\n  \033[92m✅ secrets.env mis à jour et rechiffré (${#new_vars[@]} variable(s) ajoutée(s))\033[0m"
    else
        echo -e "\033[91mErreur lors du chiffrement - $SECRETS_FILE n'a pas été modifié\033[0m"
        return 1
    fi
}

# Fonction pour initialiser secrets.env
init_secrets() {
    echo -e "\n\033[96m🔐 INITIALISATION DES SECRETS\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    
    if [ -f "$SECRETS_FILE" ]; then
        echo -e "\033[93mLe fichier $SECRETS_FILE existe déjà\033[0m"
        read -p "Écraser ? (o/N): " overwrite
        [ "$overwrite" != "o" ] && return 0
    fi
    
    # Vérifier SOPS
    if ! command -v sops &> /dev/null; then
        echo -e "\033[91mSOPS n'est pas installé. Installez-le d'abord.\033[0m"
        return 1
    fi
    
    if [ ! -f ".sops.yaml" ]; then
        echo -e "\033[91mFichier .sops.yaml introuvable. Configurez SOPS d'abord (voir docs/sops_age_guide.md).\033[0m"
        return 1
    fi

    # Copier l'exemple
    if [ -f "secrets.env.example" ]; then
        cp "secrets.env.example" "$SECRETS_FILE"
    else
        echo "# Secrets file - Edit with: sops secrets.env" > "$SECRETS_FILE"
    fi

    # Chiffrer immédiatement : un secrets.env en clair ne doit jamais rester sur disque
    if ! sops --encrypt --in-place "$SECRETS_FILE"; then
        rm -f "$SECRETS_FILE"
        echo -e "\033[91mÉchec du chiffrement SOPS - $SECRETS_FILE supprimé. Vérifiez .sops.yaml.\033[0m"
        return 1
    fi

    echo -e "\n\033[92m✅ Fichier $SECRETS_FILE créé et chiffré\033[0m"
    echo -e "\033[93m📝 Éditez-le maintenant avec: sops $SECRETS_FILE\033[0m"
    
    read -p $'\nOuvrir l\'éditeur SOPS maintenant ? (O/n): ' open_editor
    if [ "$open_editor" != "n" ]; then
        sops "$SECRETS_FILE"
    fi
}

# Main
case "$ACTION" in
    add)
        add_profile
        ;;
    list)
        if [ "$JSON_OUTPUT" = true ]; then
            show_profiles_json
        else
            show_profiles
        fi
        ;;
    generate)
        if [ "$DRY_RUN" = true ]; then
            generate_dry_run
        else
            generate_docker_compose
        fi
        ;;
    init-secrets)
        init_secrets
        ;;
    sync-secrets)
        sync_secrets
        ;;
    list-secrets)
        list_secret_vars
        ;;
    *)
        usage_error "Action inconnue: $ACTION"
        ;;
esac
