#!/usr/bin/env bash
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

# Aucun port ne doit être publié sur toutes les interfaces par défaut : chaque entrée
# d'une section ports commence par 127.0.0.1:, sauf l'IP explicite de la fixture web.
# En syntaxe longue (target / published), l'entrée doit contenir host_ip: 127.0.0.1.
# Une section ports qui n'est pas écrite en liste (ports: [...]) est aussi une erreur.
check_ports_bound_to_localhost() {
    local compose_file="$1"
    local explicit_ip_port="0.0.0.0:3002:3002"

    local unbound
    unbound=$(awk -v allowed="$explicit_ip_port" '
        function flush_long() { if (long_item != "" && !long_bound) print long_item; long_item = "" }
        function is_local_ip(text) { return text ~ /^host_ip: ["\047]?127\.0\.0\.1["\047]?$/ }
        /^    ports:/ { flush_long(); in_ports = ($0 == "    ports:"); if (!in_ports) print; next }
        in_ports && /^      - / {
            flush_long()
            port = $0
            sub(/^      - /, "", port)
            if (port ~ /^[a-z_]+:( |$)/) {
                long_item = $0
                long_bound = is_local_ip(port)
                next
            }
            gsub(/["\047]/, "", port)
            if (port !~ /^127\.0\.0\.1:/ && port != allowed) print
            next
        }
        in_ports && /^        [a-z_]+:/ {
            field = $0
            sub(/^        /, "", field)
            if (is_local_ip(field)) long_bound = 1
            next
        }
        { flush_long(); in_ports = 0 }
        END { flush_long() }
    ' "$compose_file")

    if [ -z "$unbound" ]; then
        pass "ports publiés sur 127.0.0.1 uniquement"
    else
        fail "ports publiés sur 127.0.0.1 uniquement" "$unbound"
    fi
}

test_generate() {
    echo "Génération"
    local dir
    dir=$(new_workdir generate)

    local output
    if ! output=$(bash "$dir/manage-profiles.sh" generate 2>&1); then
        fail "manage-profiles.sh generate" "$output"
        return
    fi
    pass "manage-profiles.sh generate"

    check_golden "docker-compose.yml conforme" "$dir/docker-compose.yml" "$EXPECTED/docker-compose.yml"
    check_golden "traefik/dynamic.yml conforme" "$dir/traefik/dynamic.yml" "$EXPECTED/traefik-dynamic.yml"

    check_ports_bound_to_localhost "$dir/docker-compose.yml"

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

# list-secrets exécute la détection de sync-secrets sans SOPS ni déchiffrement
test_secret_detection() {
    echo "Détection des secrets"
    local dir
    dir=$(new_workdir secrets)

    local output
    if ! output=$(bash "$dir/manage-profiles.sh" list-secrets 2>&1); then
        fail "manage-profiles.sh list-secrets" "$output"
        return
    fi
    printf '%s\n' "$output" > "$dir/secrets.txt"

    check_golden "variables de secrets détectées conformes" "$dir/secrets.txt" "$EXPECTED/secrets.txt"
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

    if output=$(bash "$dir/validate-profiles.sh" --help 2>&1) && echo "$output" | grep -q "Usage:"; then
        pass "validate-profiles.sh --help affiche l'aide"
    else
        fail "validate-profiles.sh --help affiche l'aide" "$output"
    fi

    if output=$(bash "$dir/validate-profiles.sh" --inconnu 2>&1); then
        fail "validate-profiles.sh refuse un argument inconnu" "code 0 au lieu d'une erreur"
    elif echo "$output" | grep -q "Argument inconnu: --inconnu"; then
        pass "validate-profiles.sh refuse un argument inconnu"
    else
        fail "validate-profiles.sh refuse un argument inconnu" "$output"
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

# Vérifie qu'une sortie contient un texte
# Usage: check_contains <libellé> <sortie> <texte attendu>
check_contains() {
    if echo "$2" | grep -qF -- "$3"; then
        pass "$1"
    else
        fail "$1" "texte attendu absent : $3"$'\n'"$2"
    fi
}

# Sorties JSON et commandes sans question, destinées aux outils et aux agents IA.
# stdout ne doit contenir que le JSON : il est comparé tel quel.
test_machine_interface() {
    echo "Interface pour les outils (--json, --dry-run, add sans question)"
    local dir
    dir=$(new_workdir machine)
    cp "$ROOT/launch.sh" "$dir/"

    local output
    if output=$(bash "$dir/manage-profiles.sh" list --json 2>/dev/null); then
        printf '%s\n' "$output" > "$dir/profiles.json"
        check_golden "list --json conforme" "$dir/profiles.json" "$EXPECTED/profiles.json"
    else
        fail "manage-profiles.sh list --json" "$output"
    fi
    [ "$UPDATE" = true ] && return

    output=$(bash "$dir/manage-profiles.sh" generate --dry-run --json 2>/dev/null)
    if [ "$output" = '[{"file":"docker-compose.yml","status":"new"},{"file":"traefik/dynamic.yml","status":"new"}]' ] \
        && [ ! -e "$dir/docker-compose.yml" ] && [ ! -e "$dir/traefik/dynamic.yml" ]; then
        pass "generate --dry-run --json n'écrit aucun fichier"
    else
        fail "generate --dry-run --json n'écrit aucun fichier" "$output"
    fi

    bash "$dir/manage-profiles.sh" generate > /dev/null 2>&1
    output=$(bash "$dir/manage-profiles.sh" generate --dry-run --json 2>/dev/null)
    if [ "$output" = '[{"file":"docker-compose.yml","status":"unchanged"},{"file":"traefik/dynamic.yml","status":"unchanged"}]' ]; then
        pass "generate --dry-run --json après génération : unchanged"
    else
        fail "generate --dry-run --json après génération : unchanged" "$output"
    fi

    if output=$(bash "$dir/validate-profiles.sh" --json 2>/dev/null); then
        check_contains "validate --json sur des profils valides" "$output" '{"valid":true,'
        check_contains "validate --json sans erreur" "$output" '"errors":[],"warnings":[]}'
    else
        fail "validate --json sur des profils valides" "$output"
    fi

    # add sans question : aucune entrée standard disponible
    if output=$(bash "$dir/manage-profiles.sh" add --name "Outil Test" --image nginx:alpine \
            --description 'Un "test"' --docker-port 8000 --publish 9100:8000 --docker-profile outil \
            --traefik-prefix /outil --env 'A=1' --env "B=it's: #x" --secret outil_token < /dev/null 2>&1) \
        && [ -f "$dir/profiles/outil-test.yml" ]; then
        pass "add sans question crée le profil"
    else
        fail "add sans question crée le profil" "$output"
    fi
    if grep -q '^  outil-test:$' "$dir/docker-compose.yml" \
        && grep -qF -- '- "127.0.0.1:9100:8000"' "$dir/docker-compose.yml" \
        && grep -qF -- "- 'B=it''s: #x'" "$dir/docker-compose.yml"; then
        pass "add sans question regénère docker-compose.yml"
    else
        fail "add sans question regénère docker-compose.yml" "$(grep -A12 '^  outil-test:$' "$dir/docker-compose.yml")"
    fi
    output=$(bash "$dir/manage-profiles.sh" generate --dry-run --json 2>/dev/null)
    check_contains "generate --dry-run après add : unchanged" "$output" '"docker-compose.yml","status":"unchanged"'

    if output=$(bash "$dir/manage-profiles.sh" add --name outil-test --image nginx < /dev/null 2>&1); then
        fail "add refuse un profil existant" "code 0 au lieu d'une erreur"
    else
        pass "add refuse un profil existant"
    fi
    if output=$(bash "$dir/manage-profiles.sh" add --name autre --image nginx --docker-port abc < /dev/null 2>&1) \
        || [ -e "$dir/profiles/autre.yml" ]; then
        fail "add refuse un port invalide" "$output"
    else
        pass "add refuse un port invalide"
    fi
    if output=$(bash "$dir/manage-profiles.sh" list --inconnu 2>&1); then
        fail "manage-profiles.sh refuse une option inconnue" "code 0 au lieu d'une erreur"
    else
        check_contains "manage-profiles.sh refuse une option inconnue" "$output" "Argument inconnu"
    fi

    cp "$FIXTURES/invalid/bad-port-non.yml" "$dir/profiles/zz-bad.yml"
    if output=$(bash "$dir/validate-profiles.sh" --json 2>/dev/null); then
        fail "validate --json signale les erreurs" "code 0 au lieu d'une erreur"
    else
        check_contains "validate --json signale les erreurs" "$output" \
            '"errors":[{"profile":"zz-bad","message":"Port invalide dans docker-compose.ports'
    fi
    rm "$dir/profiles/zz-bad.yml"

    if command -v docker >/dev/null 2>&1; then
        if output=$(bash "$dir/launch.sh" status --json 2>/dev/null); then
            check_contains "launch.sh status --json liste les services" "$output" \
                '{"service":"api","state":"not_created","health":null}'
        else
            fail "launch.sh status --json liste les services" "$output"
        fi
    else
        echo "  saut  launch.sh status --json (docker absent)"
    fi
}

test_generate
test_secret_detection
test_machine_interface
if [ "$UPDATE" = false ]; then
    test_valid_profiles
    test_invalid_profiles
fi

echo ""
echo "Réussis : $PASSED   Échecs : $FAILED"
[ "$FAILED" -eq 0 ]
