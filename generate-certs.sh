#!/usr/bin/env bash

# =============================================================================
# generate-certs.sh - Génération de certificats SSL locaux avec mkcert
# =============================================================================
# Ce script génère des certificats SSL auto-signés mais approuvés localement
# pour permettre du HTTPS sans warnings dans le navigateur.
#
# Utilisation:
#   ./generate-certs.sh [options]
#
# Options:
#   --domain DOMAIN     Domaine personnalisé (défaut: dev.local)
#   --force            Régénérer même si les certificats existent
#   --help             Afficher l'aide
#
# Prérequis:
#   - mkcert installé (le script propose l'installation si absent)
#
# Génère:
#   - traefik/certs/cert.pem (certificat)
#   - traefik/certs/key.pem (clé privée)
# =============================================================================

set -e

# Couleurs pour l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration par défaut
DOMAIN="dev.local"
FORCE=false
CERTS_DIR="traefik/certs"
CERT_FILE="$CERTS_DIR/cert.pem"
KEY_FILE="$CERTS_DIR/key.pem"

# =============================================================================
# Fonctions utilitaires
# =============================================================================

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Dev.Local - Génération de certificats HTTPS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# =============================================================================
# Vérification de mkcert
# =============================================================================

check_mkcert() {
    if command -v mkcert >/dev/null 2>&1; then
        print_success "mkcert est installé: $(mkcert -version 2>&1 | head -1)"
        return 0
    else
        print_error "mkcert n'est pas installé"
        echo ""
        print_info "mkcert est requis pour générer des certificats locaux approuvés"
        echo ""
        echo "Installation selon votre système:"
        echo ""
        echo "  Ubuntu/Debian:"
        echo "    sudo apt install libnss3-tools"
        echo "    curl -JLO https://dl.filippo.io/mkcert/latest?for=linux/amd64"
        echo "    chmod +x mkcert-v*-linux-amd64"
        echo "    sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert"
        echo ""
        echo "  macOS:"
        echo "    brew install mkcert"
        echo "    brew install nss  # pour Firefox"
        echo ""
        echo "  Arch Linux:"
        echo "    sudo pacman -S mkcert"
        echo ""
        echo "Plus d'infos: https://github.com/FiloSottile/mkcert"
        echo ""
        return 1
    fi
}

# =============================================================================
# Installation de la CA locale
# =============================================================================

install_ca() {
    print_info "Installation de l'autorité de certification locale..."

    if mkcert -install; then
        print_success "CA installée avec succès"
        echo ""
        print_info "Les certificats générés seront maintenant approuvés par:"
        echo "  • Chrome/Edge/Opera"
        echo "  • Firefox (si nss est installé)"
        echo "  • curl et autres outils système"
        echo ""
    else
        print_error "Échec de l'installation de la CA"
        echo ""
        print_warning "Vous devrez peut-être exécuter avec sudo:"
        echo "  sudo mkcert -install"
        echo ""
        return 1
    fi
}

# =============================================================================
# Génération des certificats
# =============================================================================

generate_certificates() {
    local domain=$1

    # Créer le répertoire si nécessaire
    if [ ! -d "$CERTS_DIR" ]; then
        print_info "Création du répertoire $CERTS_DIR"
        mkdir -p "$CERTS_DIR"
    fi

    # Vérifier si les certificats existent déjà
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && [ "$FORCE" = false ]; then
        print_warning "Les certificats existent déjà"
        echo ""
        echo "  Certificat: $CERT_FILE"
        echo "  Clé privée: $KEY_FILE"
        echo ""
        print_info "Utilisez --force pour régénérer"
        return 0
    fi

    print_info "Génération des certificats pour:"
    echo "  • localhost"
    echo "  • 127.0.0.1"
    echo "  • ::1"
    echo "  • $domain"
    echo "  • *.$domain"
    echo ""

    # Générer les certificats
    cd "$CERTS_DIR"
    if mkcert -cert-file cert.pem -key-file key.pem \
        localhost 127.0.0.1 ::1 \
        "$domain" "*.$domain"; then

        cd - > /dev/null
        print_success "Certificats générés avec succès!"
        echo ""
        echo "  Certificat: $CERT_FILE"
        echo "  Clé privée: $KEY_FILE"
        echo ""

        # Afficher les informations du certificat
        print_info "Informations du certificat:"
        openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null || true
        echo ""

        return 0
    else
        cd - > /dev/null
        print_error "Échec de la génération des certificats"
        return 1
    fi
}

# =============================================================================
# Configuration /etc/hosts
# =============================================================================

check_hosts_file() {
    local domain=$1

    print_info "Vérification du fichier /etc/hosts..."

    if grep -q "127.0.0.1.*$domain" /etc/hosts 2>/dev/null; then
        print_success "Le domaine $domain est configuré dans /etc/hosts"
    else
        print_warning "Le domaine $domain n'est pas dans /etc/hosts"
        echo ""
        print_info "Pour utiliser https://$domain, ajoutez cette ligne à /etc/hosts:"
        echo ""
        echo "  127.0.0.1    $domain"
        echo ""
        print_info "Commande pour l'ajouter automatiquement:"
        echo ""
        echo "  echo '127.0.0.1    $domain' | sudo tee -a /etc/hosts"
        echo ""
    fi
}

# =============================================================================
# Instructions post-installation
# =============================================================================

print_usage_instructions() {
    local domain=$1

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Configuration terminée!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    print_info "Prochaines étapes:"
    echo ""
    echo "  1. Assurez-vous que Traefik est configuré pour HTTPS"
    echo "     (vérifiez traefik/traefik.yml)"
    echo ""
    echo "  2. Régénérez la configuration Docker Compose:"
    echo "     ./manage-profiles.sh generate"
    echo ""
    echo "  3. Redémarrez les services:"
    echo "     ./launch.sh restart"
    echo ""
    echo "  4. Accédez à vos services via HTTPS:"
    echo "     • https://localhost"
    echo "     • https://$domain"
    echo "     • https://<service>.$domain (selon vos profils)"
    echo ""
    print_success "Aucun warning de sécurité n'apparaîtra dans votre navigateur!"
    echo ""
}

# =============================================================================
# Aide
# =============================================================================

show_help() {
    cat << EOF
Utilisation: ./generate-certs.sh [options]

Génère des certificats SSL locaux approuvés pour le développement HTTPS.

Options:
  --domain DOMAIN     Domaine de base (défaut: dev.local)
  --force            Régénérer même si les certificats existent
  --help             Afficher cette aide

Exemples:
  ./generate-certs.sh
  ./generate-certs.sh --domain myapp.local
  ./generate-certs.sh --force

Le script génère des certificats pour:
  • localhost, 127.0.0.1, ::1
  • <domain> (ex: dev.local)
  • *.<domain> (ex: *.dev.local)

Les certificats sont placés dans: $CERTS_DIR/

Pour plus d'informations, consultez: docs/https-guide.md
EOF
}

# =============================================================================
# Parsing des arguments
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Option inconnue: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    print_header

    # Vérifier mkcert
    if ! check_mkcert; then
        exit 1
    fi

    echo ""

    # Vérifier si la CA est installée
    if ! mkcert -CAROOT >/dev/null 2>&1; then
        print_warning "L'autorité de certification n'est pas installée"
        echo ""
        if ! install_ca; then
            exit 1
        fi
    else
        print_success "CA déjà installée: $(mkcert -CAROOT)"
        echo ""
    fi

    # Générer les certificats
    if ! generate_certificates "$DOMAIN"; then
        exit 1
    fi

    # Vérifier /etc/hosts
    check_hosts_file "$DOMAIN"

    echo ""

    # Instructions finales
    print_usage_instructions "$DOMAIN"
}

main "$@"