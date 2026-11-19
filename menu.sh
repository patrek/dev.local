#!/usr/bin/env bash
# Menu interactif pour Dev.Local 2.0
# Interface simple pour gérer services et profils

# Pas de "set -e" : une commande en échec ne doit pas fermer le menu (voir run_step).
# Les étapes dont l'échec doit arrêter le script le vérifient donc elles-mêmes.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# yq local ou via Docker (voir lib/yq.sh)
source "lib/yq.sh" || exit 1

# Lit les champs d'un profil utilisés par le menu, en un seul appel yq (voir lib/yq.sh).
# Résultat dans YAML_FIELDS : name, enabled, always_active, docker_profile.
# Un profil illisible est signalé et ignoré par l'appelant (retour 1), comme dans menu.ps1.
read_profile_fields() {
    read_yaml_fields "$1" .name .enabled .always_active .docker_profile
    if [ "${#YAML_FIELDS[@]}" -eq 0 ]; then
        echo -e "\033[93m⚠️  Erreur lecture $(basename "$1") (YAML invalide)\033[0m" >&2
        return 1
    fi
}

# Exécute une commande du menu. Un échec est signalé avec son code de sortie,
# sans fermer le menu.
run_step() {
    "$@"
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo -e "\n\033[91m⚠️  La commande a échoué (code de sortie : $status)\033[0m"
    fi
    return 0
}

wait_key() {
    echo -e "\n\033[90m[Appuyez sur n'importe quelle touche pour continuer...]\033[0m"
    read -n 1 -s
}

show_menu() {
    clear
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║              🚀 DEV.LOCAL 2.0 - MENU PRINCIPAL                ║
║          Gestionnaire de Services Docker Modulaire            ║
╚═══════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────┐
│ 📦 SERVICES DOCKER                                          │
└─────────────────────────────────────────────────────────────┘
  1. ▶️ Démarrer tous les services
  m. 🚀 Démarrer services minimums (sans profils)
  2. 🎯 Démarrer avec profils spécifiques
  3. 🔄 Recréer les services (down + up)
  4. ⏹️ Arrêter tous les services
  5. 📋 Lister les containers actifs

┌─────────────────────────────────────────────────────────────┐
│ 🎭 GESTION DES PROFILS                                      │
└─────────────────────────────────────────────────────────────┘
  6. ➕ Ajouter un nouveau profil
  7. 📝 Lister les profils existants
  8. 🔧 Regénérer docker-compose.yml
  9. ✅ Valider les profils

┌─────────────────────────────────────────────────────────────┐
│ 🔐 GESTION DES SECRETS (SOPS)                               │
└─────────────────────────────────────────────────────────────┘
  10. ✏️ Éditer les secrets (sops secrets.env)
  11. 👁️ Voir les secrets déchiffrés
  12. 🆕 Initialiser secrets.env
  13. 🔄 Synchroniser secrets.env avec les profils

┌─────────────────────────────────────────────────────────────┐
│ ☁️  AWS & DOCKER                                            │
└─────────────────────────────────────────────────────────────┘
  14. 🔐 Connexion AWS SSO
  15. 🪪 Voir l'identité AWS
  16. 🐳 Connexion Docker ECR

┌─────────────────────────────────────────────────────────────┐
│ 📚 DOCUMENTATION                                            │
└─────────────────────────────────────────────────────────────┘
  17. 📖 Ouvrir README.md
  
  0. ❌ Quitter (ou 'q')

EOF
}

show_profiles() {
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║            📋 PROFILS DISPONIBLES                             ║
╚═══════════════════════════════════════════════════════════════╝

EOF
    
    if [ ! -d "profiles" ] || [ -z "$(ls -A profiles/*.yml 2>/dev/null)" ]; then
        echo -e "\033[93m  Aucun profil disponible\033[0m"
        echo "  Utilisez l'option 6 pour créer un profil"
        return
    fi
    
    # Init arrays
    docker_profiles=()
    i=1
    
    for profile in profiles/*.yml; do
        [ -f "$profile" ] || continue
        
        read_profile_fields "$profile" || continue

        name="${YAML_FIELDS[0]}"
        if [ "$name" = "null" ] || [ -z "$name" ]; then
            name=$(basename "$profile" .yml)
        fi

        enabled="${YAML_FIELDS[1]}"

        docker_profile="${YAML_FIELDS[3]}"
        if [ "$docker_profile" = "null" ] || [ -z "$docker_profile" ]; then 
            docker_profile="$name"
        fi
        
        if [ "$enabled" != "false" ]; then
            echo -e "  \033[96m[$i]\033[0m \033[92m✅ $name\033[0m"
            docker_profiles[i]="$docker_profile"
            ((i++))
        else
            echo -e "  \033[90m[-] ❌ $name (Désactivé)\033[0m"
        fi
    done
    
    echo -e "\nExemples:"
    echo "  1,2         (par numéros)"
    echo "  api,web     (par noms)"
    echo ""
    
    read -p "Entrez les profils (noms ou numéros, séparés par virgules): " input
    selected_profiles=""
    if [ -n "$input" ]; then
        IFS=',' read -ra ADDR <<< "$input"
        for val in "${ADDR[@]}"; do
            val=$(echo "$val" | tr -d '[:space:]')
            [ -n "$val" ] || continue
            # Check if number
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                if [ -n "${docker_profiles[$val]}" ]; then
                    if [ -z "$selected_profiles" ]; then
                        selected_profiles="${docker_profiles[$val]}"
                    else
                        selected_profiles="$selected_profiles,${docker_profiles[$val]}"
                    fi
                fi
            else
                if [ -z "$selected_profiles" ]; then
                    selected_profiles="$val"
                else
                    selected_profiles="$selected_profiles,$val"
                fi
            fi
        done
    fi

    # Sans profil valide, rien n'est lancé
    if [ -z "$selected_profiles" ]; then
        echo -e "\033[93mAucun profil valide sélectionné - rien n'a été démarré\033[0m"
        return
    fi

    LAST_PROFILES="$selected_profiles"
    echo -e "\033[96m▶️  Démarrage avec profils: $selected_profiles\033[0m"
    echo -e "\033[90mCommande: docker compose --profile $(echo $selected_profiles | sed 's/,/ --profile /g') up -d\033[0m"
    run_step ./launch.sh --profile "$selected_profiles" up
}

# Variable globale pour stocker les derniers profils utilisés
LAST_PROFILES=""

# Boucle principale
while true; do
    show_menu
    # Fin de l'entrée (pas de terminal, Ctrl+D) : quitter au lieu de boucler
    if ! read -p "Choisissez une option (0-17) ou 'q' pour quitter: " choice; then
        echo ""
        exit 0
    fi
    
    case $choice in
        1)
            echo -e "\033[96m▶️  Démarrage de tous les services...\033[0m"
            
            # Recueillir tous les profils actifs nécessaires
            profiles_list=""
            for profile in profiles/*.yml; do
                [ -f "$profile" ] || continue
                
                read_profile_fields "$profile" || continue

                # Vérifier si activé (défaut: true)
                is_enabled="${YAML_FIELDS[1]}"
                if [ "$is_enabled" = "false" ]; then continue; fi

                # Vérifier si toujours actif (défaut: false, comme manage-profiles.sh)
                always_active="${YAML_FIELDS[2]}"

                if [ "$always_active" != "true" ]; then
                    p_name="${YAML_FIELDS[3]}"

                    if [ -n "$p_name" ] && [ "$p_name" != "null" ]; then
                        if [ -z "$profiles_list" ]; then
                            profiles_list="$p_name"
                        else
                            profiles_list="$profiles_list,$p_name"
                        fi
                    fi
                fi
            done
            
            # Dédupliquer les profils
            if [ -n "$profiles_list" ]; then
                unique_profiles=$(echo "$profiles_list" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
                echo -e "\033[90mProfils inclus: $unique_profiles\033[0m"
                echo -e "\033[90mCommande: docker compose --profile $(echo $unique_profiles | sed 's/,/ --profile /g') up -d\033[0m"
                LAST_PROFILES="$unique_profiles"
                run_step ./launch.sh --profile "$unique_profiles" up
            else
                echo -e "\033[90mCommande: docker compose up -d\033[0m"
                LAST_PROFILES=""
                run_step ./launch.sh up
            fi
            
            wait_key
            ;;
        m|M)
            echo -e "\033[96m▶️  Démarrage des services minimums (sans profils)...\033[0m"
            echo -e "\033[90mCommande: docker compose up -d\033[0m"
            run_step ./launch.sh up
            wait_key
            ;;
        2)
            show_profiles
            wait_key
            ;;
        3)
            echo -e "\033[93m🔄 Recréation des services...\033[0m"
            
            if [ -n "$LAST_PROFILES" ]; then
                echo -e "\033[90mUtilisation des derniers profils : $LAST_PROFILES\033[0m"
                echo -e "\033[90mCommande: docker compose --profile $(echo $LAST_PROFILES | sed 's/,/ --profile /g') down && docker compose --profile ... up -d\033[0m"
                # On utilise la commande recreate du script launch.sh qui supporte maintenant la persistance des profils
                # Il suffit de passer les profils à la commande, ou de laisser le script gérer si on l'appelle correctement
                
                # Méthode 1: Appel direct avec profils
                run_step ./launch.sh --profile "$LAST_PROFILES" recreate
            else
                echo -e "\033[90mCommande: docker compose down && docker compose up -d\033[0m"
                run_step ./launch.sh recreate
            fi
            wait_key
            ;;
        4)
            echo -e "\033[91m⏹️  Arrêt de tous les services...\033[0m"
            echo -e "\033[90mCommande: docker compose down\033[0m"
            run_step ./launch.sh down
            wait_key
            ;;
        5)
            echo -e "\033[96m📋 Containers actifs:\033[0m"
            echo -e "\033[90mCommande: ./launch.sh ps\033[0m"
            run_step ./launch.sh ps
            wait_key
            ;;
        6)
            echo -e "\033[96m➕ Ajout d'un nouveau profil...\033[0m"
            echo -e "\033[90mCommande: ./manage-profiles.sh add\033[0m"
            run_step ./manage-profiles.sh add
            wait_key
            ;;
        7)
            echo -e "\033[96m📝 Liste des profils...\033[0m"
            echo -e "\033[90mCommande: ./manage-profiles.sh list\033[0m"
            run_step ./manage-profiles.sh list
            wait_key
            ;;
        8)
            echo -e "\033[93m🔧 Regénération de docker-compose.yml...\033[0m"
            echo -e "\033[90mCommande: ./manage-profiles.sh generate\033[0m"
            run_step ./manage-profiles.sh generate
            wait_key
            ;;
        9)
            echo -e "\033[96m✅ Validation des profils...\033[0m"
            echo -e "\033[90mCommande: ./validate-profiles.sh\033[0m"
            run_step ./validate-profiles.sh
            wait_key
            ;;
        10)
            echo -e "\033[96m✏️  Édition des secrets...\033[0m"
            echo -e "\033[90mCommande: ./launch.sh edit-secrets\033[0m"
            run_step ./launch.sh edit-secrets
            wait_key
            ;;
        11)
            echo -e "\033[96m👁️  Affichage des secrets...\033[0m"
            echo -e "\033[90mCommande: ./launch.sh view-secrets\033[0m"
            run_step ./launch.sh view-secrets
            wait_key
            ;;
        12)
            echo -e "\033[96m🆕 Initialisation de secrets.env...\033[0m"
            echo -e "\033[90mCommande: ./manage-profiles.sh init-secrets\033[0m"
            run_step ./manage-profiles.sh init-secrets
            wait_key
            ;;
        13)
            echo -e "\033[96m🔄 Synchronisation de secrets.env...\033[0m"
            echo -e "\033[90mCommande: ./manage-profiles.sh sync-secrets\033[0m"
            run_step ./manage-profiles.sh sync-secrets
            wait_key
            ;;
        14)
            echo -e "\033[96m🔐 Connexion AWS SSO...\033[0m"
            echo -e "\033[90mCommande: ./launch.sh sso\033[0m"
            run_step ./launch.sh sso
            wait_key
            ;;
        15)
            echo -e "\033[96m🪪 Identité AWS actuelle:\033[0m"
            echo -e "\033[90mCommande: ./launch.sh id\033[0m"
            run_step ./launch.sh id
            wait_key
            ;;
        16)
            echo -e "\033[96m🐳 Connexion Docker à AWS ECR...\033[0m"
            echo -e "\033[90mCommande: ./launch.sh ecr-login\033[0m"
            run_step ./launch.sh ecr-login
            wait_key
            ;;
        17)
            echo -e "\033[96m📖 Ouverture de README.md...\033[0m"
            if command -v code &> /dev/null; then
                code README.md
            elif command -v nano &> /dev/null; then
                nano README.md
            else
                cat README.md | less
            fi
            ;;
        0|q|Q)
            echo -e "\033[92m👋 Au revoir!\033[0m"
            exit 0
            ;;
        *)
            echo -e "\033[91mOption invalide\033[0m"
            wait_key
            ;;
    esac
done
