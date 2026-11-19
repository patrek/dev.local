#!/bin/bash
# Gestionnaire de profils pour Dev.Local 2.0
# Script pour ajouter, modifier, supprimer et lister des profils de services
# Génère automatiquement docker-compose.yml et la configuration Traefik

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

ACTION="${1:-list}"
PROFILES_DIR="profiles"
DOCKER_COMPOSE_FILE="docker-compose.yml"
TRAEFIK_DYNAMIC_FILE="traefik/dynamic.yml"
SECRETS_FILE="secrets.env"
CONFIG_FILE="config.yml"

# Configuration par défaut
DOZZLE_ENABLED=true
DOZZLE_PORT=9999
NAMESPACE="default"

# yq local ou via Docker (voir lib/yq.sh)
source "lib/yq.sh"

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

# Lit plusieurs champs scalaires d'un fichier YAML en un seul appel yq.
# Usage : read_yaml_fields <fichier> <chemin>...
# Résultat dans le tableau YAML_FIELDS (même ordre que les chemins, "null" si absent).
read_yaml_fields() {
    local file="$1"
    shift
    local expr
    expr=$(IFS=,; echo "$*")
    mapfile -t YAML_FIELDS < <(yq e "$expr" "$file" 2>/dev/null)
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

# Extraire le nom de la clé YAML d'une ligne (ex: "  image: nginx" -> "image")
# Usage: key_from_line "  image: nginx"
key_from_line() {
    echo "$1" | sed -E 's/:[[:space:]].*//; s/:[[:space:]]*$//'
}

# Insérer du contenu après la première ligne dont la clé correspond
# Usage: insert_content_after_key "$text" "$content" "key1|key2"
# Retourne le texte modifié via stdout
insert_content_after_key() {
    local text="$1"
    local content="$2"
    local keys_pattern="$3"
    local result=""
    local inserted=false

    while IFS= read -r line; do
        result="${result}${line}"$'\n'
        if [ "$inserted" = false ] && echo "$line" | grep -qE "^ *(${keys_pattern})"; then
            result="${result}${content}"$'\n'
            inserted=true
        fi
    done <<< "$text"

    printf '%s' "$result"
}

# Nettoyer un item YAML : supprime commentaires inline, espaces, et guillemets
# Usage: clean_yaml_item "item" [strip_dash] [strip_quotes]
clean_yaml_item() {
    local item="$1"
    [ -z "$item" ] && return
    local strip_dash="${2:-false}"
    local strip_quotes="${3:-false}"

    # Supprimer les commentaires inline et les espaces
    item=$(echo "$item" | sed -E 's/[[:space:]]+#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')

    # Supprimer le tiret YAML si demandé
    if [ "$strip_dash" = true ]; then
      item=$(echo "$item" | sed -E 's/^-[[:space:]]*//')
    fi

    # Supprimer les guillemets si demandé
    if [ "$strip_quotes" = true ]; then
        item=$(echo "$item" | sed -E 's/^"(.*)"$/\1/')
    fi

    printf '%s' "$item"
}

# Block normalization
# Usage: normalize_block "block" [indent_level] [output_format]
#   indent_level: 2 or 4 (default: 4)
#   output_format: "list" (default) or "map"
# Converts any block format (list, map, raw key=value) to normalized output
normalize_block() {
    local block="$1"
    local indent="${2:-4}"
    local format="${3:-list}"
    local result=""
    local prefix
    prefix=$(printf '%*s' "$indent" '')

    [ -z "$block" ] && { printf '%s' "$result"; return; }

    # Detect input format
    local is_list_dash=false
    local is_map=false
    local is_list_raw=false

    if echo "$block" | grep -qE "^[[:space:]]*[-][[:space:]]"; then
        is_list_dash=true
    elif echo "$block" | grep -qE "^[[:space:]]+[A-Z_]+:"; then
        is_map=true
    elif echo "$block" | sed 's/^[[:space:]]*//' | grep -qE "^[A-Z_]+=.+" || echo "$block" | sed 's/^[[:space:]]*//' | grep -qvE "^[[:space:]]*$|#|^[[:space:]]*[A-Za-z_]+:"; then
        is_list_raw=true
    fi

    if [ "$is_list_dash" = true ] && [ "$format" = "list" ]; then
        while IFS= read -r item; do
            item=$(clean_yaml_item "$item" true false)
            [ -n "$item" ] && result="${result}${prefix}- ${item}"$'\n'
        done <<< "$block"
    elif [ "$is_map" = true ]; then
        if [ "$format" = "map" ]; then
            while IFS= read -r item; do
                item=$(clean_yaml_item "$item" false false)
                [ -z "$item" ] && continue
                local k v
                k=$(echo "$item" | cut -d: -f1)
                v=$(echo "$item" | cut -d: -f2- | sed -E 's/^[[:space:]]+//; s/^"(.*)"$/\1/')
                [ -n "$k" ] && result="${result}${prefix}${k}: ${v}"$'\n'
            done <<< "$block"
        else
            while IFS= read -r item; do
                item=$(clean_yaml_item "$item" false false)
                [ -z "$item" ] && continue
                local k v
                k=$(echo "$item" | cut -d: -f1)
                v=$(echo "$item" | cut -d: -f2- | sed -E 's/^[[:space:]]+//')
                v=$(clean_yaml_item "$v" false true)
                [ -n "$k" ] && result="${result}${prefix}- ${k}=${v}"$'\n'
            done <<< "$block"
        fi
    elif [ "$is_list_raw" = true ]; then
        while IFS= read -r item; do
            item=$(clean_yaml_item "$item" false false)
            [ -n "$item" ] && result="${result}${prefix}- ${item}"$'\n'
        done <<< "$block"
    fi

    printf '%s' "$result"
}

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
# puis les groupes service_specific du service. Rien si le service est exclu.
get_shared_env_vars() {
    local service_name="$1"

    [ -f "$CONFIG_FILE" ] || return 0
    [ "$SHARED_ENV_ENABLED" = "false" ] && return 0

    local excluded
    for excluded in "${SHARED_ENV_EXCLUDED[@]}"; do
        [ "$excluded" = "$service_name" ] && return 0
    done

    yq e ".shared_env as \$env
        | ((.shared_env_config.auto_inject // []) + (.shared_env_config.service_specific[\"$service_name\"] // []))
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

# Fonction pour ajouter un profil
add_profile() {
    echo -e "\n\033[96m➕ AJOUTER UN NOUVEAU PROFIL\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    
    # Collecter les informations
    read -p $'\nNom du service (ex: api-backend, frontend): ' name
    if [ -z "$name" ]; then
        echo -e "\033[91mLe nom est requis\033[0m"
        return 1
    fi
    
    # Nettoyer le nom
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    filename="$PROFILES_DIR/$name.yml"
    
    if [ -f "$filename" ]; then
        echo -e "\033[91mUn profil '$name' existe déjà !\033[0m"
        return 1
    fi
    
    read -p "Description du service: " description
    read -p "Image Docker (ex: nginx:latest, registry.io/myapp:v1.0): " image
    read -p "Port interne du conteneur (ex: 80, 8000): " docker_port
    read -p "Port exposé localement (via Traefik host) (ex: 8001): " local_port
    [ -z "$docker_port" ] && docker_port="80"
    [ -z "$local_port" ] && local_port=$docker_port
    
    # Port mapping docker-compose (host:container) can be same as local_port:docker_port or different
    # Par défaut le service n'est joignable que via Traefik ; publier un port est optionnel
    read -p "Publier aussi un port sur l'hôte (hôte:conteneur, ex: 9000:$docker_port, Entrée pour aucun): " host_binding
    expose_ports="false"
    ports_section=""
    if [ -n "$host_binding" ] && [ "$host_binding" != "none" ]; then
        expose_ports="true"
        ports_section=$'\n'"  ports:"$'\n'"    - \"$host_binding\""
    fi
    
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
        secret_var=$(echo "$secret" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]/_/g')
        read -p "  Description de $secret_var (optionnel): " secret_desc
        [ -z "$secret_desc" ] && secret_desc="Secret pour $name"
        
        secrets="${secrets}    - ${secret_var}=\${${secret_var}:-changeme}"$'\n'
        secrets_doc="${secrets_doc}  - name: ${secret_var}"$'\n'"    description: \"${secret_desc}\""$'\n'"    default: changeme"$'\n'
    done
    
    # Combiner env vars et secrets
    all_env="${env_vars}${secrets}"
    [ -z "$all_env" ] && all_env="    # Aucune variable d'environnement"
    
    # Section secrets si nécessaire
    secrets_section=""
    if [ -n "$secrets_doc" ]; then
        secrets_section=$'\n'"# Variables de secrets requises (à définir dans secrets.env)"$'\n'"secrets:"$'\n'"${secrets_doc}"
    fi
    
    # Générer le fichier YAML
    mkdir -p "$PROFILES_DIR"
    cat > "$filename" << EOF
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
    
    # Proposer de regénérer docker-compose.yml
    read -p $'\nRegénérer docker-compose.yml maintenant ? (O/n): ' regen
    if [ "$regen" != "n" ]; then
        generate_docker_compose
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

        # Les volumes nommés suivent les cinq champs scalaires (même appel yq)
        read_yaml_fields "$profile" .enabled .name .always_active .docker_profile .expose_ports "$NAMED_VOLUMES_EXPR"
        local enabled
        enabled=$(value_or_default "${YAML_FIELDS[0]}" true)
        if [ "$enabled" != "true" ]; then
            echo -e "  \033[90m⏭️  Ignoré (désactivé) : $(basename "$profile" .yml)\033[0m"
            continue
        fi
        named_volumes+=("${YAML_FIELDS[@]:5}")

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

        # Extraire la section docker-compose:
        local compose_section
        compose_section=$(sed -n '/^docker-compose:/,/^[a-z]/{//!p}' "$profile")

        # Traiter la section environment pour injecter les variables partagées
        local filtered_compose=""
        local in_ports=false
        local ports_ignored=false
        local environment_block=""
        local environment_indent=""

        while IFS= read -r line; do
            # Gérer la section ports : publiée sur 127.0.0.1 si expose_ports, retirée sinon
            if echo "$line" | grep -q "^  ports:"; then
                in_ports=true
                if [ "$expose_ports" = "true" ]; then
                    filtered_compose="${filtered_compose}${line}"$'\n'
                else
                    ports_ignored=true
                fi
                continue
            fi
            if [ "$in_ports" = true ]; then
                if echo "$line" | grep -q "^    "; then
                    if [ "$expose_ports" = "true" ]; then
                        filtered_compose="${filtered_compose}$(bind_port_to_localhost "$line")"$'\n'
                    fi
                    continue
                else
                    in_ports=false
                fi
            fi

            # Détecter et capturer le bloc environment
            if echo "$line" | grep -q "^  environment:"; then
                environment_indent=$(echo "$line" | sed 's/[^ ].*//')
                environment_block=""
                continue
            fi

            # Capturer les items environment (indentés)
            if [ -n "$environment_indent" ]; then
                local line_indent
                line_indent=$(echo "$line" | sed 's/[^ ].*//')
                if [ "${#line_indent}" -gt "${#environment_indent}" ] || echo "$line" | grep -q "^[[:space:]]*[-]"; then
                    environment_block="${environment_block}${line}"$'\n'
                    continue
                else
                    environment_indent=""
                fi
            fi

            filtered_compose="${filtered_compose}${line}"$'\n'
        done <<< "$compose_section"

        if [ "$ports_ignored" = true ]; then
            echo -e "    \033[90m🔒 Ports non publiés (expose_ports: true pour les publier sur 127.0.0.1)\033[0m"
        fi

        # Gérer le cas où le fichier se termine dans un bloc environment
        if [ -n "$environment_indent" ] && [ -n "$environment_block" ]; then
            environment_block=$(normalize_block "$environment_block" 4 "list")
            environment_indent=""
        fi

        # Construire et injecter le bloc environment complet
        if [ -n "$shared_env_vars" ] || [ -n "$environment_block" ]; then
            local env_body=""
            if [ -n "$shared_env_vars" ]; then
                env_body+="    # Variables partagées (depuis config.yml)"$'\n'
                while IFS= read -r var; do
                    [ -n "$var" ] && env_body+="    - ${var}"$'\n'
                done <<< "$shared_env_vars"
            fi
            local svc_items=""
            if [ -n "$environment_block" ]; then
                svc_items=$(normalize_block "$environment_block")
                if [ -n "$svc_items" ]; then
                    if [ -n "$shared_env_vars" ]; then
                        env_body+="    # Variables exclusives du service"$'\n'
                    fi
                    env_body+="${svc_items}"$'\n'
                fi
            fi

            local complete_env_section
            complete_env_section="  environment:"$'\n'"${env_body}"
            filtered_compose=$(insert_content_after_key "$filtered_compose" "$complete_env_section" "container_name|image")
        fi

        # Ajouter 2 espaces d'indentation
        local indented
        indented=$(echo "$filtered_compose" | sed 's/^  /    /')

        # Nettoyer l'indentation (retirer les lignes vides en fin)
        indented=$(echo "$indented" | sed -e :a -e '/^\s*$/d;N;ba')

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
    
    mkdir -p "traefik"
    
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
            # Un secret par ligne : nom, valeur par défaut, description (séparateur US, \x1f)
            local sep=$'\x1f'
            local secret_name secret_default secret_desc
            while IFS="$sep" read -r secret_name secret_default secret_desc; do
                [ -z "$secret_default" ] && secret_default="changeme"

                if [ -n "$secret_name" ] && [ -z "${SECRET_VARS[$secret_name]}" ]; then
                    SECRET_VARS["$secret_name"]="$secret_default"
                    echo -e "  \033[90m📌 [$profile_name] $secret_name ($secret_desc)\033[0m"
                fi
            done < <(yq e ".secrets[] | [.name // \"\", .default // \"\", .description // \"\"] | join(\"$sep\")" "$profile" 2>/dev/null || true)
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
            
                if [ -n "$var_name" ] && [ -z "${SECRET_VARS[$var_name]}" ]; then
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
        if [ -z "${existing_secrets[$var]}" ]; then
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
    for var in $(echo "${!new_vars[@]}" | tr ' ' '\n' | sort); do
        new_content="${new_content}${var}=${new_vars[$var]}"$'\n'
    done
    
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
        show_profiles
        ;;
    generate)
        generate_docker_compose
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
        show_profiles
        ;;
esac
