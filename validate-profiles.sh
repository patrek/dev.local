#!/usr/bin/env bash
# Script de validation des profils Dev.Local 2.0
# Valide la syntaxe YAML, les champs requis et les valeurs des profils

# Note: Pas de 'set -e' car on veut valider tous les profils même si certains échouent

PROFILES_DIR="profiles"
ERRORS=0
WARNINGS=0
VALIDATED=0

# Couleurs pour l'affichage
RED='\033[91m'
YELLOW='\033[93m'
GREEN='\033[92m'
CYAN='\033[96m'
RESET='\033[0m'

# yq local ou via Docker (voir lib/yq.sh)
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source "lib/yq.sh"

# Champs lus dans chaque profil, en un seul appel yq par fichier
PROFILE_FIELDS=(
    .name .enabled .always_active .docker_profile .expose_ports
    .docker-compose.image .docker-compose.container_name
    .traefik.enabled .traefik.prefix .traefik.docker_port
    .traefik.local_port .traefik.priority
)
declare -A PROFILE_VALUES

# Fonction pour afficher un message d'erreur
error() {
    local profile="$1"
    local message="$2"
    echo -e "${RED}❌ ERREUR${RESET} [$profile]: $message"
    ((ERRORS++))
}

# Fonction pour afficher un avertissement
warning() {
    local profile="$1"
    local message="$2"
    echo -e "${YELLOW}⚠️  AVERTISSEMENT${RESET} [$profile]: $message"
    ((WARNINGS++))
}

# Fonction pour afficher un succès
success() {
    local profile="$1"
    echo -e "${GREEN}✅${RESET} $profile"
}

# Charge les champs d'un profil dans PROFILE_VALUES.
# Échoue si le fichier n'est pas du YAML valide ou n'est pas exploitable.
load_profile() {
    local file="$1"
    local expr
    expr=$(IFS=,; echo "${PROFILE_FIELDS[*]}")

    local output
    output=$(yq e "$expr" "$file" 2>/dev/null) || return 1

    local values
    mapfile -t values <<< "$output"
    # Une ligne par champ : un écart signale une valeur multi-ligne ou plusieurs documents
    [ "${#values[@]}" -eq "${#PROFILE_FIELDS[@]}" ] || return 1

    local i
    for i in "${!PROFILE_FIELDS[@]}"; do
        PROFILE_VALUES["$file|${PROFILE_FIELDS[$i]}"]="${values[$i]}"
    done
}

# Retourne un champ chargé par load_profile, ou la valeur par défaut s'il est absent
get_value() {
    local file="$1"
    local path="$2"
    local default="${3:-}"
    local value="${PROFILE_VALUES["$file|$path"]}"

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Validation 1: Syntaxe YAML
validate_yaml_syntax() {
    local profile="$1"

    if ! load_profile "$profile"; then
        error "$(basename "$profile")" "Syntaxe YAML invalide (ou valeur multi-ligne / documents multiples non supportés)"
        return 1
    fi
    return 0
}

# Validation 2: Champs requis
validate_required_fields() {
    local profile="$1"
    local basename
    basename=$(basename "$profile" .yml)
    local has_errors=0

    # Champs obligatoires au niveau racine
    local name
    name=$(get_value "$profile" ".name")
    if [ -z "$name" ] || [ "$name" = "null" ]; then
        error "$basename" "Champ 'name' manquant ou vide"
        has_errors=1
    fi

    local enabled
    enabled=$(get_value "$profile" ".enabled")
    if [ "$enabled" != "true" ] && [ "$enabled" != "false" ]; then
        error "$basename" "Champ 'enabled' doit être true ou false (trouvé: '$enabled')"
        has_errors=1
    fi

    # Validation docker-compose
    if ! grep -q "^docker-compose:" "$profile"; then
        error "$basename" "Section 'docker-compose' manquante"
        has_errors=1
        return 1
    fi

    local image
    image=$(get_value "$profile" ".docker-compose.image")
    if [ -z "$image" ] || [ "$image" = "null" ]; then
        error "$basename" "Champ 'docker-compose.image' manquant ou vide"
        has_errors=1
    fi

    local container_name
    container_name=$(get_value "$profile" ".docker-compose.container_name")
    if [ -z "$container_name" ] || [ "$container_name" = "null" ]; then
        warning "$basename" "Champ 'docker-compose.container_name' recommandé"
    fi

    return $has_errors
}

# Validation 3: Valeurs et types
validate_values() {
    local profile="$1"
    local basename
    basename=$(basename "$profile" .yml)
    local has_errors=0

    # Validation always_active vs docker_profile
    local always_active
    always_active=$(get_value "$profile" ".always_active" "false")
    local docker_profile
    docker_profile=$(get_value "$profile" ".docker_profile")

    if [ "$always_active" = "true" ] && [ "$docker_profile" != "null" ] && [ -n "$docker_profile" ]; then
        warning "$basename" "always_active=true mais docker_profile='$docker_profile' (devrait être null)"
    fi

    if [ "$always_active" = "false" ] && ([ "$docker_profile" = "null" ] || [ -z "$docker_profile" ]); then
        error "$basename" "always_active=false nécessite un docker_profile valide"
        has_errors=1
    fi

    local expose_ports
    expose_ports=$(get_value "$profile" ".expose_ports" "false")
    if [ "$expose_ports" != "true" ] && [ "$expose_ports" != "false" ]; then
        error "$basename" "Champ 'expose_ports' doit être true ou false (trouvé: '$expose_ports')"
        has_errors=1
    fi

    # Validation des ports
    if grep -q "^[[:space:]]*ports:" "$profile"; then
        local port_line
        port_line=$(grep -A1 "^[[:space:]]*ports:" "$profile" | tail -1)
        if echo "$port_line" | grep -q '"non"'; then
            error "$basename" "Valeur de port invalide: 'non' (devrait être 'none' ou un port valide)"
            has_errors=1
        fi
    fi

    # Validation Traefik si activé
    if grep -q "^traefik:" "$profile"; then
        local traefik_enabled
        traefik_enabled=$(get_value "$profile" ".traefik.enabled" "false")

        if [ "$traefik_enabled" = "true" ]; then
            local prefix
            prefix=$(get_value "$profile" ".traefik.prefix")
            if [ -z "$prefix" ] || [ "$prefix" = "null" ]; then
                error "$basename" "traefik.prefix requis quand traefik est activé"
                has_errors=1
            elif [[ ! "$prefix" =~ ^/ ]]; then
                error "$basename" "traefik.prefix doit commencer par '/' (trouvé: '$prefix')"
                has_errors=1
            fi

            local docker_port
            docker_port=$(get_value "$profile" ".traefik.docker_port" "80")
            if ! [[ "$docker_port" =~ ^[0-9]+$ ]] || [ "$docker_port" -lt 1 ] || [ "$docker_port" -gt 65535 ]; then
                error "$basename" "traefik.docker_port doit être entre 1 et 65535 (trouvé: '$docker_port')"
                has_errors=1
            fi

            local local_port
            local_port=$(get_value "$profile" ".traefik.local_port" "80")
            if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
                error "$basename" "traefik.local_port doit être entre 1 et 65535 (trouvé: '$local_port')"
                has_errors=1
            fi

            local priority
            priority=$(get_value "$profile" ".traefik.priority" "10")
            if ! [[ "$priority" =~ ^[0-9]+$ ]]; then
                warning "$basename" "traefik.priority doit être un entier (trouvé: '$priority')"
            fi
        fi
    fi

    return $has_errors
}

# Validation 4: Validations inter-profils
validate_cross_profile() {
    declare -A container_names
    declare -A host_ports
    local has_errors=0

    for profile in $PROFILES_DIR/*.yml; do
        [ -f "$profile" ] || continue

        # Ignorer les profils non chargés : déjà signalés par la validation individuelle
        [ -n "${PROFILE_VALUES["$profile|.name"]+x}" ] || continue

        local enabled
        enabled=$(get_value "$profile" ".enabled" "true")
        [ "$enabled" != "true" ] && continue

        local basename
        basename=$(basename "$profile" .yml)

        # Vérifier l'unicité des noms de containers
        local container_name
        container_name=$(get_value "$profile" ".docker-compose.container_name")
        if [ -n "$container_name" ] && [ "$container_name" != "null" ]; then
            if [ -n "${container_names[$container_name]}" ]; then
                error "$basename" "Nom de container '$container_name' déjà utilisé par ${container_names[$container_name]}"
                has_errors=1
            else
                container_names["$container_name"]="$basename"
            fi
        fi

        # Vérifier les conflits de ports (uniquement si format standard port:port)
        # Sans expose_ports, les ports du profil ne sont pas publiés : aucun conflit possible
        if [ "$(get_value "$profile" ".expose_ports" "false")" = "true" ] && grep -q "^[[:space:]]*ports:" "$profile"; then
            while IFS= read -r port_line; do
                if [[ "$port_line" =~ ^[[:space:]]*-[[:space:]]*\"?([0-9]+): ]]; then
                    local host_port="${BASH_REMATCH[1]}"
                    if [ -n "${host_ports[$host_port]}" ]; then
                        warning "$basename" "Port hôte $host_port déjà utilisé par ${host_ports[$host_port]}"
                    else
                        host_ports["$host_port"]="$basename"
                    fi
                fi
            done < <(sed -n '/^[[:space:]]*ports:/,/^[[:space:]]*[a-z]/p' "$profile" | grep "^[[:space:]]*-")
        fi
    done

    return $has_errors
}

# Fonction principale de validation
validate_profile() {
    local profile="$1"
    local basename
    basename=$(basename "$profile" .yml)

    validate_yaml_syntax "$profile" || return 1
    validate_required_fields "$profile" || return 1
    validate_values "$profile" || return 1

    return 0
}

# Main
main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║     VALIDATION DES PROFILS DEV.LOCAL 2.0            ║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [ "$YQ_MODE" = "docker" ]; then
        echo -e "${GREEN}✓${RESET} yq via Docker ($YQ_IMAGE)"
    else
        echo -e "${GREEN}✓${RESET} yq local"
    fi
    echo ""

    if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/*.yml 2>/dev/null)" ]; then
        echo -e "${YELLOW}Aucun profil trouvé dans $PROFILES_DIR${RESET}"
        exit 0
    fi

    echo -e "${CYAN}📋 Validation individuelle des profils:${RESET}"
    echo ""

    for profile in $PROFILES_DIR/*.yml; do
        [ -f "$profile" ] || continue

        local basename
        basename=$(basename "$profile" .yml)

        if validate_profile "$profile"; then
            success "$basename"
            ((VALIDATED++))
        fi
    done

    echo ""
    echo -e "${CYAN}🔍 Validations inter-profils:${RESET}"
    echo ""

    validate_cross_profile

    # Résumé
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║                    RÉSUMÉ                            ║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Profils validés    : ${GREEN}$VALIDATED${RESET}"
    echo -e "  Erreurs            : ${RED}$ERRORS${RESET}"
    echo -e "  Avertissements     : ${YELLOW}$WARNINGS${RESET}"
    echo ""

    if [ $ERRORS -gt 0 ]; then
        echo -e "${RED}❌ La validation a échoué avec $ERRORS erreur(s)${RESET}"
        exit 1
    elif [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠️  La validation a réussi mais avec $WARNINGS avertissement(s)${RESET}"
        exit 0
    else
        echo -e "${GREEN}✅ Tous les profils sont valides !${RESET}"
        exit 0
    fi
}

# Exécuter si appelé directement
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi