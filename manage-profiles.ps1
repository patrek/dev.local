<#
.SYNOPSIS
    Gestionnaire de profils pour Dev.Local 2.0

.DESCRIPTION
    Script pour ajouter, modifier, supprimer et lister des profils de services.
    Génère automatiquement docker-compose.yml et la configuration Traefik.

.PARAMETER Action
    Action à effectuer : add, list, generate, init-secrets, sync-secrets, list-secrets

.EXAMPLE
    .\manage-profiles.ps1 -Action add
    Ajouter un nouveau profil de service

.EXAMPLE
    .\manage-profiles.ps1 -Action list
    Lister tous les profils

.EXAMPLE
    .\manage-profiles.ps1 -Action generate
    Regénérer docker-compose.yml et traefik/dynamic.yml
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('add', 'list', 'generate', 'init-secrets', 'sync-secrets', 'list-secrets')]
    [string]$Action = 'list'
)

$PSDefaultParameterValues['*:Encoding'] = 'UTF8'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Module powershell-yaml : installé seulement s'il est absent
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Warning "Le module 'powershell-yaml' est requis. Installation..."
    try {
        Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    catch {
        Write-Host "❌ Impossible d'installer le module 'powershell-yaml' : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Vérifiez votre connexion, puis installez-le : Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
}
try {
    Import-Module powershell-yaml -ErrorAction Stop
}
catch {
    Write-Host "❌ Impossible de charger le module 'powershell-yaml' : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
# -Ordered conserve l'ordre des clés du fichier (environment en map)
if (-not (Get-Command ConvertFrom-Yaml).Parameters.ContainsKey('Ordered')) {
    Write-Host "❌ Le module 'powershell-yaml' installé est trop ancien (option -Ordered absente)." -ForegroundColor Red
    Write-Host "   Mettez-le à jour : Update-Module powershell-yaml" -ForegroundColor Yellow
    exit 1
}

# Chemins
$ProfilesDir = "profiles"
$DockerComposeFile = "docker-compose.yml"
$TraefikDynamicFile = "traefik/dynamic.yml"
$SecretsFile = "secrets.env"
$ConfigFile = "config.yml"

# Texte d'une valeur YAML tel que yq l'affiche dans manage-profiles.sh : booléens en
# minuscules, chaîne vide pour une valeur absente ou null.
function ConvertTo-YamlText {
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return [string]$Value
}

# Texte d'un champ YAML, ou $Default s'il est absent, null ou vide : même règle que
# value_or_default dans manage-profiles.sh. Les booléens se testent sur ce texte, comme en
# Bash, et non sur la valeur PowerShell (où "false", yes ou off sont des chaînes non vides,
# donc vraies) :
#   (Get-YamlText $v 'true') -ceq 'true'    équivaut à   [ "$v" = "true" ]
#   (Get-YamlText $v 'true') -cne 'false'   équivaut à   [ "$v" != "false" ]
function Get-YamlText {
    param($Value, [string]$Default = '')

    $text = ConvertTo-YamlText $Value
    if ($text -eq '' -or $text -ceq 'null') { return $Default }
    return $text
}

# Écrit un fichier généré en UTF-8 sans BOM, avec des fins de ligne LF uniquement
# (les here-strings de ce script, enregistré en CRLF, contiennent des CRLF).
function Write-GeneratedFile {
    param([string]$Path, [string]$Content)

    $text = ($Content -replace "`r", '').TrimEnd("`n") + "`n"
    # Chemin absolu : les API .NET ignorent le dossier courant de PowerShell
    $fullPath = Join-Path (Get-Location).Path $Path
    [System.IO.File]::WriteAllText($fullPath, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Charge config.yml ; table vide si le fichier est absent ou illisible
function Read-Config {
    if (-not (Test-Path $ConfigFile)) { return @{} }

    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Yaml -Ordered
        if ($config -is [System.Collections.IDictionary]) { return $config }
    }
    catch {
        Write-Warning "Erreur lors de la lecture de $ConfigFile : $_"
    }
    return @{}
}

# Variables d'environnement partagées d'un service : les groupes auto_inject, puis les
# groupes service_specific du service, chaque groupe une seule fois.
# Rien si les variables partagées sont désactivées ou si le service est exclu.
function Get-SharedEnvironmentVariables {
    param(
        $Config,
        [string]$ServiceName
    )

    $sharedConfig = $Config.shared_env_config

    # Activées par défaut : seul "false" les désactive, comme dans manage-profiles.sh
    if ((Get-YamlText $sharedConfig.enabled 'true') -ceq 'false') {
        return @()
    }

    if ($sharedConfig.exclude_services -ccontains $ServiceName) {
        return @()
    }

    $groups = @()
    if ($sharedConfig.auto_inject) {
        $groups += $sharedConfig.auto_inject
    }
    if ($sharedConfig.service_specific -and $sharedConfig.service_specific.$ServiceName) {
        $groups += $sharedConfig.service_specific.$ServiceName
    }

    $sharedVars = @()
    foreach ($group in ($groups | Select-Object -Unique)) {
        if ($Config.shared_env.$group) {
            $sharedVars += $Config.shared_env.$group
        }
    }

    return $sharedVars
}

# Fonction pour charger un profil YAML
function Read-ProfileYaml {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        Write-Error "Profil non trouvé : $Path"
        return $null
    }
    
    try {
        # -Ordered : les clés gardent l'ordre du fichier, comme dans manage-profiles.sh
        return Get-Content $Path -Raw | ConvertFrom-Yaml -Ordered
    }
    catch {
        Write-Error "Erreur de syntaxe YAML dans $Path : $_"
        return $null
    }
}

# Fonction pour lister les profils
function Show-Profiles {
    Write-Host "`n📋 PROFILS DISPONIBLES" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    $profiles = Get-ChildItem -Path $ProfilesDir -Filter "*.yml" -ErrorAction SilentlyContinue
    
    if ($profiles.Count -eq 0) {
        Write-Host "Aucun profil trouvé dans $ProfilesDir" -ForegroundColor Yellow
        return
    }
    
    foreach ($pro in $profiles) {
        $data = Read-ProfileYaml -Path $pro.FullName
        if (-not $data) { continue }
        
        $name = Get-YamlText $data.name $pro.BaseName
        $enabled = (Get-YamlText $data.enabled 'true') -ceq 'true'
        $description = Get-YamlText $data.description "Sans description"
        
        $status = if ($enabled) { "✅ Activé" } else { "❌ Désactivé" }
        $statusColor = if ($enabled) { "Green" } else { "Red" }
        
        Write-Host "  $name" -ForegroundColor White -NoNewline
        Write-Host " - $status" -ForegroundColor $statusColor
        Write-Host "    📝 $description" -ForegroundColor DarkGray
        Write-Host "    📁 $($pro.Name)" -ForegroundColor DarkGray
        Write-Host ""
    }
}

# Fonction pour ajouter un profil
function Add-Profile {
    Write-Host "`n➕ AJOUTER UN NOUVEAU PROFIL" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    # Collecter les informations
    $name = Read-Host "`nNom du service (ex: api-backend, frontend)"
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Error "Le nom est requis"
        exit 1
    }
    
    # Nettoyer le nom
    $name = $name.ToLower() -replace '[^a-z0-9-]', '-'
    $fileName = Join-Path $ProfilesDir "$name.yml"
    
    if (Test-Path $fileName) {
        Write-Error "Un profil '$name' existe déjà !"
        exit 1
    }
    
    $description = Read-Host "Description du service"
    $image = Read-Host "Image Docker (ex: nginx:latest, registry.io/myapp:v1.0)"
    $dockerPort = Read-Host "Port interne du conteneur (ex: 80, 8000)"
    $localPort = Read-Host "Port exposé localement (via Traefik host) (ex: 8001)"
    if ([string]::IsNullOrWhiteSpace($dockerPort)) { $dockerPort = "80" }
    if ([string]::IsNullOrWhiteSpace($localPort)) { $localPort = $dockerPort }

    # Par défaut le service n'est joignable que via Traefik ; publier un port est optionnel
    $hostBinding = Read-Host "Publier aussi un port sur l'hôte (hôte:conteneur, ex: 9000:${dockerPort}, Entrée pour aucun)"
    $exposePorts = $false
    $portsSection = ""
    if (-not [string]::IsNullOrWhiteSpace($hostBinding) -and $hostBinding -ne 'none') {
        $exposePorts = $true
        $portsSection = "`n  ports:`n    - `"$hostBinding`""
    }
    
    Write-Host "`n🔑 Activation du service" -ForegroundColor Yellow
    $alwaysActive = (Read-Host "Service toujours actif (démarré par défaut) ? (O/n)") -ne 'n'
    $dockerProfile = $null
    if (-not $alwaysActive) {
        $dockerProfile = Read-Host "Nom du profil Docker (pour démarrage conditionnel, ex: $name)"
        if ([string]::IsNullOrWhiteSpace($dockerProfile)) { $dockerProfile = $name }
    }
    
    Write-Host "`n🔧 Configuration Traefik" -ForegroundColor Yellow
    $enableTraefik = (Read-Host "Activer Traefik ? (o/N)") -eq 'o'
    $traefikPrefix = "/"
    $stripPrefix = $false
    
    if ($enableTraefik) {
        $traefikPrefix = Read-Host "Préfixe de route (ex: /api, /app)"
        if ([string]::IsNullOrWhiteSpace($traefikPrefix)) { $traefikPrefix = "/$name" }
        $stripPrefix = (Read-Host "Supprimer le préfixe avant transmission ? (O/n)") -ne 'n'
    }
    
    Write-Host "`n🔐 Variables d'environnement" -ForegroundColor Yellow
    Write-Host "Entrez les variables (format: NOM=valeur), ligne vide pour terminer"
    $envVars = @()
    while ($true) {
        $env = Read-Host "Variable d'environnement"
        if ([string]::IsNullOrWhiteSpace($env)) { break }
        $envVars += "    - $env"
    }
    
    Write-Host "`n🔑 Secrets depuis secrets.env" -ForegroundColor Yellow
    Write-Host "Entrez les secrets (format: SECRET_NAME), ligne vide pour terminer"
    $secrets = @()
    $secretsDoc = @()
    while ($true) {
        $secret = Read-Host "Nom du secret"
        if ([string]::IsNullOrWhiteSpace($secret)) { break }
        $secretVar = $secret.ToUpper() -replace '[^A-Z0-9_]', '_'
        $secretDesc = Read-Host "  Description de $secretVar (optionnel)"
        if ([string]::IsNullOrWhiteSpace($secretDesc)) { $secretDesc = "Secret pour $name" }
        
        $secrets += "    - ${secretVar}=`${${secretVar}:-changeme}"
        $secretsDoc += @"
  - name: $secretVar
    description: "$secretDesc"
    default: changeme
"@
    }
    
    # Générer le fichier YAML
    $allEnv = ($envVars + $secrets) -join "`n"
    if ([string]::IsNullOrWhiteSpace($allEnv)) {
        $allEnv = "    # Aucune variable d'environnement"
    }
    
    $secretsSection = ""
    if ($secretsDoc.Count -gt 0) {
        $secretsSection = @"

# Variables de secrets requises (à définir dans secrets.env)
secrets:
$($secretsDoc -join "`n")

"@
    }
    
    $dockerProfileValue = if ($dockerProfile) { $dockerProfile } else { 'null' }
    
    $profileContent = @"
# Profil généré automatiquement
name: $name
description: "$description"
enabled: true
always_active: $($alwaysActive.ToString().ToLower())
docker_profile: $dockerProfileValue
expose_ports: $($exposePorts.ToString().ToLower())

docker-compose:
  image: $image
  container_name: $name$portsSection
  environment:
$allEnv
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:$dockerPort/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 10s

traefik:
  enabled: $($enableTraefik.ToString().ToLower())
  prefix: $traefikPrefix
  strip_prefix: $($stripPrefix.ToString().ToLower())
  local_port: $localPort
  docker_port: $dockerPort
  priority: 10
$secretsSection
metadata:
  category: custom
  tags:
    - $name
"@
    
    if (-not (Test-Path $ProfilesDir)) {
        New-Item -ItemType Directory -Path $ProfilesDir | Out-Null
    }
    Write-GeneratedFile -Path $fileName -Content $profileContent
    
    Write-Host "`n✅ Profil créé : $fileName" -ForegroundColor Green
    Write-Host "📝 Vous pouvez éditer ce fichier pour personnaliser davantage" -ForegroundColor Gray
    
    # Proposer de regénérer docker-compose.yml
    if ((Read-Host "`nRegénérer docker-compose.yml maintenant ? (O/n)") -ne 'n') {
        Generate-DockerCompose
    }
}

# Lie un port (syntaxe courte) à 127.0.0.1 s'il ne précise pas d'IP hôte.
#   "8090:80" -> "127.0.0.1:8090:80"      "80" -> "127.0.0.1::80"
# Syntaxe longue (target / published) : host_ip: 127.0.0.1 est ajouté s'il est absent.
# Les ports avec IP explicite (ex: "0.0.0.0:8090:80", host_ip: 0.0.0.0) sont conservés.
function ConvertTo-LocalhostPortBinding {
    param($Port)

    if ($Port -is [System.Collections.IDictionary]) {
        if (-not $Port.Contains('host_ip')) { $Port['host_ip'] = '127.0.0.1' }
        return $Port
    }
    if ($Port -isnot [string] -and $Port -isnot [ValueType]) { return $Port }

    $spec = [string]$Port
    # Compter les ':' en ignorant ceux des ${VAR:-defaut}
    $outsideVars = $spec -replace '\$\{[^}]*\}', ''
    $colons = ($outsideVars.ToCharArray() | Where-Object { $_ -eq ':' }).Count

    switch ($colons) {
        0 { return "127.0.0.1::$spec" }
        1 { return "127.0.0.1:$spec" }
        default { return $spec }
    }
}

# Retourne les noms des volumes nommés d'une liste docker-compose.volumes. Un volume nommé
# doit être déclaré dans la section volumes: de premier niveau, sinon docker compose refuse
# le fichier. Mêmes règles que NAMED_VOLUMES_EXPR dans manage-profiles.sh :
#   - syntaxe courte "nom:/chemin[:mode]" : la source est un nom de volume (au moins deux
#     caractères, sinon Compose y voit une lettre de lecteur Windows), pas un chemin
#     (./, /, ~, C:\) ni une variable (${VAR}) ;
#   - syntaxe longue : type: volume avec une source.
# Les montages de dossiers et les volumes anonymes ne sont pas retournés.
function Get-NamedVolumeName {
    param($Volumes)

    if ($Volumes -is [string] -or $Volumes -is [System.Collections.IDictionary]) { return }

    foreach ($volume in $Volumes) {
        if ($volume -is [string]) {
            if ($volume -cmatch '^([a-zA-Z0-9][a-zA-Z0-9_.-]+):') { $matches[1] }
        }
        elseif ($volume -is [System.Collections.IDictionary] -and $volume['type'] -ceq 'volume' -and
            $volume['source'] -is [string] -and $volume['source'] -cmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
            $volume['source']
        }
    }
}

# Fonction pour générer docker-compose.yml
function Generate-DockerCompose {
    Write-Host "`n🔧 GÉNÉRATION DE docker-compose.yml" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    $profiles = Get-ChildItem -Path $ProfilesDir -Filter "*.yml" -ErrorAction SilentlyContinue
    
    if ($profiles.Count -eq 0) {
        Write-Warning "Aucun profil trouvé"
        exit 1
    }

    # Validation des profils avant génération
    if (Test-Path ".\validate-profiles.ps1") {
        Write-Host "`n🔍 Validation des profils..." -ForegroundColor Cyan
        & .\validate-profiles.ps1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n❌ La validation a échoué. Corrigez les erreurs avant de générer." -ForegroundColor Red
            exit 1
        }
        Write-Host ""
    }

    $config = Read-Config
    $namespace = Get-YamlText $config.namespace 'devlocal'
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    $compose = @"
# Généré automatiquement par manage-profiles.ps1
# NE PAS ÉDITER MANUELLEMENT - Vos modifications seront écrasées
# Dernière génération : $timestamp
name: $namespace

services:
  # Proxy du socket Docker : seul conteneur qui monte le socket.
  # Traefik et Dozzle passent par lui et n'ont accès qu'à des requêtes de lecture
  # (conteneurs, événements, infos) ; aucune requête d'écriture n'est acceptée.
  socket-proxy:
    image: tecnativa/docker-socket-proxy:v0.5.0
    container_name: "${namespace}_socket_proxy"
    environment:
      - CONTAINERS=1  # liste, logs et stats des conteneurs (Traefik, Dozzle)
      - INFO=1        # requis par Dozzle pour se connecter
      - POST=0        # refuse toute requête d'écriture
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - socket-proxy

  # Reverse Proxy Traefik
  traefik:
    image: traefik:v3.6.4
    container_name: "${namespace}_traefik"
    ports:
      - "127.0.0.1:8080:80"
      - "127.0.0.1:8081:8080"
    extra_hosts:
      - "external-ip:host-gateway"
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro
    networks:
      - traefik-network
      - socket-proxy
    depends_on:
      - socket-proxy
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3

"@
    
    # Ajouter Dozzle si activé
    if ((Get-YamlText $config.dozzle_enabled 'true') -ceq 'true') {
        $dozzlePort = Get-YamlText $config.dozzle_port '9999'
        $compose += @"
  # Monitoring des logs
  dozzle:
    image: amir20/dozzle:v11.5.0
    container_name: "${namespace}_dozzle"
    ports:
      - "127.0.0.1:${dozzlePort}:8080"
    environment:
      - DOZZLE_TIMEOUT=15s
      - DOZZLE_BASE=/logs
      - DOCKER_HOST=tcp://socket-proxy:2375
    extra_hosts:
      - "external-ip:host-gateway"
    networks:
      - traefik-network
      - socket-proxy
    depends_on:
      - socket-proxy
    healthcheck:
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 3s
      timeout: 30s

"@
    }
    
    # Ajouter chaque service
    # Tri ordinal et sans doublon, comme "LC_ALL=C sort -u" dans manage-profiles.sh
    $namedVolumes = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($pro in $profiles) {
        $data = Read-ProfileYaml -Path $pro.FullName
        if (-not $data) { continue }
        
        if ((Get-YamlText $data.enabled 'true') -cne 'true') {
            Write-Host "  ⏭️  Ignoré (désactivé) : $($pro.BaseName)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  ✅ Ajout : $($pro.BaseName)" -ForegroundColor Green

        $name = Get-YamlText $data.name $pro.BaseName
        # Sans always_active, le service dépend de son profil Docker (défaut : false)
        $alwaysActive = (Get-YamlText $data.always_active 'false') -ceq 'true'
        # Chaîne vide si docker_profile est absent ou null
        $dockerProfile = Get-YamlText $data.docker_profile ''
        $exposePorts = (Get-YamlText $data.expose_ports 'false') -ceq 'true'

        # Charger les variables partagées
        $sharedEnvVars = @(Get-SharedEnvironmentVariables -Config $config -ServiceName $name)
        if ($sharedEnvVars.Count -gt 0) {
            Write-Host "    📌 $($sharedEnvVars.Count) variable(s) partagée(s)" -ForegroundColor DarkGray
        }

        # Traitement de la section docker-compose
        if ($data.'docker-compose') {
            # On clone l'objet pour ne pas modifier l'original (en mémoire)
            # Note: Si powershell-yaml retourne Hashtable/OrderedDictionary, .Clone() est shallow.
            # Mais comme on lit le fichier à chaque itération, c'est acceptable de modifier l'objet retourné.
            $composeData = $data.'docker-compose'

            foreach ($volumeName in (Get-NamedVolumeName -Volumes $composeData.volumes)) {
                [void]$namedVolumes.Add($volumeName)
            }

            # Section ports : publiée sur 127.0.0.1 si expose_ports, retirée sinon (service via Traefik)
            if ($composeData.Contains('ports')) {
                if ($exposePorts) {
                    $composeData.ports = @($composeData.ports | ForEach-Object { ConvertTo-LocalhostPortBinding -Port $_ })
                }
                else {
                    $composeData.Remove('ports')
                    Write-Host "    🔒 Ports non publiés (expose_ports: true pour les publier sur 127.0.0.1)" -ForegroundColor DarkGray
                }
            }
            
            # environment en map (CLE: valeur) : converti en liste CLE=valeur dans l'ordre du
            # fichier, comme manage-profiles.sh, pour pouvoir y ajouter les variables partagées
            if ($composeData.environment -is [System.Collections.IDictionary]) {
                $composeData.environment = @($composeData.environment.GetEnumerator() |
                        ForEach-Object { "$($_.Key)=$(ConvertTo-YamlText $_.Value)" })
            }
            elseif ($composeData.Contains('environment') -and $null -eq $composeData.environment) {
                $composeData.Remove('environment')
            }

            # Préparer l'injection des variables partagées sans polluer les données YAML (pas de faux entries)
            $hadEnvBefore = $false
            if ($composeData.Contains('environment') -and $composeData.environment) {
                $hadEnvBefore = $true
            }
            if ($sharedEnvVars.Count -gt 0 -and -not $composeData.environment) {
                # Crée une clé environment vide pour pouvoir insérer dans le YAML rendu
                $composeData.environment = @()
            }
            
            # Convertir en YAML (sans commentaires) puis injecter les commentaires/vars en texte
            $yaml = $composeData | ConvertTo-Yaml
            $yamlLines = $yaml -split "\r?\n" | Where-Object { $_ -ne '---' -and $_.Trim() -ne '' }

            if ($sharedEnvVars.Count -gt 0) {
                $newYamlLines = New-Object System.Collections.Generic.List[string]
                $inserted = $false
                for ($i = 0; $i -lt $yamlLines.Count; $i++) {
                    $line = $yamlLines[$i]

                    # "environment: []" est la clé vide créée plus haut pour un service sans variables
                    # Clé de la section (non indentée), pas une clé environment imbriquée
                    if (-not $inserted -and $line -match '^environment:\s*(\[\])?\s*$') {
                        $envIndent = ''
                        $newYamlLines.Add("environment:")

                        # Reprendre l'indentation des items existants ; elle peut être vide,
                        # car ConvertTo-Yaml aligne les items de liste sur leur clé
                        $itemIndent = $null
                        if ($i + 1 -lt $yamlLines.Count -and $yamlLines[$i + 1] -match '^(\s*)-\s') {
                            $itemIndent = $matches[1]
                        }
                        if ($null -eq $itemIndent) { $itemIndent = "$envIndent  " }

                        # Insérer le bloc partagé puis un séparateur pour le service (si des vars existent côté service)
                        $newYamlLines.Add("$itemIndent# Variables partagées (depuis config.yml)")
                        foreach ($var in $sharedEnvVars) {
                            $newYamlLines.Add("$itemIndent- $var")
                        }
                        if ($hadEnvBefore) {
                            $newYamlLines.Add("$itemIndent# Variables exclusives du service")
                        }

                        $inserted = $true
                    }
                    else {
                        $newYamlLines.Add($line)
                    }
                }
                $yamlLines = $newYamlLines
            }

            # Indenter de 4 espaces
            $indentedYaml = $yamlLines | ForEach-Object { "    $_" }
            $dockerComposeContent = $indentedYaml -join "`n"
            
            # Section profiles
            $profilesSection = ""
            if (-not $alwaysActive -and $dockerProfile -ne '') {
                $profilesSection = @"

    profiles:
      - $dockerProfile
"@
            }
            
            $compose += @"
  # Service: $name
  ${name}:
$dockerComposeContent
    extra_hosts:
      - "external-ip:host-gateway"
    networks:
      - traefik-network$profilesSection

"@
        }
    }
    
    # Networks
    $compose += @"

networks:
  traefik-network:
    driver: bridge
  # Réseau interne réservé à socket-proxy, Traefik et Dozzle :
  # les services des profils ne peuvent pas joindre l'API Docker
  socket-proxy:
    driver: bridge
    internal: true
"@

    # Volumes nommés utilisés par les profils activés
    if ($namedVolumes.Count -gt 0) {
        $compose += "`n`nvolumes:`n" + (($namedVolumes | ForEach-Object { "  ${_}:" }) -join "`n")
    }

    Write-GeneratedFile -Path $DockerComposeFile -Content $compose
    Write-Host "`n✅ docker-compose.yml généré" -ForegroundColor Green
    
    # Générer aussi la config Traefik dynamique
    Generate-TraefikDynamic
}

# Fonction pour générer traefik/dynamic.yml
function Generate-TraefikDynamic {
    Write-Host "`n🔧 GÉNÉRATION DE traefik/dynamic.yml" -ForegroundColor Cyan
    
    if (-not (Test-Path "traefik")) {
        New-Item -ItemType Directory -Path "traefik" | Out-Null
    }
    
    $routersStr = ""
    $middlewaresStr = ""
    $servicesStr = ""
    
    $profiles = Get-ChildItem -Path $ProfilesDir -Filter "*.yml" -ErrorAction SilentlyContinue
    
    foreach ($pro in $profiles) {
        $data = Read-ProfileYaml -Path $pro.FullName
        if (-not $data) { continue }
        
        $enabled = (Get-YamlText $data.enabled 'true') -ceq 'true'
        $traefikEnabled = (Get-YamlText $data.traefik.enabled 'false') -ceq 'true'
        if (-not ($enabled -and $traefikEnabled)) { continue }

        # Seule une valeur absente ou vide prend la valeur par défaut : 0 est conservé
        $name = Get-YamlText $data.name $pro.BaseName
        $localPort = Get-YamlText $data.traefik.local_port '80'
        $dockerPort = Get-YamlText $data.traefik.docker_port '80'
        $healthPath = Get-YamlText $data.traefik.health_path '/health'
        $prefix = Get-YamlText $data.traefik.prefix "/$name"
        $stripPrefix = (Get-YamlText $data.traefik.strip_prefix 'false') -ceq 'true'
        $priority = Get-YamlText $data.traefik.priority '10'

        # --- Router ---
        $middlewareList = ""
        if ($stripPrefix) {
            $middlewareList = @"
      middlewares:
        - ${name}-strip
"@
            # --- Middleware ---
            $middlewaresStr += @"

    ${name}-strip:
      stripPrefix:
        prefixes:
          - "$prefix"
"@
        }
        
        $routersStr += @"

    ${name}:
      rule: "PathPrefix(``$prefix``)"
      service: ${name}
      priority: $priority
$middlewareList
"@

        # --- Services ---
        $servicesStr += @"

    ${name}:
      failover:
        service: ${name}-host
        fallback: ${name}-docker

    ${name}-host:
      loadBalancer:
        healthCheck:
          path: $healthPath
          interval: 5s
          timeout: 1s
        servers:
          - url: "http://external-ip:${localPort}"
        passHostHeader: true

    ${name}-docker:
      loadBalancer:
        healthCheck:
          path: $healthPath
          interval: 5s
          timeout: 1s
        servers:
          - url: "http://${name}:${dockerPort}"
        passHostHeader: true
"@
    }
    
    $dynamic = @"
# Généré automatiquement par manage-profiles.ps1
# NE PAS ÉDITER MANUELLEMENT - Vos modifications seront écrasées
http:
"@

    $dozzleEnabled = (Get-YamlText (Read-Config).dozzle_enabled 'true') -ceq 'true'

    # Build the dynamic configuration
    if ($routersStr.Trim().Length -gt 0 -or $dozzleEnabled) {
        $dynamic += "`n  routers:$routersStr"
        if ($dozzleEnabled) {
            $dynamic += @"

    dozzle-logs:
      rule: "PathPrefix(``/logs``)"
      service: dozzle
      priority: 10
"@
        }
    }

    # Middlewares section (définitions référencées par les routers avec strip_prefix)
    if ($middlewaresStr.Trim().Length -gt 0) {
        $dynamic += "`n`n  middlewares:$middlewaresStr"
    }

    # Services section
    if ($servicesStr.Trim().Length -gt 0 -or $dozzleEnabled) {
        $dynamic += "`n`n  services:$servicesStr"
        if ($dozzleEnabled) {
            $dynamic += @"

    dozzle:
      loadBalancer:
        healthCheck:
          path: /logs
          interval: 5s
          timeout: 2s
        servers:
          - url: "http://dozzle:8080"
        passHostHeader: true
"@
        }
    }
    
    Write-GeneratedFile -Path $TraefikDynamicFile -Content $dynamic
    Write-Host "✅ traefik/dynamic.yml généré" -ForegroundColor Green
}

# Chiffre un contenu dotenv avec SOPS et retourne le texte chiffré ($null en cas d'échec).
# -TargetFile fait appliquer à SOPS les règles .sops.yaml du fichier final.
# Hors Windows, le contenu passe par l'entrée standard, comme dans manage-profiles.sh : rien
# n'est écrit en clair sur disque. Sous Windows (pas de /dev/stdin), il passe par un fichier
# temporaire privé, hors du dépôt, toujours supprimé.
function Protect-SecretsContent {
    param(
        [string]$Content,
        [string]$TargetFile
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        # PowerShell ajoute un saut de ligne au texte envoyé à une commande : retirer le dernier
        $encrypted = ($Content -replace "`n$", '') |
            & sops -e --filename-override $TargetFile --input-type dotenv --output-type dotenv /dev/stdin
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($encrypted -join "`n")
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempFile, $Content, (New-Object System.Text.UTF8Encoding $false))
        $encrypted = & sops -e --filename-override $TargetFile --input-type dotenv --output-type dotenv $tempFile
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($encrypted -join "`n")
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# Détecte les variables de secrets des profils activés, sans SOPS ni déchiffrement.
# Retourne une table nom -> valeur par défaut.
function Get-SecretVariables {
    $profiles = Get-ChildItem -Path $ProfilesDir -Filter "*.yml" -ErrorAction SilentlyContinue
    # Table sensible à la casse, comme le tableau associatif de manage-profiles.sh
    $secretVars = [hashtable]::new()
    
    foreach ($pro in $profiles) {
        $data = Read-ProfileYaml -Path $pro.FullName
        if (-not $data) { continue }
        
        if ((Get-YamlText $data.enabled 'true') -cne 'true') { continue }

        $profileName = Get-YamlText $data.name $pro.BaseName

        # Méthode 1 : section secrets: (même vide, elle désactive l'auto-détection)
        if ($data.Keys -ccontains 'secrets') {
            foreach ($secret in $data.secrets) {
                $secretName = ConvertTo-YamlText $secret.name
                if ($secretName -eq '') { continue }

                $secretDesc = ConvertTo-YamlText $secret.description
                # Une valeur par défaut présente est conservée telle quelle, même 0, false
                # ou "" ; absente ou null : "changeme" (comme manage-profiles.sh)
                $secretDefault = if ($null -ne $secret.default) { ConvertTo-YamlText $secret.default } else { 'changeme' }

                if (-not $secretVars.ContainsKey($secretName)) {
                    $secretVars[$secretName] = $secretDefault
                    Write-Host "  📌 [$profileName] $secretName ($secretDesc)" -ForegroundColor Gray
                }
            }
        }
        else {
            # Méthode 2 (fallback, profil sans section secrets:) : variables ${VAR:-defaut}
            # des entrées de docker-compose.environment uniquement (liste ou map).
            # L'image, les ports et les commentaires ne sont pas des secrets.
            # Même motif que manage-profiles.sh : sensible à la casse, ":-" obligatoire
            # (un ${VAR} nu n'est pas un secret), toutes les occurrences d'une entrée.
            $environment = $data.'docker-compose'.environment
            $envValues = if ($environment -is [System.Collections.IDictionary]) { $environment.Values } else { $environment }
            foreach ($envValue in $envValues) {
                foreach ($found in [regex]::Matches([string]$envValue, '\$\{([A-Z_][A-Z0-9_]*):-([^}\n]*)\}')) {
                    $varName = $found.Groups[1].Value
                    $defaultValue = if ($found.Groups[2].Value) { $found.Groups[2].Value } else { 'changeme' }

                    if (-not $secretVars.ContainsKey($varName)) {
                        $secretVars[$varName] = $defaultValue
                        Write-Host "  📌 [$profileName] $varName (auto-détecté)" -ForegroundColor DarkGray
                    }
                }
            }
        }
    }

    return $secretVars
}

# Affiche les noms des variables de secrets détectées, triés, un par ligne
function Show-SecretVariables {
    # 6>$null : masque les messages de détection (Write-Host)
    $secretVars = Get-SecretVariables 6>$null
    [string[]]$names = @($secretVars.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $names
}

# Fonction pour synchroniser secrets.env avec les profils
function Sync-Secrets {
    Write-Host "`n🔄 SYNCHRONISATION DES SECRETS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    # Vérifier SOPS
    if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
        Write-Error "SOPS n'est pas installé. Cette fonctionnalité nécessite SOPS."
        Write-Host "`n  💡 Installez SOPS : https://github.com/mozilla/sops/releases" -ForegroundColor Yellow
        exit 1
    }
    
    # Vérifier la configuration SOPS
    if (-not (Test-Path ".sops.yaml")) {
        Write-Error "Fichier .sops.yaml introuvable. Configurez SOPS d'abord."
        exit 1
    }
    
    $sopsConfig = Get-Content ".sops.yaml" -Raw
    if (-not ($sopsConfig -match 'kms:' -or $sopsConfig -match 'age:')) {
        Write-Warning "SOPS n'est pas configuré avec une clé KMS ou Age."
        Write-Host "`n  💡 Éditez .sops.yaml et configurez :" -ForegroundColor Yellow
        Write-Host "     - AWS KMS : kms: 'arn:aws:kms:...'" -ForegroundColor Gray
        Write-Host "     - Age : age: 'age1...'" -ForegroundColor Gray
        Write-Host "`n  Pour générer une clé Age :" -ForegroundColor Yellow
        Write-Host "     age-keygen -o age-key.txt" -ForegroundColor Gray
        exit 1
    }
    
    # Récupérer toutes les variables de secrets des profils
    $secretVars = Get-SecretVariables

    if ($secretVars.Count -eq 0) {
        Write-Host "  ℹ️  Aucune variable de secrets trouvée dans les profils" -ForegroundColor Yellow
        return
    }
    
    Write-Host "`n  Total: $($secretVars.Count) variable(s) trouvée(s)" -ForegroundColor Cyan
    
    # Lire le fichier secrets.env existant (déchiffré)
    # Table sensible à la casse, comme le tableau associatif de manage-profiles.sh
    $existingSecrets = [hashtable]::new()
    $secretsContent = ""

    if (Test-Path $SecretsFile) {
        # Ne pas continuer si le déchiffrement échoue, quelle qu'en soit la forme (code de
        # sortie ou exception) : le fichier existant serait écrasé
        $decryptedLines = $null
        $decryptionSucceeded = $false
        try {
            $decryptedLines = & sops -d $SecretsFile
            $decryptionSucceeded = ($LASTEXITCODE -eq 0)
        }
        catch {
            Write-Warning "Erreur lors du déchiffrement de ${SecretsFile} : $($_.Exception.Message)"
        }
        if (-not $decryptionSucceeded) {
            Write-Error "Impossible de déchiffrer $SecretsFile - aucune modification effectuée. Vérifiez votre clé SOPS, ou supprimez le fichier pour repartir de zéro."
            exit 1
        }

        # Contenu conservé tel quel (lignes vides comprises), sans les sauts de ligne finaux
        $secretsContent = (@($decryptedLines) -join "`n").TrimEnd("`n")
        foreach ($line in $secretsContent -split "`n") {
            if ($line -cmatch '^([A-Z_][A-Z0-9_]*)(=|$)') {
                $existingSecrets[$matches[1]] = $true
            }
        }
        Write-Host "`n  ✅ Fichier secrets.env déchiffré ($($existingSecrets.Count) variables existantes)" -ForegroundColor Green
    }

    # Identifier les nouvelles variables à ajouter
    $newVars = [hashtable]::new()
    foreach ($var in $secretVars.Keys) {
        if (-not $existingSecrets.ContainsKey($var)) {
            $newVars[$var] = $secretVars[$var]
        }
    }
    
    if ($newVars.Count -eq 0) {
        Write-Host "`n  ✅ Toutes les variables sont déjà présentes dans secrets.env" -ForegroundColor Green
        return
    }
    
    Write-Host "`n  📝 Variables manquantes à ajouter:" -ForegroundColor Yellow
    foreach ($var in $newVars.Keys) {
        Write-Host "     - $var" -ForegroundColor Gray
    }
    
    # Demander confirmation
    Write-Host ""
    $confirm = Read-Host "  Ajouter ces variables à secrets.env ? (o/N)"
    if ($confirm -ne 'o') {
        Write-Host "  ⏭️  Annulé" -ForegroundColor Yellow
        return
    }
    
    # Construire le nouveau contenu : l'existant, une ligne vide, puis les nouvelles variables
    $newContent = ""
    if ($secretsContent) {
        $newContent = "$secretsContent`n"
    }
    $newContent += "`n# Variables ajoutées automatiquement le $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
    [string[]]$newNames = @($newVars.Keys)
    [Array]::Sort($newNames, [StringComparer]::Ordinal)
    foreach ($var in $newNames) {
        $newContent += "$var=$($newVars[$var])`n"
    }

    $encrypted = Protect-SecretsContent -Content $newContent -TargetFile $SecretsFile
    if ($null -eq $encrypted) {
        Write-Error "Erreur lors du chiffrement - $SecretsFile n'a pas été modifié"
        exit 1
    }

    Write-GeneratedFile -Path $SecretsFile -Content $encrypted
    Write-Host "`n  ✅ secrets.env mis à jour et rechiffré ($($newVars.Count) variable(s) ajoutée(s))" -ForegroundColor Green
}

# Fonction pour initialiser secrets.env
function Initialize-Secrets {
    Write-Host "`n🔐 INITIALISATION DES SECRETS" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    if (Test-Path $SecretsFile) {
        Write-Warning "Le fichier $SecretsFile existe déjà"
        if ((Read-Host "Écraser ? (o/N)") -ne 'o') {
            return
        }
    }
    
    # Vérifier SOPS
    if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
        Write-Error "SOPS n'est pas installé. Installez-le d'abord."
        exit 1
    }
    
    if (-not (Test-Path ".sops.yaml")) {
        Write-Error "Fichier .sops.yaml introuvable. Configurez SOPS d'abord (voir docs/sops_age_guide.md)."
        exit 1
    }

    # Copier l'exemple
    if (Test-Path "secrets.env.example") {
        Copy-Item "secrets.env.example" $SecretsFile
    }
    else {
        "# Secrets file - Edit with: sops secrets.env`n" | Out-File $SecretsFile -Encoding UTF8
    }

    # Chiffrer immédiatement : un secrets.env en clair ne doit jamais rester sur disque
    & sops --encrypt --in-place $SecretsFile
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $SecretsFile -Force -ErrorAction SilentlyContinue
        Write-Error "Échec du chiffrement SOPS - $SecretsFile supprimé. Vérifiez .sops.yaml."
        exit 1
    }

    Write-Host "`n✅ Fichier $SecretsFile créé et chiffré" -ForegroundColor Green
    Write-Host "📝 Éditez-le maintenant avec: sops $SecretsFile" -ForegroundColor Yellow
    
    if ((Read-Host "`nOuvrir l'éditeur SOPS maintenant ? (O/n)") -ne 'n') {
        & sops $SecretsFile
    }
}

# Main : exécuté depuis le dossier du script, comme manage-profiles.sh. Le dossier courant de
# l'appelant est restauré sur toutes les sorties, y compris exit dans une fonction : menu.ps1
# et launch.ps1 appellent ce script avec & dans leur propre session.
Push-Location -LiteralPath $PSScriptRoot
try {
    switch ($Action) {
        'add' { Add-Profile }
        'list' { Show-Profiles }
        'generate' { Generate-DockerCompose }
        'init-secrets' { Initialize-Secrets }
        'sync-secrets' { Sync-Secrets }
        'list-secrets' { Show-SecretVariables }
        default { Show-Profiles }
    }
}
finally {
    Pop-Location
}
exit 0
