<#
.SYNOPSIS
    Script principal de gestion des services Dev.Local 2.0

.DESCRIPTION
    Gère le cycle de vie des services Docker avec support SOPS pour les secrets.

.PARAMETER p
    Profils à démarrer (séparés par virgules)

.PARAMETER c
    Commande : start, stop, recreate, ps, run, sso, id, ecr-login, jfrog-login, edit-secrets

.PARAMETER runArgs
    Pour la commande run : la commande à exécuter dans le conteneur, après le nom du service.
    Placer "--" avant les arguments qui commencent par un tiret (inutile avec "just run").

.EXAMPLE
    .\launch.ps1
    Démarre tous les services

.EXAMPLE
    .\launch.ps1 -p api,frontend
    Démarre uniquement les services api et frontend

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
        # Utiliser SecureString pour minimiser l'exposition en mémoire
        $process = Start-Process -FilePath "sops" -ArgumentList "-d", "secrets.env" `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput "temp_secrets.tmp" `
            -RedirectStandardError "temp_errors.tmp"

        if ($process.ExitCode -ne 0) {
            $errorContent = Get-Content "temp_errors.tmp" -Raw -ErrorAction SilentlyContinue
            Remove-Item "temp_secrets.tmp", "temp_errors.tmp" -ErrorAction SilentlyContinue
            Write-Error "Échec du déchiffrement SOPS. Vérifiez votre configuration AWS/Age"
            return
        }

        # Charger les variables ligne par ligne sans stocker tout le contenu
        Get-Content "temp_secrets.tmp" | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.+)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()

                # Valider le nom de variable (sécurité contre injection)
                if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') {
                    [Environment]::SetEnvironmentVariable($key, $value, "Process")
                }
                else {
                    Write-Warning "Variable ignorée (nom invalide): $key"
                }
            }
        }

        # Nettoyer les fichiers temporaires de manière sécurisée
        if (Test-Path "temp_secrets.tmp") {
            # Écraser avec des zéros avant suppression
            $zeros = New-Object byte[] (Get-Item "temp_secrets.tmp").Length
            [System.IO.File]::WriteAllBytes("temp_secrets.tmp", $zeros)
            Remove-Item "temp_secrets.tmp" -Force
        }
        Remove-Item "temp_errors.tmp" -ErrorAction SilentlyContinue

        Write-Host "✅ Secrets chargés de manière sécurisée" -ForegroundColor Green
    }
    catch {
        Write-Error "Erreur lors du déchiffrement : $_"
        Remove-Item "temp_secrets.tmp", "temp_errors.tmp" -ErrorAction SilentlyContinue
    }
}

# Éditer les secrets
function Edit-Secrets {
    if (-not (Validate-Sops)) {
        Write-Error "SOPS requis pour éditer les secrets"
        return
    }
    
    if (-not (Validate-SopsConfig)) {
        return
    }
    
    if (-not (Test-Path "secrets.env")) {
        Write-Host "Création de secrets.env..." -ForegroundColor Yellow
        & .\manage-profiles.ps1 -Action init-secrets
        return
    }
    
    Write-Host "📝 Ouverture de l'éditeur SOPS..." -ForegroundColor Cyan
    & sops secrets.env

    # SOPS retourne 200 si le fichier n'a pas été modifié, ce qui est normal
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 200) {
        # Succès ou pas de modification
        return
    }
    else {
        Write-Error "Erreur SOPS (code: $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}

# Voir les secrets déchiffrés
function View-Secrets {
    if (-not (Validate-Sops)) {
        Write-Error "SOPS requis"
        return
    }

    if (-not (Validate-SopsConfig)) {
        return
    }

    if (-not (Test-Path "secrets.env")) {
        Write-Error "secrets.env non trouvé"
        return
    }

    Write-Host "🔍 Secrets déchiffrés:" -ForegroundColor Cyan
    Write-Warning "⚠️  ATTENTION: Les secrets seront affichés en clair"
    $confirmation = Read-Host "Continuer? (y/N)"

    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "Annulé" -ForegroundColor DarkGray
        return
    }

    # Afficher avec pagination sécurisée
    & sops -d secrets.env | Out-Host -Paging
}

# Générer docker-compose.yml s'il n'existe pas encore
function Ensure-ComposeFile {
    if (-not (Test-Path "docker-compose.yml")) {
        Write-Warning "docker-compose.yml non trouvé. Génération..."
        & .\manage-profiles.ps1 -Action generate
    }
}

# Exécuter une commande ponctuelle dans un service (ex: run gulp npx gulp build)
function Invoke-RunCommand {
    param(
        [string]$service,
        [string[]]$arguments
    )

    if ([string]::IsNullOrWhiteSpace($service)) {
        Write-Error "Service requis. Usage: .\launch.ps1 run <service> [commande...]"
        exit 1
    }

    Ensure-ComposeFile
    Load-Secrets

    # --profile "*" : le service est utilisable même si son profil Docker n'est pas démarré
    docker compose --profile "*" run --rm $service @arguments
    exit $LASTEXITCODE
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
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
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

# Lire une valeur de config.yml (ex: Get-ConfigValue @('aws', 'region') 'ca-central-1')
function Get-ConfigValue {
    param(
        [string[]]$path,
        [string]$default
    )

    $configPath = Join-Path $PSScriptRoot "config.yml"
    if (-not (Test-Path $configPath)) {
        return $default
    }

    $value = Get-Content $configPath -Raw | ConvertFrom-Yaml -ErrorAction SilentlyContinue
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
        return
    }
    
    Write-Host "🔐 Connexion AWS SSO..." -ForegroundColor Cyan
    aws sso login --profile (Get-AwsProfile)
}

# AWS Identity
function Show-AwsIdentity {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI non installé"
        return
    }
    
    Write-Host "🪪 Identité AWS:" -ForegroundColor Cyan
    aws sts get-caller-identity --profile (Get-AwsProfile)
}

# Docker ECR Login
function Connect-EcrLogin {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI non installé"
        return
    }

    $ecrUrl = Get-ConfigValue @('registries', 'ecr', 'url') '<id>.dkr.ecr.ca-central-1.amazonaws.com'
    $region = Get-ConfigValue @('aws', 'region') 'ca-central-1'

    Write-Host "🐳 Connexion Docker à AWS ECR..." -ForegroundColor Cyan

    # Le mot de passe reste en mémoire et passe à docker par l'entrée standard, sans fichier temporaire
    $password = aws ecr get-login-password --profile (Get-AwsProfile) --region $region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($password)) {
        Write-Error "Échec de récupération du mot de passe ECR"
        return 1
    }

    $password | docker login --username AWS --password-stdin $ecrUrl
    return $LASTEXITCODE
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
    default { Write-Error "Commande inconnue: $Command" }
}
