#!/bin/bash
# Script principal de gestion des services Dev.Local 2.0
# Gère le cycle de vie des services Docker avec support SOPS pour les secrets

# Note: set -e retiré car il empêche la gestion gracieuse des erreurs de SOPS

COMMAND="start"
PROFILES=""
SERVICE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile)
            PROFILES="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        up|start|stop|down|recreate|ps|logs|sso|id|ecr-login|jfrog-login|edit-secrets|view-secrets)
            COMMAND="$1"
            shift
            ;;
        *)
            # Capture le service si fourni après la commande logs
            if [[ "$COMMAND" == "logs" ]] && [[ -z "$SERVICE" ]]; then
                SERVICE="$1"
            fi
            shift
            ;;
    esac
done

# Valider Docker Compose
validate_docker_compose() {
    if ! command -v docker &> /dev/null; then
        echo -e "\033[91mDocker n'est pas installé\033[0m"
        exit 1
    fi
    
    if ! docker compose version &> /dev/null; then
        echo -e "\033[91mDocker Compose v2+ requis\033[0m"
        exit 1
    fi
}

# Valider SOPS
validate_sops() {
    if ! command -v sops &> /dev/null; then
        echo -e "\033[93mSOPS n'est pas installé - la gestion des secrets ne sera pas disponible\033[0m"
        return 1
    fi
    return 0
}

# Valider la configuration SOPS (.sops.yaml)
validate_sops_config() {
    if [ ! -f ".sops.yaml" ]; then
        echo -e "\033[91mErreur: .sops.yaml non trouvé\033[0m"
        return 1
    fi
    
    # Vérifier si une méthode de chiffrement est active (non commentée)
    # On cherche des lignes qui ne commencent pas par # et qui contiennent une clé de chiffrement valide
    if ! grep -qE "^\s*(- )?(kms|age|pgp|gcp_kms|azure_kv|hc_vault):" .sops.yaml; then
        echo -e "\033[91mErreur: Aucune méthode de chiffrement configurée dans .sops.yaml\033[0m"
        echo -e "\033[93mVeuillez éditer .sops.yaml pour décommenter et configurer 'kms' ou 'age'\033[0m"
        return 1
    fi
    return 0
}

# Charger et déchiffrer les secrets
load_secrets() {
    if [ ! -f "secrets.env" ]; then
        echo -e "\033[93msecrets.env non trouvé - créez-le avec: ./manage-profiles.sh init-secrets\033[0m"
        return
    fi

    if ! validate_sops; then
        return
    fi

    if ! validate_sops_config; then
        echo -e "\033[93mAvertissement: Configuration SOPS invalide. Les secrets ne seront pas chargés.\033[0m"
        return 0
    fi

    echo -e "\033[96m🔐 Déchiffrement des secrets avec SOPS...\033[0m"

    # Déchiffrer et charger - utiliser || true pour éviter que set -e n'arrête le script
    local count=0
    local sops_output
    sops_output=$(sops -d secrets.env 2>&1) || {
        echo -e "\033[91mÉchec du déchiffrement SOPS (code: $?)\033[0m"
        echo -e "\033[93mVérifiez votre configuration AWS/Age\033[0m"
        echo -e "\033[93mLes services démarreront sans secrets\033[0m"
        return 0
    }

    while IFS= read -r line; do
        # Ignorer les commentaires et lignes vides
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Valider le nom de variable (sécurité contre injection)
            if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                export "$key=$value"
                ((count++))
            else
                echo -e "\033[93mAvertissement: Variable ignorée (nom invalide): $key\033[0m" >&2
            fi
        fi
    done <<< "$sops_output"

    if [ $count -eq 0 ]; then
        echo -e "\033[93mAucun secret trouvé dans secrets.env\033[0m"
    else
        echo -e "\033[92m✅ $count secret(s) chargé(s) de manière sécurisée\033[0m"
    fi
}

# Éditer les secrets
edit_secrets() {
    if ! validate_sops; then
        echo -e "\033[91mSOPS requis pour éditer les secrets\033[0m"
        return 1
    fi

    if ! validate_sops_config; then
        return 1
    fi
    
    if [ ! -f "secrets.env" ]; then
        echo -e "\033[93mCréation de secrets.env...\033[0m"
        ./manage-profiles.sh init-secrets
        return
    fi
    
    echo -e "\033[96m📝 Ouverture de l'éditeur SOPS...\033[0m"
    sops secrets.env
    local exit_code=$?

    # SOPS retourne 200 si le fichier n'a pas été modifié, ce qui est normal
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 200 ]; then
        return 0
    else
        echo -e "\033[91mErreur SOPS (code: $exit_code)\033[0m"
        return $exit_code
    fi
}

# Voir les secrets déchiffrés
view_secrets() {
    if ! validate_sops; then
        echo -e "\033[91mSOPS requis\033[0m"
        return 1
    fi

    if ! validate_sops_config; then
        return 1
    fi

    if [ ! -f "secrets.env" ]; then
        echo -e "\033[91msecrets.env non trouvé\033[0m"
        return 1
    fi

    echo -e "\033[96m🔍 Secrets déchiffrés:\033[0m"
    echo -e "\033[93m⚠️  ATTENTION: Les secrets seront affichés en clair\033[0m"
    read -p "Continuer? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\033[90mAnnulé\033[0m"
        return 0
    fi

    # Afficher avec pagination sécurisée
    sops -d secrets.env | less -S
}

# Démarrer les services
start_services() {
    # Vérifier que docker-compose.yml existe
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "\033[93mdocker-compose.yml non trouvé. Génération...\033[0m"
        ./manage-profiles.sh generate
    fi
    
    load_secrets
    
    if [ -n "$PROFILES" ]; then
        export COMPOSE_PROFILES="$PROFILES"
        echo -e "\033[96m🚀 Démarrage des profils: $PROFILES\033[0m"
        
        # Construire la commande avec --profile pour chaque profil
        local profile_args=""
        IFS=',' read -ra PROFILE_ARRAY <<< "$PROFILES"
        for profile in "${PROFILE_ARRAY[@]}"; do
            profile_args="$profile_args --profile $profile"
        done
        
        docker compose $profile_args up -d
    else
        unset COMPOSE_PROFILES
        echo -e "\033[96m🚀 Démarrage de tous les services\033[0m"
        docker compose up -d
    fi
}

# Arrêter les services
stop_services() {
    echo -e "\033[93m⏹️ Arrêt des services\033[0m"
    docker compose --profile "*" down
}

# Recréer les services
recreate_services() {
    echo -e "\033[93m🔄 Recréation des services\033[0m"
    docker compose --profile "*" down
    if [ -n "$PROFILES" ]; then
        export COMPOSE_PROFILES="$PROFILES"
    fi
    start_services
}

# Lister les containers
list_containers() {
    echo -e "\n\033[96m📋 CONTAINERS ACTIFS\033[0m"
    echo -e "\033[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    docker compose ps
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Afficher les logs
show_logs() {
    if [ -n "$SERVICE" ]; then
        echo -e "\033[96m📋 Logs du service: $SERVICE\033[0m"
        docker compose logs -f "$SERVICE"
    else
        echo -e "\033[96m📋 Logs de tous les services\033[0m"
        docker compose logs -f
    fi
}

# AWS SSO
connect_aws_sso() {
    if ! command -v aws &> /dev/null; then
        echo -e "\033[91mAWS CLI non installé\033[0m"
        return 1
    fi
    
    echo -e "\033[96m🔐 Connexion AWS SSO...\033[0m"
    aws sso login --profile ESG-DV-PowerUser-SSO
}

# AWS Identity
show_aws_identity() {
    if ! command -v aws &> /dev/null; then
        echo -e "\033[91mAWS CLI non installé\033[0m"
        return 1
    fi
    
    echo -e "\033[96m🪪 Identité AWS:\033[0m"
    aws sts get-caller-identity
}

# Docker ECR Login
connect_ecr_login() {
    if ! command -v aws &> /dev/null; then
        echo -e "\033[91mAWS CLI non installé\033[0m"
        return 1
    fi

    # Lire l'URL ECR depuis config.yml
    local config_path="$(dirname "$0")/config.yml"
    local ecr_url="<id>.dkr.ecr.ca-central-1.amazonaws.com"  # Valeur par défaut

    if [ -f "$config_path" ] && command -v yq &> /dev/null; then
        local url=$(yq eval '.registries.ecr.url' "$config_path" 2>/dev/null)
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            ecr_url="$url"
        fi
    fi

    echo -e "\033[96m🐳 Connexion Docker à AWS ECR...\033[0m"

    # Méthode sécurisée: utiliser un fichier temporaire avec permissions restreintes
    local temp_pass
    temp_pass=$(mktemp -t ecr-pass.XXXXXX)
    chmod 600 "$temp_pass"

    # Nettoyer le fichier temporaire à la fin
    trap "rm -f '$temp_pass'" EXIT

    if aws ecr get-login-password --region ca-central-1 > "$temp_pass" 2>/dev/null; then
        docker login --username AWS --password-stdin "$ecr_url" < "$temp_pass"
        local result=$?
        # Écraser le contenu avant suppression
        shred -u "$temp_pass" 2>/dev/null || rm -f "$temp_pass"
        trap - EXIT
        return $result
    else
        rm -f "$temp_pass"
        trap - EXIT
        echo -e "\033[91mÉchec de récupération du mot de passe ECR\033[0m"
        return 1
    fi
}

# Docker JFrog Login
connect_jfrog_login() {
    # Lire l'URL JFrog depuis config.yml
    local config_path="$(dirname "$0")/config.yml"
    local jfrog_url="custom.jfrog.io"  # Valeur par défaut
    
    if [ -f "$config_path" ] && command -v yq &> /dev/null; then
        local url=$(yq eval '.registries.jfrog.url' "$config_path" 2>/dev/null)
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            jfrog_url="$url"
        fi
    fi
    
    echo -e "\033[96m🐳 Connexion Docker à JFrog...\033[0m"
    echo -e "\033[93mUtilisez: docker login $jfrog_url\033[0m"
    echo -e "\033[93mEntrez vos identifiants JFrog lorsque demandé\033[0m"
    docker login "$jfrog_url"
}

# Main
validate_docker_compose

case "$COMMAND" in
    start|up)
        start_services
        ;;
    stop|down)
        stop_services
        ;;
    recreate)
        recreate_services
        ;;
    ps)
        list_containers
        ;;
    logs)
        show_logs
        ;;
    sso)
        connect_aws_sso
        ;;
    id)
        show_aws_identity
        ;;
    ecr-login)
        connect_ecr_login
        ;;
    jfrog-login)
        connect_jfrog_login
        ;;
    edit-secrets)
        edit_secrets
        ;;
    view-secrets)
        view_secrets
        ;;
    *)
        echo -e "\033[91mCommande inconnue: $COMMAND\033[0m"
        echo "Usage: $0 [start|stop|recreate|ps|sso|id|ecr-login|edit-secrets|view-secrets]"
        echo "       $0 --profile <profils> start"
        exit 1
        ;;
esac
