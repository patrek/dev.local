#!/usr/bin/env bash
# Teste les scripts PowerShell sur les fixtures, puis compare la génération de
# manage-profiles.ps1 et sa détection des secrets à celles de manage-profiles.sh.
#
# Usage :
#   tests/compare-shells.sh                     Tests PowerShell + comparaison avec Bash
#   tests/compare-shells.sh --powershell-only   Tests PowerShell uniquement
#
# La comparaison porte sur la sortie de "docker compose config" : elle ignore la mise en
# forme et les commentaires, et ne montre que les différences de configuration réelles.
#
# Prérequis : docker, pwsh et le module PowerShell powershell-yaml.
# Codes de sortie : 0 succès, 1 test PowerShell en échec, 2 prérequis manquant,
#                   3 différences entre Bash et PowerShell.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures"

POWERSHELL_ONLY=false
[ "${1:-}" = "--powershell-only" ] && POWERSHELL_ONLY=true

for tool in docker pwsh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Prérequis manquant : $tool"
        exit 2
    fi
done
if ! pwsh -NoLogo -NoProfile -Command 'if (Get-Module -ListAvailable powershell-yaml) { exit 0 } else { exit 1 }'; then
    echo "Prérequis manquant : module PowerShell powershell-yaml (Install-Module powershell-yaml)"
    exit 2
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Usage: new_workdir <nom> <fichier de script>...
new_workdir() {
    local dir="$TMP_ROOT/$1"
    shift
    mkdir -p "$dir/traefik" "$dir/profiles"
    local script
    for script in "$@"; do
        cp -r "$ROOT/$script" "$dir/"
    done
    cp "$ROOT/traefik/traefik.yml" "$dir/traefik/"
    cp "$FIXTURES/config.yml" "$dir/"
    cp "$FIXTURES/profiles/"*.yml "$dir/profiles/"
    echo "$dir"
}

# Configuration résolue par docker compose, sans les chemins propres au répertoire de travail
resolved_config() {
    local dir="$1"
    (cd "$dir" && docker compose config --no-interpolate) | sed "s|$dir|WORKDIR|g"
}

echo "Génération avec PowerShell"
ps_dir=$(new_workdir powershell manage-profiles.ps1 validate-profiles.ps1)
if ! (cd "$ps_dir" && pwsh -NoLogo -NoProfile -File ./manage-profiles.ps1 -Action generate); then
    echo "ECHEC : manage-profiles.ps1 generate a échoué"
    exit 1
fi
for generated in docker-compose.yml traefik/dynamic.yml; do
    if [ ! -s "$ps_dir/$generated" ]; then
        echo "ECHEC : $generated n'a pas été généré par PowerShell"
        exit 1
    fi
done
# Les fichiers générés n'ont que des fins de ligne LF, comme ceux de manage-profiles.sh
for generated in docker-compose.yml traefik/dynamic.yml; do
    if grep -q $'\r' "$ps_dir/$generated"; then
        echo "ECHEC : $generated généré par PowerShell contient des fins de ligne CRLF"
        exit 1
    fi
done
echo "  ok    fichiers générés par PowerShell en LF"
if ! (cd "$ps_dir" && docker compose config --quiet); then
    echo "ECHEC : le docker-compose.yml généré par PowerShell est refusé par docker compose"
    exit 1
fi
echo "  ok    génération PowerShell acceptée par docker compose"

# list-secrets exécute la détection de sync-secrets sans SOPS ni déchiffrement
echo "Détection des secrets avec PowerShell"
if ! (cd "$ps_dir" && pwsh -NoLogo -NoProfile -File ./manage-profiles.ps1 -Action list-secrets) > "$TMP_ROOT/secrets.powershell.raw"; then
    echo "ECHEC : manage-profiles.ps1 list-secrets a échoué"
    exit 1
fi
tr -d '\r' < "$TMP_ROOT/secrets.powershell.raw" > "$TMP_ROOT/secrets.powershell.txt"
if ! diff -u --label attendu --label powershell "$ROOT/tests/expected/secrets.txt" "$TMP_ROOT/secrets.powershell.txt"; then
    echo "ECHEC : les variables de secrets détectées par PowerShell diffèrent de tests/expected/secrets.txt"
    exit 1
fi
echo "  ok    variables de secrets détectées conformes"

# validate-profiles.ps1 lit les profils avec powershell-yaml : il ne dépend ni de yq ni du
# répertoire courant. Le mode "isole" le vérifie : PATH réduit à un répertoire vide (pwsh
# appelé par son chemin absolu, yq introuvable qu'il soit installé ou non) et exécution
# depuis un autre répertoire que celui du script.
PWSH_BIN=$(command -v pwsh)
EMPTY_PATH_DIR="$TMP_ROOT/path-sans-yq"
mkdir -p "$EMPTY_PATH_DIR"

# Usage: run_ps_validator <répertoire de travail> <normal|isole>
run_ps_validator() {
    if [ "$2" = isole ]; then
        (cd "$TMP_ROOT" && PATH="$EMPTY_PATH_DIR" "$PWSH_BIN" -NoLogo -NoProfile -File "$1/validate-profiles.ps1" 2>&1)
    else
        (cd "$1" && pwsh -NoLogo -NoProfile -File ./validate-profiles.ps1 2>&1)
    fi
}

# Profil valide qui piégeait une lecture approximative du YAML : "non" hors des ports,
# et traefik.enabled à false alors que enabled est à true (aucun champ Traefik requis).
valid_dir=$(new_workdir powershell-valid validate-profiles.ps1)
cat > "$valid_dir/profiles/zz-pieges.yml" << 'EOF'
name: pieges
description: "non"
enabled: true
always_active: true
docker_profile: null

docker-compose:
  image: nginx:alpine
  container_name: pieges
  ports:
    - "8099:80"
  environment:
    - REPONSE="non"

traefik:
  enabled: false
EOF

echo "Validation avec PowerShell"
for mode in normal isole; do
    label="validate-profiles.ps1 accepte les fixtures et le profil piège ($mode)"
    if ! output=$(run_ps_validator "$valid_dir" "$mode"); then
        echo "ECHEC : $label"
        echo "$output"
        exit 1
    fi
    echo "  ok    $label"
done

# Chaque fichier de fixtures/invalid commence par "# expect: <texte>" :
# la validation doit échouer et afficher ce texte.
for fixture in "$FIXTURES/invalid/"*.yml; do
    name=$(basename "$fixture" .yml)
    expected_message=$(sed -n '1s/^# expect: //p' "$fixture")
    invalid_dir=$(new_workdir "powershell-invalid-$name" validate-profiles.ps1)
    cp "$fixture" "$invalid_dir/profiles/zz-$name.yml"

    for mode in normal isole; do
        output=$(run_ps_validator "$invalid_dir" "$mode")
        validation_status=$?
        if [ "$validation_status" -eq 0 ]; then
            echo "ECHEC : $name est accepté par validate-profiles.ps1 ($mode)"
            exit 1
        elif ! echo "$output" | grep -qF "$expected_message"; then
            echo "ECHEC : $name est rejeté sans le message attendu ($mode) : $expected_message"
            exit 1
        fi
    done
    echo "  ok    $name est rejeté"
done

[ "$POWERSHELL_ONLY" = true ] && exit 0

echo "Génération avec Bash"
sh_dir=$(new_workdir bash manage-profiles.sh validate-profiles.sh lib)
if ! (cd "$sh_dir" && bash ./manage-profiles.sh generate >/dev/null); then
    echo "ECHEC : manage-profiles.sh generate a échoué"
    exit 1
fi

echo "Comparaison Bash / PowerShell"
status=0

# Même verdict que PowerShell sur le profil piège
mkdir -p "$TMP_ROOT/bash-valid"
cp -r "$ROOT/validate-profiles.sh" "$ROOT/lib" "$valid_dir/profiles" "$TMP_ROOT/bash-valid/"
if output=$(bash "$TMP_ROOT/bash-valid/validate-profiles.sh" 2>&1); then
    echo "  ok    validate-profiles.sh accepte aussi le profil piège"
else
    echo "  DIFF  validate-profiles.sh refuse le profil piège accepté par PowerShell"
    echo "$output"
    status=3
fi

resolved_config "$sh_dir" > "$TMP_ROOT/compose.bash.yml"
resolved_config "$ps_dir" > "$TMP_ROOT/compose.powershell.yml"
if diff -u --label bash --label powershell "$TMP_ROOT/compose.bash.yml" "$TMP_ROOT/compose.powershell.yml"; then
    echo "  ok    docker-compose.yml équivalent"
else
    echo "  DIFF  docker-compose.yml"
    status=3
fi

# dynamic.yml n'est pas un fichier Compose : comparaison du contenu sans commentaires,
# lignes vides ni fins de ligne Windows
strip_comments() { tr -d '\r' < "$1" | grep -vE '^[[:space:]]*(#|$)'; }
if diff -u --label bash --label powershell <(strip_comments "$sh_dir/traefik/dynamic.yml") <(strip_comments "$ps_dir/traefik/dynamic.yml"); then
    echo "  ok    traefik/dynamic.yml équivalent"
else
    echo "  DIFF  traefik/dynamic.yml"
    status=3
fi

if ! (cd "$sh_dir" && bash ./manage-profiles.sh list-secrets) > "$TMP_ROOT/secrets.bash.txt"; then
    echo "ECHEC : manage-profiles.sh list-secrets a échoué"
    exit 1
fi
if diff -u --label bash --label powershell "$TMP_ROOT/secrets.bash.txt" "$TMP_ROOT/secrets.powershell.txt"; then
    echo "  ok    mêmes variables de secrets détectées"
else
    echo "  DIFF  variables de secrets détectées"
    status=3
fi

exit "$status"
