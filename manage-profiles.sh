#!/bin/bash
# Gestionnaire de profils pour Dev.Local 2.0
# Script pour ajouter, modifier, supprimer et lister des profils de services
# Génère automatiquement docker-compose.yml et la configuration Traefik

set -e

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

# Détection robuste de yq (mikefarah v4+)
YQ_CMD=""
detect_yq() {
    # Vérifier si yq est installé
    if ! command -v yq >/dev/null 2>&1; then
        return 1
    fi

    # Vérifier qu'il s'agit de mikefarah/yq (pas kislyuk/yq)
    # mikefarah/yq a une commande 'eval' ou 'e', kislyuk n'en a pas
    if yq --help 2>&1 | grep -q "eval"; then
        # Vérifier la version (v4+)
        local version
        version=$(yq --version 2>&1 | grep -oP 'version [v]?\K[0-9]+' | head -1)
        if [ -n "$version" ] && [ "$version" -ge 4 ]; then
            YQ_CMD="yq"
            return 0
        fi
    fi

    # Si ce n'est pas mikefarah v4+, ne pas utiliser yq
    return 1
}

# Activer yq si disponible et compatible
if detect_yq; then
    echo -e "\033[92m✓ yq (mikefarah v4+) détecté - parsing YAML robuste activé\033[0m" >&2
else
    echo -e "\033[93m⚠ yq non disponible ou version incompatible - utilisation du fallback sed/grep\033[0m" >&2
    echo -e "\033[93m  Installez yq v4+ pour un parsing plus fiable: https://github.com/mikefarah/yq\033[0m" >&2
fi

# Charger la configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        if [ -n "$YQ_CMD" ]; then
            # Using yq for robust parsing
            DOZZLE_ENABLED=$(yq e '.dozzle_enabled // true' "$CONFIG_FILE" 2>/dev/null)
            DOZZLE_PORT=$(yq e '.dozzle_port // 9999' "$CONFIG_FILE" 2>/dev/null)
            NAMESPACE=$(yq e '.namespace // "devlocal"' "$CONFIG_FILE" 2>/dev/null)
        else
            if grep -q "dozzle_enabled: false" "$CONFIG_FILE" 2>/dev/null; then
                DOZZLE_ENABLED=false
            fi
            # Extraire seulement le nombre du port (ignorer le commentaire #)
            local port
            port=$(grep "dozzle_port:" "$CONFIG_FILE" 2>/dev/null | sed 's/.*dozzle_port: *//; s/ *#.*//' | tr -d '\r')
            if [ -n "$port" ]; then
                DOZZLE_PORT=$port
            fi

            # Extraire la valeur namespace si presente
            local ns_line
            ns_line=$(grep -E '^[[:space:]]*namespace:' "$CONFIG_FILE" 2>/dev/null | head -n1 || true)
            if [ -n "$ns_line" ]; then
                NAMESPACE=$(echo "$ns_line" | sed -E 's/^[[:space:]]*namespace:[[:space:]]*//; s/"//g; s/[[:space:]]+#.*//' | tr -d '\r')
                if [ -z "$NAMESPACE" ]; then
                    NAMESPACE="devlocal"
                fi
            fi
        fi
    fi
}

# Fonction pour charger les variables d'environnement partagées
get_shared_env_vars() {
    local service_name="$1"
    local shared_vars=""

    [ ! -f "$CONFIG_FILE" ] && echo "" && return

    if [ -n "$YQ_CMD" ]; then
        # yq-based implementation
        local enabled
        enabled=$(yq e '.shared_env_config.enabled // true' "$CONFIG_FILE" 2>/dev/null)
        [ "$enabled" = "false" ] && echo "" && return

        # auto_inject groups
        local groups
        groups=$(yq e '.shared_env_config.auto_inject[]? // []' "$CONFIG_FILE" 2>/dev/null || true)

        # service specific groups
        if [ -n "$service_name" ]; then
            local svc_groups
            svc_groups=$(yq e ".shared_env_config.service_specific.${service_name}[]? // []" "$CONFIG_FILE" 2>/dev/null || true)
            if [ -n "$svc_groups" ]; then
                groups="$groups\n$svc_groups"
            fi
        fi

        # iterate groups and collect variables
        while IFS= read -r grp; do
            [ -z "$grp" ] && continue
            # for each group, get the list under shared_env.<group>
            while IFS= read -r v; do
                # Filtrer les valeurs vides et la chaîne littérale "[]"
                [ -n "$v" ] && [ "$v" != "[]" ] && shared_vars="$shared_vars$v"$'\n'
            done < <(yq e ".shared_env.${grp}[]? // []" "$CONFIG_FILE" 2>/dev/null || true)
        done <<< "$groups"

        echo "$shared_vars"
        return
    fi

    # Fallback: original grep/sed implementation
    local enabled
    enabled=$(grep -A 10 "^shared_env_config:" "$CONFIG_FILE" | grep "enabled:" | sed 's/.*enabled: *//; s/ *#.*//' | tr -d '\r' | head -1)
    [ "$enabled" = "false" ] && echo "" && return

    # Récupérer les groupes auto_inject
    local auto_inject_groups=""
    local in_auto_inject=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "^  auto_inject:"; then
            in_auto_inject=true
            continue
        fi
        if [ "$in_auto_inject" = true ]; then
            if echo "$line" | grep -q "^    - "; then
                local group
                group=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*//; s/[[:space:]]+$//' | tr -d '\r')
                auto_inject_groups="${auto_inject_groups} ${group}"
            else
                break
            fi
        fi
    done < "$CONFIG_FILE"

    # Vérifier si le service est exclu
    if [ -n "$service_name" ]; then
        local in_exclude=false
        while IFS= read -r line; do
            if echo "$line" | grep -q "^  exclude_services:"; then
                in_exclude=true
                continue
            fi
            if [ "$in_exclude" = true ]; then
                if echo "$line" | grep -q "^    - "; then
                    local excluded_service
                    excluded_service=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*//; s/[[:space:]]+$//' | tr -d '\r')
                    if [ "$excluded_service" = "$service_name" ]; then
                        echo ""
                        return
                    fi
                else
                    break
                fi
            fi
        done < "$CONFIG_FILE"
    fi

    # Récupérer les groupes service_specific pour ce service
    local service_groups=""
    if [ -n "$service_name" ]; then
        local in_service_specific=false
        local in_current_service=false
        while IFS= read -r line; do
            if echo "$line" | grep -q "^  service_specific:"; then
                in_service_specific=true
                continue
            fi
            if [ "$in_service_specific" = true ]; then
                if echo "$line" | grep -q "^    ${service_name}:"; then
                    in_current_service=true
                    continue
                fi
                if [ "$in_current_service" = true ]; then
                    if echo "$line" | grep -q "^      - "; then
                        local group
                        group=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*//; s/[[:space:]]+$//' | tr -d '\r')
                        service_groups="${service_groups} ${group}"
                    else
                        in_current_service=false
                        if [ "$(echo "$line" | grep -c "^    [a-z]")" -eq 0 ]; then
                            break
                        fi
                    fi
                fi
            fi
        done < "$CONFIG_FILE"
    fi

    # Combiner tous les groupes
    local all_groups
    all_groups="${auto_inject_groups} ${service_groups}"

    # Extraire les variables de chaque groupe
    for group in $all_groups; do
        [ -z "$group" ] && continue

        local in_shared_env=false
        local in_group=false
        while IFS= read -r line; do
            if echo "$line" | grep -q "^shared_env:"; then
                in_shared_env=true
                continue
            fi
            if [ "$in_shared_env" = true ]; then
                if echo "$line" | grep -q "^  ${group}:"; then
                    in_group=true
                    continue
                fi
                if [ "$in_group" = true ]; then
                    if echo "$line" | grep -q "^    - "; then
                        local var
                        # Fix: strip only the YAML list marker, preserve hyphens in values
                        var=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*//; s/[[:space:]]+$//' | tr -d '\r')
                        shared_vars="${shared_vars}${var}"$'\n'
                    elif echo "$line" | grep -qE "^[[:space:]]+#"; then
                        # Skip comment lines within the list (at list item indentation or deeper)
                        continue
                    else
                        in_group=false
                        if [ "$(echo "$line" | grep -c "^  [a-z]")" -eq 0 ]; then
                            break
                        fi
                    fi
                fi
            fi
        done < "$CONFIG_FILE"
    done

    echo "$shared_vars"
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
        local name
        name=$(grep -m1 "^name:" "$profile" | sed 's/name: *//; s/ *#.*//' | tr -d '\r' || echo "${basename%.yml}")
        local enabled
        enabled=$(grep -m1 "^enabled:" "$profile" | sed 's/enabled: *//; s/ *#.*//' | tr -d '\r' || echo "true")
        local description
        description=$(grep -m1 '^description:' "$profile" | sed -E 's/description: *"//; s/"$//; s/[[:space:]]+#.*//' | tr -d '\r' || echo "Sans description")

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
    read -p "Port binding Docker (host:container) (Entrée pour utiliser $local_port:$docker_port, 'none' pour aucun): " host_binding
    if [ -z "$host_binding" ]; then
        host_binding="$local_port:$docker_port"
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

docker-compose:
  image: $image
  container_name: $name
  ports:
    - "$host_binding"
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
  # Reverse Proxy Traefik
  traefik:
    image: traefik:v3.6.4
    container_name: ${COMPOSE_PROJECT_NAME:-devlocal}_traefik
    ports:
      - "8080:80"
      - "8081:8080"
    extra_hosts:
      - "external-ip:host-gateway"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro
    networks:
      - traefik-network
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
    image: amir20/dozzle:latest
    container_name: ${COMPOSE_PROJECT_NAME:-devlocal}_dozzle
    ports:
      - "$DOZZLE_PORT:8080"
    environment:
      - DOZZLE_TIMEOUT=15s
      - DOZZLE_BASE=/logs
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    extra_hosts:
      - "external-ip:host-gateway"
    networks:
      - traefik-network
    healthcheck:
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 3s
      timeout: 30s

EOF
    fi
    
    # Ajouter chaque service
    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue
        
        local enabled
        enabled=$(grep -m1 "^enabled:" "$profile" | sed 's/enabled: *//; s/ *#.*//' | tr -d '\r' || echo "true")
        if [ "$enabled" != "true" ]; then
            echo -e "  \033[90m⏭️  Ignoré (désactivé) : $(basename "$profile" .yml)\033[0m"
            continue
        fi
        
        local name
        name=$(grep -m1 "^name:" "$profile" | sed 's/name: *//; s/ *#.*//' | tr -d '\r' || basename "$profile" .yml)
        echo -e "  \033[92m✅ Ajout : $(basename "$profile" .yml)\033[0m"

        # Charger les variables partagées pour ce service
        local shared_env_vars
        shared_env_vars=$(get_shared_env_vars "$name")
        local shared_count=0
        if [ -n "$shared_env_vars" ]; then
            shared_count=$(echo "$shared_env_vars" | grep -c "^" || echo 0)
            echo -e "    \033[90m📌 $shared_count variable(s) partagée(s)\033[0m"
        fi

        local always_active
        always_active=$(grep -m1 "^always_active:" "$profile" | sed 's/always_active: *//; s/ *#.*//' | tr -d '\r' || echo "true")
        local docker_profile_raw
        docker_profile_raw=$(grep -m1 "^docker_profile:" "$profile" | sed 's/docker_profile: *//; s/ *#.*//' | tr -d '\r')
        # Considérer null, vide, ou whitespace comme absence de profil
        local docker_profile
        docker_profile=$(echo "$docker_profile_raw" | xargs)  # trim whitespace
        if [ "$docker_profile" = "null" ] || [ -z "$docker_profile" ]; then
            docker_profile=""
        fi

        # Extraire la section docker-compose:
        local compose_section
        compose_section=$(sed -n '/^docker-compose:/,/^[a-z]/{//!p}' "$profile")

        # Traiter la section environment pour injecter les variables partagées
        local filtered_compose=""
        local in_ports=false
        local environment_found=false

        while IFS= read -r line; do
            # Gérer la section ports
            if echo "$line" | grep -q "^  ports:"; then
                in_ports=true
                continue
            fi
            if [ "$in_ports" = true ]; then
                if echo "$line" | grep -q "^    "; then
                    continue
                else
                    in_ports=false
                fi
            fi

            # Détecter la section environment
            if echo "$line" | grep -q "^  environment:"; then
                environment_found=true
                filtered_compose="${filtered_compose}${line}"$'\n'

                # Injecter les variables partagées juste après environment:
                if [ -n "$shared_env_vars" ]; then
                    filtered_compose="${filtered_compose}    # Variables partagées (depuis config.yml)"$'\n'
                    while IFS= read -r var; do
                        [ -n "$var" ] && filtered_compose="${filtered_compose}    - ${var}"$'\n'
                    done <<< "$shared_env_vars"
                    # Séparateur pour les variables propres au service
                    filtered_compose="${filtered_compose}    # Variables exclusives du service"$'\n'
                fi
                continue
            fi

            filtered_compose="${filtered_compose}${line}"$'\n'
        done <<< "$compose_section"
        
        # Si pas de section environment, en créer une avec les variables partagées
        if [ "$environment_found" = false ] && [ -n "$shared_env_vars" ]; then
            local new_compose=""
            local added=false
            while IFS= read -r line; do
                new_compose="${new_compose}${line}"$'\n'
                # Ajouter environment après image/container_name
                if [ "$added" = false ] && echo "$line" | grep -q "^  container_name:"; then
                    new_compose="${new_compose}  environment:"$'\n'
                    new_compose="${new_compose}    # Variables partagées (depuis config.yml)"$'\n'
                    while IFS= read -r var; do
                        [ -n "$var" ] && new_compose="${new_compose}    - ${var}"$'\n'
                    done <<< "$shared_env_vars"
                    added=true
                fi
            done <<< "$filtered_compose"
            filtered_compose="$new_compose"
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
EOF
    
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

        # Parse avec yq si disponible, sinon fallback grep/sed
        local enabled
        local traefik_enabled
        local name
        local local_port
        local docker_port
        local health_path
        local prefix
        local strip_prefix
        local priority

        if [ -n "$YQ_CMD" ]; then
            # Parsing avec yq (mikefarah v4+)
            enabled=$(yq e '.enabled // true' "$profile" 2>/dev/null)
            traefik_enabled=$(yq e '.traefik.enabled // false' "$profile" 2>/dev/null)

            if [ "$enabled" != "true" ] || [ "$traefik_enabled" != "true" ]; then
                continue
            fi

            name=$(yq e '.name' "$profile" 2>/dev/null)
            [ "$name" = "null" ] || [ -z "$name" ] && name=$(basename "$profile" .yml)

            local_port=$(yq e '.traefik.local_port // 80' "$profile" 2>/dev/null)
            docker_port=$(yq e '.traefik.docker_port // 80' "$profile" 2>/dev/null)
            health_path=$(yq e '.traefik.health_path // "/health"' "$profile" 2>/dev/null)
            prefix=$(yq e ".traefik.prefix // \"/$name\"" "$profile" 2>/dev/null)
            strip_prefix=$(yq e '.traefik.strip_prefix // false' "$profile" 2>/dev/null)
            priority=$(yq e '.traefik.priority // 10' "$profile" 2>/dev/null)
        else
            # Fallback: parsing avec grep/sed
            enabled=$(grep -m1 "^enabled:" "$profile" | sed 's/enabled: *//; s/ *#.*//' | tr -d '\r' || echo "true")
            traefik_enabled=$(grep -A 10 "^traefik:" "$profile" | grep "enabled:" | head -1 | sed 's/.*enabled: *//; s/ *#.*//' | tr -d '\r' || echo "false")

            if [ "$enabled" != "true" ] || [ "$traefik_enabled" != "true" ]; then
                continue
            fi

            name=$(grep -m1 "^name:" "$profile" | sed 's/name: *//; s/ *#.*//' | tr -d '\r')
            [ -z "$name" ] && name=$(basename "$profile" .yml)

            local_port=$(grep -A 10 "^traefik:" "$profile" | grep "local_port:" | head -1 | sed 's/.*local_port: *//; s/ *#.*//' | tr -d '\r' || echo "80")
            docker_port=$(grep -A 10 "^traefik:" "$profile" | grep "docker_port:" | head -1 | sed 's/.*docker_port: *//; s/ *#.*//' | tr -d '\r' || echo "80")
            health_path=$(grep -A 10 "^traefik:" "$profile" | grep "health_path:" | head -1 | sed 's/.*health_path: *//; s/ *#.*//' | tr -d '\r' || echo "/health")
            prefix=$(grep -A 10 "^traefik:" "$profile" | grep "prefix:" | head -1 | sed 's/.*prefix: *//; s/ *#.*//' | tr -d '\r')
            [ -z "$prefix" ] && prefix="/$name"
            strip_prefix=$(grep -A 10 "^traefik:" "$profile" | grep "strip_prefix:" | head -1 | sed 's/.*strip_prefix: *//; s/ *#.*//' | tr -d '\r' || echo "false")
            priority=$(grep -A 10 "^traefik:" "$profile" | grep "priority:" | head -1 | sed 's/.*priority: *//; s/ *#.*//' | tr -d '\r' || echo "10")
        fi

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
    declare -A secret_vars
    
    for profile in "$PROFILES_DIR"/*.yml; do
        [ -f "$profile" ] || continue
        
        local enabled
        enabled=$(grep -m1 "^enabled:" "$profile" | sed 's/enabled: *//; s/ *#.*//' | tr -d '\r' || echo "true")
        [ "$enabled" != "true" ] && continue
        
        local profile_name
        profile_name=$(grep -m1 "^name:" "$profile" | sed 's/name: *//; s/ *#.*//' | tr -d '\r' || basename "$profile" .yml)

        # Méthode 1 : Lire la section secrets:
        if grep -q "^secrets:" "$profile"; then
            local in_secrets=false
            while IFS= read -r line; do
                if echo "$line" | grep -q "^secrets:"; then
                    in_secrets=true
                    continue
                fi
                if [ "$in_secrets" = true ]; then
                    if echo "$line" | grep -q "^  - name:"; then
                        local secret_name
                        secret_name=$(echo "$line" | sed 's/.*name: *//; s/ *#.*//' | tr -d '\r')
                        local secret_desc=""
                        local secret_default="changeme"
                        
                        # Lire les lignes suivantes pour description et default
                        while IFS= read -r next_line; do
                            if echo "$next_line" | grep -q "^    description:"; then
                                secret_desc=$(echo "$next_line" | sed -E 's/.*description: *"//; s/"$//; s/[[:space:]]+#.*//' | tr -d '\r')
                            elif echo "$next_line" | grep -q "^    default:"; then
                                secret_default=$(echo "$next_line" | sed 's/.*default: *//; s/ *#.*//' | tr -d '\r')
                                break
                            elif echo "$next_line" | grep -qE "^(  -|[a-z])"; then
                                break
                            fi
                        done
                        
                        if [ -n "$secret_name" ] && [ -z "${secret_vars[$secret_name]}" ]; then
                            secret_vars["$secret_name"]="$secret_default"
                            echo -e "  \033[90m📌 [$profile_name] $secret_name = $secret_default ($secret_desc)\033[0m"
                        fi
                    elif echo "$line" | grep -qE "^[a-z]"; then
                        break
                    fi
                fi
            done < "$profile"
        fi
        
        # Méthode 2 (fallback) : Scanner les ${VAR:-default}
        while IFS= read -r match; do
            local var_name
            var_name=$(echo "$match" | sed 's/.*\${\([A-Z_][A-Z0-9_]*\).*/\1/')
            local default_value
            default_value=$(echo "$match" | sed 's/.*:-\([^}]*\)}.*/\1/')
            [ -z "$default_value" ] && default_value="changeme"
            
            if [ -n "$var_name" ] && [ -z "${secret_vars[$var_name]}" ]; then
                secret_vars["$var_name"]="$default_value"
                echo -e "  \033[90m📌 [$profile_name] $var_name = $default_value (auto-détecté)\033[0m"
            fi
        done < <(grep -o '\${[A-Z_][A-Z0-9_]*:-[^}]*}' "$profile" 2>/dev/null || true)
    done
    
    if [ ${#secret_vars[@]} -eq 0 ]; then
        echo -e "  \033[93mℹ️  Aucune variable de secrets trouvée dans les profils\033[0m"
        return 0
    fi
    
    echo -e "\n  \033[96mTotal: ${#secret_vars[@]} variable(s) trouvée(s)\033[0m"
    
    # Lire le fichier secrets.env existant
    declare -A existing_secrets
    local secrets_content=""
    
    if [ -f "$SECRETS_FILE" ]; then
        secrets_content=$(sops -d "$SECRETS_FILE" 2>&1)
        if [ $? -eq 0 ]; then
            while IFS='=' read -r key value; do
                if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                    existing_secrets["$key"]="$value"
                fi
            done <<< "$secrets_content"
            echo -e "\n  \033[92m✅ Fichier secrets.env déchiffré (${#existing_secrets[@]} variables existantes)\033[0m"
        else
            echo -e "\033[93mImpossible de déchiffrer secrets.env. Création d'un nouveau fichier.\033[0m"
        fi
    fi
    
    # Identifier les nouvelles variables
    declare -A new_vars
    for var in "${!secret_vars[@]}"; do
        if [ -z "${existing_secrets[$var]}" ]; then
            new_vars["$var"]="${secret_vars[$var]}"
        fi
    done
    
    if [ ${#new_vars[@]} -eq 0 ]; then
        echo -e "\n  \033[92m✅ Toutes les variables sont déjà présentes dans secrets.env\033[0m"
        return 0
    fi
    
    echo -e "\n  \033[93m📝 Variables manquantes à ajouter:\033[0m"
    for var in "${!new_vars[@]}"; do
        echo -e "     \033[90m- $var=${new_vars[$var]}\033[0m"
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
    
    # Sauvegarder temporairement en clair
    local temp_file="${SECRETS_FILE}.tmp"
    echo -n "$new_content" > "$temp_file"
    
    # Chiffrer avec SOPS
    # Note: On passe --filename-override secrets.env pour que SOPS applique les règles de .sops.yaml
    if output=$(sops -e --filename-override "$SECRETS_FILE" "$temp_file" 2>&1); then
        echo "$output" > "$SECRETS_FILE"
        rm -f "$temp_file"
        echo -e "\n  \033[92m✅ secrets.env mis à jour et rechiffré (${#new_vars[@]} variable(s) ajoutée(s))\033[0m"
    else
        echo -e "\033[91mErreur lors du chiffrement\033[0m"
        echo "$output"
        rm -f "$temp_file"
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
    
    # Copier l'exemple
    if [ -f "secrets.env.example" ]; then
        cp "secrets.env.example" "$SECRETS_FILE"
    else
        echo "# Secrets file - Edit with: sops secrets.env" > "$SECRETS_FILE"
    fi
    
    echo -e "\n\033[92m✅ Fichier $SECRETS_FILE créé\033[0m"
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
    *)
        show_profiles
        ;;
esac
