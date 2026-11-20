#!/usr/bin/env bash
# Script de validation des profils Dev.Local 2.0
# Valide la syntaxe YAML, les champs requis et les valeurs des profils

# Note: Pas de 'set -e' car on veut valider tous les profils même si certains échouent

PROFILES_DIR="profiles"
ERRORS=0
WARNINGS=0
VALIDATED=0
JSON_OUTPUT=false
# Erreurs et avertissements en JSON, pour la sortie --json
JSON_ERRORS=()
JSON_WARNINGS=()

# Couleurs pour l'affichage
RED='\033[91m'
YELLOW='\033[93m'
GREEN='\033[92m'
CYAN='\033[96m'
RESET='\033[0m'

show_usage() {
    cat << EOF
VALIDATION DES PROFILS DEV.LOCAL 2.0

Usage:
    ./validate-profiles.sh           Valider tous les profils
    ./validate-profiles.sh --json    Résultat en JSON sur stdout, sans autre texte :
                                     {"valid", "validated", "errors", "warnings"}
                                     errors et warnings : liste de {"profile", "message"}
    ./validate-profiles.sh --help    Afficher cette aide

Valide la syntaxe YAML, les champs requis et les valeurs des profils du répertoire profiles/.

Codes de sortie:
    0 - Tous les profils sont valides (avec ou sans avertissements)
    1 - Erreurs détectées
EOF
}

# Arguments : traités avant de chercher yq, pour que l'aide ne dépende pas de lui
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --json)
                JSON_OUTPUT=true
                ;;
            *)
                echo -e "${RED}Argument inconnu: $arg${RESET}" >&2
                show_usage >&2
                exit 1
                ;;
        esac
    done
fi

# yq local ou via Docker (voir lib/yq.sh)
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source "lib/yq.sh"
source "lib/json.sh"

# Champs lus dans chaque profil, en un seul appel yq par fichier
PROFILE_FIELDS=(
    .name .enabled .always_active .docker_profile .expose_ports
    .docker-compose.image .docker-compose.container_name
    .traefik.enabled .traefik.prefix .traefik.docker_port
    .traefik.local_port .traefik.priority
)
declare -A PROFILE_VALUES
PORT_FORMATS_HELP="Formats acceptés: \"8080:80\", \"127.0.0.1:8080:80\", \"80\", ou la syntaxe longue (target, published). Retirez la section ports si le service ne publie aucun port."

# Champs calculés par yq dans le même appel, une ligne chacun, toujours préfixée pour ne
# jamais être vide. Stockés dans PROFILE_VALUES sous la clé indiquée.
#   @dup         true si une clé est écrite deux fois dans une même section
#   @ports_kind  type YAML de docker-compose.ports (!!seq pour une liste, vide si absent)
#   @bad_ports   éléments de docker-compose.ports qui ne sont pas un port valide
#   @host_ports  ports sous la forme [ip:][hôte:]conteneur ; syntaxe longue -> published:target
# Chaque résultat doit dépendre de l'élément lu : yq émet une constante seule ("texte") même
# quand select() ne retient rien.
# Syntaxe courte acceptée (une variable ${...} compte pour un nombre) :
#   [IP:][PORT_HOTE[-FIN]:]PORT_CONTENEUR[-FIN][/tcp|udp|sctp]
COMPUTED_KEYS=(@dup @ports_kind @bad_ports @host_ports)
read -r -d '' VALID_SHORT_PORT <<'EOF' || true
(tostring | sub("[$][{][^}]*[}]"; "1") | test("^((([0-9]{1,3}[.]){3}[0-9]{1,3}|\[[0-9a-fA-F:]+\]):([0-9]+(-[0-9]+)?)?:|[0-9]+(-[0-9]+)?:)?[0-9]+(-[0-9]+)?(/(tcp|udp|sctp))?$"))
EOF
read -r -d '' COMPUTED_EXPR <<EOF || true
("dup=" + ([.. | select(tag == "!!map") | (keys | length) != (keys | unique | length)] | any | tostring)),
("portskind=" + (.["docker-compose"].ports | tag)),
("badports=" + ([.["docker-compose"].ports | select(tag == "!!seq") | .[] | (
    (select(tag == "!!map" and (has("target") | not)) | "syntaxe longue sans target (" + (keys | sort | join(", ")) + ")"),
    (select(tag == "!!seq" or tag == "!!null") | "élément vide ou imbriqué" + (tag | sub(".*"; ""))),
    (select(tag != "!!map" and tag != "!!seq" and tag != "!!null") | select($VALID_SHORT_PORT | not) | "'" + tostring + "'")
)] | join(", "))),
("hostports=" + ([.["docker-compose"].ports | select(tag == "!!seq") | .[] | (
    (select(tag == "!!map" and has("published") and has("target")) | (.published | tostring) + ":" + (.target | tostring)),
    (select(tag == "!!str" or tag == "!!int") | tostring)
)] | join(" ")))
EOF

# Fonction pour afficher un message d'erreur
error() {
    local profile="$1"
    local message="$2"
    echo -e "${RED}❌ ERREUR${RESET} [$profile]: $message"
    JSON_ERRORS+=("{\"profile\":$(json_string "$profile"),\"message\":$(json_string "$message")}")
    ((ERRORS++))
}

# Fonction pour afficher un avertissement
warning() {
    local profile="$1"
    local message="$2"
    echo -e "${YELLOW}⚠️  AVERTISSEMENT${RESET} [$profile]: $message"
    JSON_WARNINGS+=("{\"profile\":$(json_string "$profile"),\"message\":$(json_string "$message")}")
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
    output=$(yq e "$expr,$COMPUTED_EXPR" "$file" 2>/dev/null) || return 1

    local values
    mapfile -t values <<< "$output"
    # Une ligne par champ : un écart signale une valeur multi-ligne ou plusieurs documents
    [ "${#values[@]}" -eq $((${#PROFILE_FIELDS[@]} + ${#COMPUTED_KEYS[@]})) ] || return 1

    local i
    for i in "${!PROFILE_FIELDS[@]}"; do
        PROFILE_VALUES["$file|${PROFILE_FIELDS[$i]}"]="${values[$i]}"
    done
    for i in "${!COMPUTED_KEYS[@]}"; do
        local computed="${values[$((${#PROFILE_FIELDS[@]} + i))]}"
        PROFILE_VALUES["$file|${COMPUTED_KEYS[$i]}"]="${computed#*=}"
    done
}

# Affiche le port hôte d'un port "[ip:][hôte:]conteneur[/proto]" s'il est numérique
host_port_of() {
    local spec="${1%%/*}"
    [[ "$spec" == \[* ]] && return 0
    local parts
    IFS=':' read -ra parts <<< "$spec"
    local host_port=""
    case "${#parts[@]}" in
        2) host_port="${parts[0]}" ;;
        3) host_port="${parts[1]}" ;;
    esac
    [[ "$host_port" =~ ^[0-9]+$ ]] && echo "$host_port"
    return 0
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

# Vrai si la valeur est un numéro de port (1 à 65535).
# Le nombre de chiffres est borné avant la comparaison : au-delà de 64 bits,
# [ -gt ] échoue et laisserait passer la valeur.
is_valid_port() {
    [[ "$1" =~ ^0*([0-9]{1,5})$ ]] || return 1
    local port=$((10#${BASH_REMATCH[1]}))
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Validation 1: Syntaxe YAML
validate_yaml_syntax() {
    local profile="$1"

    if ! load_profile "$profile"; then
        error "$(basename "$profile")" "Syntaxe YAML invalide (ou valeur multi-ligne / documents multiples non supportés)"
        return 1
    fi
    if [ "${PROFILE_VALUES["$profile|@dup"]}" = "true" ]; then
        error "$(basename "$profile")" "Clé YAML en double (une clé ne peut apparaître qu'une fois dans une même section)"
        # Profil traité comme non chargé par les validations inter-profils
        unset "PROFILE_VALUES[$profile|.name]"
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

    # Validation des ports : docker-compose.ports est une liste de ports valides
    local ports_kind="${PROFILE_VALUES["$profile|@ports_kind"]}"
    if [ "$ports_kind" = "!!seq" ]; then
        local bad_ports="${PROFILE_VALUES["$profile|@bad_ports"]}"
        if [ -n "$bad_ports" ]; then
            error "$basename" "Port invalide dans docker-compose.ports: $bad_ports. $PORT_FORMATS_HELP"
            has_errors=1
        fi
    elif [ -n "$ports_kind" ] && [ "$ports_kind" != "!!null" ]; then
        error "$basename" "Champ 'docker-compose.ports' doit être une liste. $PORT_FORMATS_HELP"
        has_errors=1
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
            if ! is_valid_port "$docker_port"; then
                error "$basename" "traefik.docker_port doit être entre 1 et 65535 (trouvé: '$docker_port')"
                has_errors=1
            fi

            local local_port
            local_port=$(get_value "$profile" ".traefik.local_port" "80")
            if ! is_valid_port "$local_port"; then
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
        if [ "$(get_value "$profile" ".expose_ports" "false")" = "true" ]; then
            local port_spec host_port
            for port_spec in ${PROFILE_VALUES["$profile|@host_ports"]}; do
                host_port=$(host_port_of "$port_spec")
                [ -n "$host_port" ] || continue
                if [ -n "${host_ports[$host_port]}" ]; then
                    warning "$basename" "Port hôte $host_port déjà utilisé par ${host_ports[$host_port]}"
                else
                    host_ports["$host_port"]="$basename"
                fi
            done
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

# Écrit le résultat de la validation en JSON sur le descripteur 3 (stdout d'origine)
print_json_result() {
    local valid=true
    [ "$ERRORS" -gt 0 ] && valid=false
    local IFS=,
    echo "{\"valid\":$valid,\"validated\":$VALIDATED,\"errors\":[${JSON_ERRORS[*]}],\"warnings\":[${JSON_WARNINGS[*]}]}" >&3
}

# Main
main() {
    # --json : le texte destiné à l'utilisateur est supprimé, seul le JSON final est écrit
    if [ "$JSON_OUTPUT" = true ]; then
        exec 3>&1 > /dev/null
    fi

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
        [ "$JSON_OUTPUT" = true ] && print_json_result
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
    [ "$JSON_OUTPUT" = true ] && print_json_result

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