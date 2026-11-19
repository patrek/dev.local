<#
.SYNOPSIS
    Script principal de gestion des services Dev.Local 2.0

.DESCRIPTION
    Gère le cycle de vie des services Docker avec support SOPS pour les secrets.
    Le script peut être appelé depuis n'importe quel répertoire. Le répertoire courant et
    les variables d'environnement de la session appelante sont rétablis à la fin.
    Le code de sortie est celui de la dernière commande docker, aws ou sops exécutée.

.PARAMETER SelectedProfiles
    Profils à démarrer (séparés par virgules). Alias : -p, -profile

.PARAMETER Command
    Commande (alias : -c), aussi acceptée en première position :
      start, up       Démarrer les services (défaut)
      stop, down      Arrêter les services
      recreate        Arrêter puis redémarrer les services
      ps              Lister les containers
      logs            Suivre les logs (de tous les services ou de -ServiceItem)
      run             Exécuter une commande ponctuelle dans un service
      sso             Connexion AWS SSO
      id              Afficher l'identité AWS
      ecr-login       Connecter Docker à AWS ECR
      jfrog-login     Connecter Docker à JFrog
      edit-secrets    Éditer les secrets avec SOPS
      view-secrets    Afficher les secrets déchiffrés

.PARAMETER ServiceItem
    Service visé par les commandes logs et run (alias : -s, -service), aussi accepté en
    deuxième position.

.PARAMETER runArgs
    Pour la commande run : la commande à exécuter dans le conteneur, après le nom du service.
    Placer "--" avant les arguments qui commencent par un tiret (inutile avec "just run").
    "--" n'est pas reconnu avec "pwsh -File" : utiliser "pwsh -Command" dans ce cas.

.EXAMPLE
    .\launch.ps1
    Démarre tous les services

.EXAMPLE
    .\launch.ps1 -p api,frontend
    Démarre uniquement les services api et frontend

.EXAMPLE
    .\launch.ps1 logs -service api
    Suit les logs du service api

.EXAMPLE
    .\launch.ps1 -c edit-secrets
    Édite les secrets avec SOPS

.EXAMPLE
    .\launch.ps1 run gulp -- npx gulp build --production
    Exécute une commande ponctuelle dans le service gulp
#>

param(
    [Alias("p", "profile")]
    [string]$SelectedProfiles,

    [Parameter(Position = 0)]
    [Alias("c")]
    [ValidateSet('up', 'start', 'stop', 'down', 'recreate', 'ps', 'logs', 'run', 'sso', 'id', 'ecr-login', 'jfrog-login', 'edit-secrets', 'view-secrets')]
    [string]$Command = 'start',

    [Parameter(Position = 1)]
    [Alias("s", "service")]
    [string]$ServiceItem,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$runArgs
)

$PSDefaultParameterValues['*:Encoding'] = 'UTF8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Rétablir les variables d'environnement du processus telles qu'elles étaient au lancement.
# Le script peut tourner dans la session interactive de l'appelant (menu.ps1, console) :
# sans cela, les secrets déchiffrés et COMPOSE_PROFILES y resteraient après la fin du script.
function Restore-Environment {
    param([System.Collections.IDictionary]$saved)

    $current = [Environment]::GetEnvironmentVariables()
    foreach ($name in @($current.Keys)) {
        if (-not $saved.Contains($name)) {
            Remove-Item -LiteralPath "env:$name"
        }
    }
    foreach ($name in @($saved.Keys)) {
        if ($current[$name] -cne $saved[$name]) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
        }
    }
}

# Écrire sur stderr ce qui arrive par le pipeline (messages, avertissements, erreurs)
filter Write-ToStderr {
    if ($_ -is [System.Management.Automation.WarningRecord]) {
        [Console]::Error.WriteLine("WARNING: $_")
    }
    else {
        [Console]::Error.WriteLine("$_")
    }
}

# Permet aux profils d'exécuter les conteneurs avec l'utilisateur courant
# (user: "${HOST_UID:-1000}:${HOST_GID:-1000}") pour ne pas créer de fichiers root.
# Sous Windows, les variables restent absentes (les profils utilisent alors leur valeur par défaut).
function Set-HostUser {
    if (-not ($IsLinux -or $IsMacOS)) {
        return
    }
    if (-not $env:HOST_UID) { $env:HOST_UID = (& id -u) }
    if (-not $env:HOST_GID) { $env:HOST_GID = (& id -g) }
}

# Valider Docker Compose
function Validate-DockerCompose {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker n'est pas installé"
        exit 1
    }

    $ver = docker compose version 2>$null
    if (-not $ver) {
        Write-Error "Docker Compose v2+ requis"
        exit 1
    }
}

# Valider SOPS
function Validate-Sops {
    if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
        Write-Warning "SOPS n'est pas installé - la gestion des secrets ne sera pas disponible"
        return $false
    }
    return $true
}

# Valider la configuration SOPS (.sops.yaml)
function Validate-SopsConfig {
    if (-not (Test-Path ".sops.yaml")) {
        Write-Error ".sops.yaml non trouvé"
        return $false
    }

    # Vérifier si une méthode de chiffrement est active (non commentée)
    # Note: On lit le contenu comme texte pour chercher les commentaires
    $content = Get-Content ".sops.yaml" -Raw

    # Regex pour chercher kms: ou age: au début de la ligne ou après des espaces/tirets, mais pas après un #
    if ($content -notmatch "(?m)^\s*(- )?(kms|age|pgp|gcp_kms|azure_kv|hc_vault):") {
        Write-Error "Aucune méthode de chiffrement configurée dans .sops.yaml"
        Write-Warning "Veuillez éditer .sops.yaml pour décommenter et configurer 'kms' ou 'age'"
        return $false
    }

    return $true
}

# Charger et déchiffrer les secrets
function Load-Secrets {
    if (-not (Test-Path "secrets.env")) {
        Write-Warning "secrets.env non trouvé - créez-le avec: .\manage-profiles.ps1 -Action init-secrets"
        return
    }

    if (-not (Validate-Sops)) {
        return
    }

    if (-not (Validate-SopsConfig)) {
        Write-Warning "Configuration SOPS invalide. Les secrets ne seront pas chargés."
        return
    }

    Write-Host "🔐 Déchiffrement des secrets avec SOPS..." -ForegroundColor Cyan

    try {
        # La sortie de SOPS reste en mémoire : aucun secret en clair n'est écrit sur le disque
        $decrypted = & sops -d secrets.env 2>$null

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Échec du déchiffrement SOPS (code: $LASTEXITCODE). Vérifiez votre configuration AWS/Age"
            Write-Warning "Les services démarreront sans secrets"
            return
        }

        # Même analyse que load_secrets de launch.sh : la clé va jusqu'au premier "=",
        # la valeur est conservée telle quelle (espaces compris). [ \t\n\v\f\r] équivaut
        # à [[:space:]], que les expressions régulières .NET ne connaissent pas.
        $count = 0
        foreach ($line in @($decrypted)) {
            # Ignorer les commentaires et lignes vides
            if ([string]::IsNullOrEmpty($line) -or $line -cmatch '^[ \t\n\v\f\r]*#') {
                continue
            }

            if ($line -cmatch '(?s)^[ \t\n\v\f\r]*([^=]+)=(.+)\z') {
                $key = $matches[1]
                $value = $matches[2]

                # Valider le nom de variable (sécurité contre injection)
                if ($key -cmatch '^[A-Za-z_][A-Za-z0-9_]*\z') {
                    [Environment]::SetEnvironmentVariable($key, $value, "Process")
                    $count++
                }
                else {
                    Write-Warning "Variable ignorée (nom invalide): $key"
                }
            }
        }

        if ($count -eq 0) {
            Write-Host "Aucun secret trouvé dans secrets.env" -ForegroundColor Yellow
        }
        else {
            Write-Host "✅ $count secret(s) chargé(s) de manière sécurisée" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Erreur lors du déchiffrement : $_"
    }
}

# Éditer les secrets
function Edit-Secrets {
    if (-not (Validate-Sops)) {
        Write-Error "SOPS requis pour éditer les secrets"
        exit 1
    }

    if (-not (Validate-SopsConfig)) {
        exit 1
    }

    if (-not (Test-Path "secrets.env")) {
        Write-Host "Création de secrets.env..." -ForegroundColor Yellow
        & .\manage-profiles.ps1 -Action init-secrets
        exit $LASTEXITCODE
    }

    Write-Host "📝 Ouverture de l'éditeur SOPS..." -ForegroundColor Cyan
    & sops secrets.env

    # SOPS retourne 200 si le fichier n'a pas été modifié, ce qui est normal
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 200) {
        exit 0
    }

    Write-Error "Erreur SOPS (code: $LASTEXITCODE)"
    exit $LASTEXITCODE
}

# Voir les secrets déchiffrés
function View-Secrets {
    if (-not (Validate-Sops)) {
        Write-Error "SOPS requis"
        exit 1
    }

    if (-not (Validate-SopsConfig)) {
        exit 1
    }

    if (-not (Test-Path "secrets.env")) {
        Write-Error "secrets.env non trouvé"
        exit 1
    }

    Write-Host "🔍 Secrets déchiffrés:" -ForegroundColor Cyan
    Write-Warning "⚠️  ATTENTION: Les secrets seront affichés en clair"
    $confirmation = Read-Host "Continuer? (y/N)"

    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Annulé" -ForegroundColor DarkGray
        exit 0
    }

    # Afficher avec pagination sécurisée
    & sops -d secrets.env | Out-Host -Paging

    # Comme launch.sh, dont le code de sortie est celui du pager et non celui de sops
    exit 0
}

# Générer docker-compose.yml s'il n'existe pas encore
function Ensure-ComposeFile {
    if (-not (Test-Path "docker-compose.yml")) {
        Write-Warning "docker-compose.yml non trouvé. Génération..."
        & .\manage-profiles.ps1 -Action generate
    }
}

# Exécuter une commande ponctuelle dans un service (ex: run gulp npx gulp build)
# Les messages vont sur stderr pour que stdout ne contienne que la sortie de la commande
function Invoke-RunCommand {
    param(
        [string]$service,
        [string[]]$arguments
    )

    if ([string]::IsNullOrWhiteSpace($service)) {
        Write-Error "Service requis. Usage: .\launch.ps1 run <service> [commande...]"
        exit 1
    }

    Ensure-ComposeFile *>&1 | Write-ToStderr
    Load-Secrets *>&1 | Write-ToStderr

    # --profile "*" : le service est utilisable même si son profil Docker n'est pas démarré
    docker compose --profile "*" run --rm $service @arguments
}

# Démarrer les services
function Start-Services {
    param([string]$profiles)

    Ensure-ComposeFile

    Load-Secrets

    if ($profiles) {
        $env:COMPOSE_PROFILES = $profiles
        Write-Host "🚀 Démarrage des profils: $profiles" -ForegroundColor Cyan
    }
    else {
        if (Test-Path env:COMPOSE_PROFILES) {
            Remove-Item env:COMPOSE_PROFILES
        }
        Write-Host "🚀 Démarrage de tous les services" -ForegroundColor Cyan
    }

    docker compose up -d
}

# Arrêter les services
function Stop-Services {
    Write-Host "⏹️ Arrêt des services" -ForegroundColor Yellow
    docker compose --profile "*" down
}

# Recréer les services
function Recreate-Services {
    Write-Host "🔄 Recréation des services" -ForegroundColor Yellow
    docker compose --profile "*" down
    Start-Services -profiles $SelectedProfiles
}

# Lister les containers
function List-Containers {
    Write-Host "`n📋 CONTAINERS ACTIFS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    docker compose ps
    Write-Host "`n"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Afficher les logs
function Show-Logs {
    param([string]$service)

    if ($service) {
        Write-Host "📋 Logs du service: $service" -ForegroundColor Cyan
        docker compose logs -f $service
    }
    else {
        Write-Host "📋 Logs de tous les services" -ForegroundColor Cyan
        docker compose logs -f
    }
}

# Charger config.yml une seule fois. Sans le module powershell-yaml ou si le fichier est
# illisible, un avertissement est affiché une fois et les valeurs par défaut sont utilisées.
$script:Config = $null
$script:ConfigLoaded = $false
function Get-Config {
    if ($script:ConfigLoaded) {
        return $script:Config
    }
    $script:ConfigLoaded = $true

    $configPath = Join-Path $PSScriptRoot "config.yml"
    if (-not (Test-Path $configPath)) {
        return $null
    }

    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Write-Warning "Module 'powershell-yaml' introuvable : config.yml est ignoré, les valeurs par défaut sont utilisées."
        Write-Warning "Pour l'installer : Install-Module powershell-yaml -Scope CurrentUser"
        return $null
    }

    try {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:Config = Get-Content $configPath -Raw | ConvertFrom-Yaml -ErrorAction Stop
    }
    catch {
        Write-Warning "config.yml illisible, les valeurs par défaut sont utilisées : $_"
    }
    return $script:Config
}

# Lire une valeur de config.yml (ex: Get-ConfigValue @('aws', 'region') 'ca-central-1')
function Get-ConfigValue {
    param(
        [string[]]$path,
        [string]$default
    )

    $value = Get-Config
    foreach ($key in $path) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) {
            return $default
        }
        $value = $value[$key]
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $default
    }
    return [string]$value
}

# Profil AWS : AWS_PROFILE s'il est défini, sinon aws.profile de config.yml
function Get-AwsProfile {
    if ($env:AWS_PROFILE) {
        return $env:AWS_PROFILE
    }
    return Get-ConfigValue @('aws', 'profile') 'ESG-DV-PowerUser-SSO'
}

# AWS SSO
function Connect-AwsSso {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI non installé"
        exit 1
    }

    Write-Host "🔐 Connexion AWS SSO..." -ForegroundColor Cyan
    aws sso login --profile (Get-AwsProfile)
}

# AWS Identity
function Show-AwsIdentity {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI non installé"
        exit 1
    }

    Write-Host "🪪 Identité AWS:" -ForegroundColor Cyan
    aws sts get-caller-identity --profile (Get-AwsProfile)
}

# Docker ECR Login
function Connect-EcrLogin {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI non installé"
        exit 1
    }

    $ecrUrl = Get-ConfigValue @('registries', 'ecr', 'url') '<id>.dkr.ecr.ca-central-1.amazonaws.com'
    $region = Get-ConfigValue @('aws', 'region') 'ca-central-1'

    Write-Host "🐳 Connexion Docker à AWS ECR..." -ForegroundColor Cyan

    # Le mot de passe reste en mémoire et passe à docker par l'entrée standard, sans fichier temporaire
    $password = aws ecr get-login-password --profile (Get-AwsProfile) --region $region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($password)) {
        Write-Error "Échec de récupération du mot de passe ECR"
        exit 1
    }

    $password | docker login --username AWS --password-stdin $ecrUrl
}

# Docker JFrog Login
function Connect-JfrogLogin {
    $jfrogUrl = Get-ConfigValue @('registries', 'jfrog', 'url') 'custom.jfrog.io'

    Write-Host "🐳 Connexion Docker à JFrog..." -ForegroundColor Cyan
    Write-Host "Utilisez: docker login $jfrogUrl" -ForegroundColor Yellow
    Write-Host "Entrez vos identifiants JFrog lorsque demandé" -ForegroundColor Yellow
    docker login $jfrogUrl
}

# Main

# Un argument en trop est une erreur, pour qu'une faute de frappe ne démarre pas les services
$extraArguments = @()
if ($Command -notin @('run', 'logs') -and $ServiceItem) { $extraArguments += $ServiceItem }
if ($Command -ne 'run' -and $runArgs) { $extraArguments += $runArgs }
if ($extraArguments.Count -gt 0) {
    Write-Host "Argument inconnu: $($extraArguments -join ' ')" -ForegroundColor Red
    Write-Host "Usage: .\launch.ps1 [start|stop|recreate|ps|logs [service]|sso|id|ecr-login|jfrog-login|edit-secrets|view-secrets]"
    Write-Host "       .\launch.ps1 -p <profils> start"
    Write-Host "       .\launch.ps1 run <service> [commande...]"
    exit 1
}

# Les chemins du script (secrets.env, .sops.yaml, docker-compose.yml, manage-profiles.ps1)
# sont relatifs à son répertoire. Le bloc finally s'exécute aussi sur "exit", sur une
# erreur et sur Ctrl+C : l'appelant retrouve son répertoire et son environnement.
$initialEnvironment = [Environment]::GetEnvironmentVariables()
Push-Location -LiteralPath $PSScriptRoot -StackName 'DevLocalLaunch'
try {
    Set-HostUser
    Validate-DockerCompose

    switch ($Command) {
        'up' { Start-Services -profiles $SelectedProfiles }
        'start' { Start-Services -profiles $SelectedProfiles }
        'stop' { Stop-Services }
        'down' { Stop-Services }
        'recreate' { Recreate-Services }
        'ps' { List-Containers }
        'logs' { Show-Logs -service $ServiceItem }
        'run' { Invoke-RunCommand -service $ServiceItem -arguments $runArgs }
        'sso' { Connect-AwsSso }
        'id' { Show-AwsIdentity }
        'ecr-login' { Connect-EcrLogin }
        'jfrog-login' { Connect-JfrogLogin }
        'edit-secrets' { Edit-Secrets }
        'view-secrets' { View-Secrets }
    }

    # Comme launch.sh : le code de sortie est celui de la dernière commande exécutée
    # (docker, aws). Les fonctions qui échouent avant cela sortent elles-mêmes avec "exit".
    exit $LASTEXITCODE
}
finally {
    Restore-Environment $initialEnvironment
    Pop-Location -StackName 'DevLocalLaunch'
}
