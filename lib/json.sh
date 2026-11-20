#!/usr/bin/env bash
# Écriture de JSON pour les sorties --json des scripts Dev.Local (sans jq).
# Ce fichier doit être sourcé.

# Affiche une chaîne JSON entre guillemets.
# Usage : json_string <texte>
json_string() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\n'/\\n}"
    text="${text//$'\r'/\\r}"
    text="${text//$'\t'/\\t}"
    # Les autres caractères de contrôle sont interdits dans une chaîne JSON : retirés
    # (uniquement si le texte en contient, pour ne pas lancer tr à chaque appel)
    if [[ "$text" == *[[:cntrl:]]* ]]; then
        text=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\037')
    fi
    printf '"%s"' "$text"
}

# Comme json_string, mais affiche null pour une valeur YAML absente (vide ou "null")
json_string_or_null() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        printf 'null'
    else
        json_string "$1"
    fi
}

# Affiche true si la valeur vaut exactement "true", false sinon
json_bool() {
    if [ "$1" = "true" ]; then printf 'true'; else printf 'false'; fi
}
