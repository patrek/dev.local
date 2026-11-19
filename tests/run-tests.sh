#!/bin/bash
# Tests des scripts Bash de Dev.Local
#
# Usage :
#   tests/run-tests.sh            Exécute les tests
#   tests/run-tests.sh --update   Régénère les fichiers attendus (tests/expected)
#
# Les scripts sont copiés avec les fixtures dans un répertoire temporaire :
# le dépôt n'est jamais modifié (sauf tests/expected avec --update).
# yq est utilisé tel que lib/yq.sh le trouve : binaire local, sinon image Docker.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures"
EXPECTED="$ROOT/tests/expected"

UPDATE=false
[ "${1:-}" = "--update" ] && UPDATE=true

PASSED=0
FAILED=0

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
    echo "  ok    $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "  ECHEC $1"
    [ -n "${2:-}" ] && echo "$2" | sed 's/^/        /'
    FAILED=$((FAILED + 1))
}

# Crée un répertoire de travail contenant les scripts, config.yml et les profils valides
# Usage: new_workdir <nom>  ->  affiche le chemin
new_workdir() {
    local dir="$TMP_ROOT/$1"
    mkdir -p "$dir/traefik" "$dir/profiles"
    cp "$ROOT/manage-profiles.sh" "$ROOT/validate-profiles.sh" "$dir/"
    cp -r "$ROOT/lib" "$dir/"
    cp "$ROOT/traefik/traefik.yml" "$dir/traefik/"
    cp "$FIXTURES/config.yml" "$dir/"
    cp "$FIXTURES/profiles/"*.yml "$dir/profiles/"
    echo "$dir"
}

# Compare un fichier généré au fichier attendu, ou le met à jour avec --update
# La ligne d'horodatage est ignorée.
check_golden() {
    local label="$1" actual="$2" expected="$3"
    local normalized="$actual.normalized"

    grep -v '^# Dernière génération' "$actual" > "$normalized"

    if [ "$UPDATE" = true ]; then
        cp "$normalized" "$expected"
        pass "$label (fichier attendu mis à jour)"
        return
    fi

    local differences
    if differences=$(diff -u "$expected" "$normalized" 2>&1); then
        pass "$label"
    else
        fail "$label" "$differences"
    fi
}

test_generate() {
    echo "Génération"
    local dir
    dir=$(new_workdir generate)

    local output
    # COMPOSE_PROJECT_NAME influence les noms de conteneurs générés
    if ! output=$(env -u COMPOSE_PROJECT_NAME bash "$dir/manage-profiles.sh" generate 2>&1); then
        fail "manage-profiles.sh generate" "$output"
        return
    fi
    pass "manage-profiles.sh generate"

    check_golden "docker-compose.yml conforme" "$dir/docker-compose.yml" "$EXPECTED/docker-compose.yml"
    check_golden "traefik/dynamic.yml conforme" "$dir/traefik/dynamic.yml" "$EXPECTED/traefik-dynamic.yml"

    if command -v docker >/dev/null 2>&1; then
        if output=$(cd "$dir" && docker compose config --quiet 2>&1); then
            pass "docker-compose.yml accepté par docker compose"
        else
            fail "docker-compose.yml accepté par docker compose" "$output"
        fi
    else
        echo "  saut  docker compose config (docker absent)"
    fi
}

test_valid_profiles() {
    echo "Validation des profils valides"
    local dir
    dir=$(new_workdir valid)

    local output
    if output=$(bash "$dir/validate-profiles.sh" 2>&1); then
        pass "validate-profiles.sh accepte les fixtures"
    else
        fail "validate-profiles.sh accepte les fixtures" "$output"
    fi
}

# Chaque fichier de fixtures/invalid commence par "# expect: <texte>" :
# la validation doit échouer et afficher ce texte.
test_invalid_profiles() {
    echo "Validation des profils invalides"
    local fixture
    for fixture in "$FIXTURES/invalid/"*.yml; do
        local name
        name=$(basename "$fixture" .yml)
        local expected_message
        expected_message=$(sed -n '1s/^# expect: //p' "$fixture")

        local dir
        dir=$(new_workdir "invalid-$name")
        cp "$fixture" "$dir/profiles/zz-$name.yml"

        local output status
        output=$(bash "$dir/validate-profiles.sh" 2>&1)
        status=$?

        if [ "$status" -eq 0 ]; then
            fail "$name est rejeté" "validate-profiles.sh a réussi (code 0)"
        elif ! echo "$output" | grep -qF "$expected_message"; then
            fail "$name est rejeté" "message attendu absent : $expected_message"
        else
            pass "$name est rejeté"
        fi
    done
}

test_generate
if [ "$UPDATE" = false ]; then
    test_valid_profiles
    test_invalid_profiles
fi

echo ""
echo "Réussis : $PASSED   Échecs : $FAILED"
[ "$FAILED" -eq 0 ]
