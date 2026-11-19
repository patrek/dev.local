#!/usr/bin/env bash
# YQ_MODE est lu par les scripts qui sourcent ce fichier (ex: validate-profiles.sh)
# shellcheck disable=SC2034
# Fournit la commande `yq` (mikefarah v4+) aux scripts Dev.Local.
#
# Si yq n'est pas installé localement, il est exécuté depuis son image Docker
# (Docker est déjà un prérequis du projet). Il n'y a ainsi qu'un seul parseur
# YAML, avec ou sans installation locale.
#
# Ce fichier doit être sourcé depuis la racine du projet. En mode Docker :
#   - les fichiers passés à yq doivent être des chemins relatifs à la racine
#     (montée en lecture seule dans le conteneur) ;
#   - yq ne lit pas l'entrée standard.

# mapfile et les tableaux associatifs demandent bash 4+ (macOS fournit bash 3.2 : brew install bash)
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "bash 4 ou plus récent est requis (version actuelle : ${BASH_VERSION:-inconnue})." >&2
    echo "Sur macOS : brew install bash" >&2
    exit 1
fi

YQ_IMAGE="${YQ_IMAGE:-mikefarah/yq:4.50.1}"
YQ_MODE=""

_has_local_yq_v4() {
    command -v yq >/dev/null 2>&1 || return 1
    # mikefarah/yq expose la commande 'eval', contrairement à kislyuk/yq
    yq --help 2>&1 | grep -q "eval" || return 1
    local major
    major=$(yq --version 2>&1 | sed -nE 's/.*version v?([0-9]+).*/\1/p' | head -1)
    [ -n "$major" ] && [ "$major" -ge 4 ]
}

if _has_local_yq_v4; then
    YQ_MODE="local"
elif command -v docker >/dev/null 2>&1; then
    YQ_MODE="docker"

    if ! docker image inspect "$YQ_IMAGE" >/dev/null 2>&1; then
        echo -e "\033[93myq non installé localement - téléchargement de l'image $YQ_IMAGE...\033[0m" >&2
        if ! docker pull "$YQ_IMAGE" >&2; then
            echo -e "\033[91mImpossible de télécharger $YQ_IMAGE.\033[0m" >&2
            echo -e "\033[93mInstallez yq v4+ (https://github.com/mikefarah/yq) ou vérifiez votre connexion.\033[0m" >&2
            exit 1
        fi
    fi

    yq() {
        docker run --rm --network none \
            --user "$(id -u):$(id -g)" \
            -v "$PWD":/workdir:ro -w /workdir \
            "$YQ_IMAGE" "$@" </dev/null
    }
else
    echo -e "\033[91myq v4+ (mikefarah) ou Docker est requis pour lire les fichiers YAML.\033[0m" >&2
    exit 1
fi

# Lit plusieurs champs scalaires d'un fichier YAML en un seul appel yq.
# Usage : read_yaml_fields <fichier> <chemin>...
# Résultat dans le tableau YAML_FIELDS (même ordre que les chemins, "null" si absent).
# Le tableau est vide si le fichier est illisible ou n'est pas du YAML valide.
read_yaml_fields() {
    local file="$1"
    shift
    local expr
    expr=$(IFS=,; echo "$*")
    mapfile -t YAML_FIELDS < <(yq e "$expr" "$file" 2>/dev/null)
}
