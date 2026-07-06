#!/bin/bash
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
GRAY='\033[90m'
RESET='\033[0m'

# Détection de yq (même logique que manage-profiles.sh)
YQ_CMD=""
detect_yq_version() {
    if ! command -v yq >/dev/null 2>&1; then
        return 1
    fi

    if yq --help 2>&1 | grep -q "eval"; then
        local version
        version=$(yq --version 2>&1 | grep -oP 'version [v]?\K[0-9]+' | head -1)
        if [ -n "$version" ] && [ "$version" -ge 4 ]; then
            return 0
        fi
    fi
    return 1
}

if detect_yq_version; then
    YQ_CMD="yq"
fi

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

# Fonction pour extraire une valeur YAML
get_value() {
    local file="$1"
    local path="$2"
    local default="${3:-}"

    if [ -n "$YQ_CMD" ]; then
        # Ne pas utiliser // car il traite false comme falsy
        local value
        value=$(yq e "$path" "$file" 2>/dev/null)

        # Si la valeur est null ou vide, utiliser le défaut
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            echo "$default"
        else
            echo "$value"
        fi
    else
        # Fallback grep/sed (basique)
        local key
        key=$(echo "$path" | sed 's/^\.//' | tr '.' ' ' | awk '{print $NF}')
        grep -m1 "^[[:space:]]*${key}:" "$file" 2>/dev/null | sed "s/.*${key}: *//; s/ *#.*//" | tr -d '\r' || echo "$default"
    fi
}

# Validation 1: Syntaxe YAML
validate_yaml_syntax() {
    local profile="$1"

    if [ -n "$YQ_CMD" ]; then
        if ! yq e '.' "$profile" >/dev/null 2>&1; then
            error "$(basename "$profile")" "Syntaxe YAML invalide"
            return 1
        fi
    else
        # Validation basique sans yq
        if ! grep -q "^[a-z]" "$profile" 2>/dev/null; then
            error "$(basename "$profile")" "Fichier vide ou invalide"
            return 1
        fi
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
        if grep -q "^[[:space:]]*ports:" "$profile"; then
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

    if [ -n "$YQ_CMD" ]; then
        echo -e "${GREEN}✓${RESET} yq détecté - validation complète activée"
    else
        echo -e "${YELLOW}⚠${RESET} yq non disponible - validation basique seulement"
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