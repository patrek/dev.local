# Script de validation des profils Dev.Local 2.0
# Valide la syntaxe YAML, les champs requis et les valeurs des profils
#
# validate-profiles.sh est l'implémentation de référence : ce script doit rendre le même
# verdict. Les profils sont lus avec le module powershell-yaml, comme dans
# manage-profiles.ps1 ; yq n'est pas utilisé.

param(
    [switch]$Help
)

$ErrorActionPreference = "Continue"

# Chemin absolu : le script fonctionne depuis n'importe quel répertoire, sans modifier
# le répertoire courant de l'appelant (manage-profiles.ps1 et menu.ps1 l'appellent avec &)
$ProfilesDirName = "profiles"
$ProfilesDir = Join-Path $PSScriptRoot $ProfilesDirName

$Script:Errors = 0
$Script:Warnings = 0
$Script:Validated = 0

# --json : résultat en JSON sur stdout, sans autre texte (comme validate-profiles.sh --json)
$Script:JsonOutput = $false
$Script:JsonErrors = [System.Collections.Generic.List[object]]::new()
$Script:JsonWarnings = [System.Collections.Generic.List[object]]::new()

# Champs lus dans chaque profil (même liste et même ordre que PROFILE_FIELDS dans validate-profiles.sh)
$Script:ProfileFields = @(
    '.name', '.enabled', '.always_active', '.docker_profile', '.expose_ports',
    '.docker-compose.image', '.docker-compose.container_name',
    '.traefik.enabled', '.traefik.prefix', '.traefik.docker_port',
    '.traefik.local_port', '.traefik.priority'
)

# Profils chargés par Read-ProfileFile : chemin -> @{ Values ; Text ; Ports }
# Comparaisons ordinales : les clés et les valeurs sont sensibles à la casse, comme en Bash
$Script:LoadedProfiles = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$Script:DuplicateKeyProfiles = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)

function Show-Usage {
    Write-Host @"
VALIDATION DES PROFILS DEV.LOCAL 2.0

Usage:
    .\validate-profiles.ps1          # Valider tous les profils
    .\validate-profiles.ps1 --json   # Résultat en JSON sur stdout, sans autre texte :
                                     # {"valid", "validated", "errors", "warnings"}
                                     # errors et warnings : liste de {"profile", "message"}
    .\validate-profiles.ps1 -Help    # Afficher cette aide

Description:
    Valide la syntaxe YAML, les champs requis et les valeurs des profils
    dans le répertoire profiles/

Validations effectuées:
    1. Syntaxe YAML valide
    2. Champs requis présents (name, enabled, docker-compose.image)
    3. Valeurs correctes (ports, prefixes Traefik, types)
    4. Validations inter-profils (noms uniques, conflits de ports)

Codes de sortie:
    0 - Tous les profils sont valides (avec ou sans avertissements)
    1 - Erreurs détectées

"@
}

# Fonctions d'affichage colorées
function Write-Error-Message {
    param([string]$ProfileName, [string]$Message)
    Write-Host "❌ ERREUR " -ForegroundColor Red -NoNewline
    Write-Host "[$ProfileName]: $Message"
    $Script:JsonErrors.Add([ordered]@{ profile = $ProfileName; message = $Message })
    $Script:Errors++
}

function Write-Warning-Message {
    param([string]$ProfileName, [string]$Message)
    Write-Host "⚠️  AVERTISSEMENT " -ForegroundColor Yellow -NoNewline
    Write-Host "[$ProfileName]: $Message"
    $Script:JsonWarnings.Add([ordered]@{ profile = $ProfileName; message = $Message })
    $Script:Warnings++
}

function Write-Success-Message {
    param([string]$ProfileName)
    Write-Host "✅" -ForegroundColor Green -NoNewline
    Write-Host " $ProfileName"
}

# Charge powershell-yaml, en l'installant au besoin comme manage-profiles.ps1.
# Retourne $false si le module reste indisponible : la validation ne doit alors pas réussir.
function Import-YamlModule {
    try {
        if (-not (Get-Module -ListAvailable powershell-yaml)) {
            Write-Warning "Le module 'powershell-yaml' est requis. Installation..."
            Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
        }
        Import-Module powershell-yaml -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "❌ Le module PowerShell 'powershell-yaml' est requis pour valider les profils et n'a pas pu être chargé." -ForegroundColor Red
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Installez-le avec : Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
        return $false
    }
}

# Valeur d'une clé d'un dictionnaire YAML, $null si absente (comparaison sensible à la casse)
function Get-MapEntry {
    param($Map, [string]$Key)

    foreach ($candidate in @($Map.Keys)) {
        if ($candidate -is [string] -and $candidate -ceq $Key) {
            # La virgule empêche PowerShell de dérouler une liste à un seul élément
            return , $Map[$candidate]
        }
    }
    return $null
}

function Test-YamlList {
    param($Value)
    return ($Value -is [System.Collections.IList])
}

# Texte d'un scalaire converti par powershell-yaml (booléen, nombre) quand le texte
# d'origine n'a pas pu être relu
function ConvertTo-CanonicalText {
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
}

# Texte d'origine de la valeur d'un champ, tel qu'écrit dans le fichier.
#
# powershell-yaml convertit les scalaires simples : "True" devient $true, "0080" devient 80,
# "~" devient $null. validate-profiles.sh juge le texte ("True" n'est pas "true") : pour ces
# valeurs, le texte est relu sur la ligne "clé: valeur". L'analyse YAML ayant déjà établi
# la structure, seules ces écritures sont cherchées :
#   - clé de premier niveau en colonne 0 ;
#   - clé de second niveau à l'indentation du premier enfant de sa section ;
#   - clé de second niveau d'une section en style flux sur une ligne (traefik: {enabled: true}).
# Retourne $null si la valeur n'est pas trouvée, une chaîne vide si rien ne suit la clé.
function Get-RawFieldText {
    param([string[]]$Lines, [string[]]$Segments, [switch]$AllowNextLine)

    # Clé éventuellement entre guillemets
    $keyNames = @($Segments | ForEach-Object { "[`"']?" + [regex]::Escape($_) + "[`"']?" })

    $keyLine = $null
    $keyIndex = -1
    $keyIndent = 0
    $index = -1
    if ($Segments.Count -eq 1) {
        $pattern = '^' + $keyNames[0] + '\s*:(?:\s+(.*))?$'
        foreach ($line in $Lines) {
            $index++
            if ($line -cmatch $pattern) {
                $keyLine = [string]$Matches[1]
                $keyIndex = $index
                break
            }
        }
    }
    elseif ($Segments.Count -eq 2) {
        $sectionPattern = '^' + $keyNames[0] + '\s*:\s*(?:#.*)?$'
        $flowSectionPattern = '^' + $keyNames[0] + '\s*:\s+\{(.*)\}\s*(?:#.*)?$'
        $flowKeyPattern = '(?:^|,)\s*' + $keyNames[1] + '\s*:\s+([^,]*)'
        $keyPattern = '^ +' + $keyNames[1] + '\s*:(?:\s+(.*))?$'
        $inSection = $false
        $childIndent = -1
        foreach ($line in $Lines) {
            $index++
            if (-not $inSection) {
                if ($line -cmatch $flowSectionPattern) {
                    if ($Matches[1] -cmatch $flowKeyPattern) { $keyLine = [string]$Matches[1] }
                    break
                }
                if ($line -cmatch $sectionPattern) { $inSection = $true }
                continue
            }
            if ($line -match '^\s*(?:#.*)?$') { continue }
            $indent = $line.Length - $line.TrimStart(' ').Length
            if ($indent -eq 0) { break }
            if ($childIndent -lt 0) { $childIndent = $indent }
            if ($indent -eq $childIndent -and $line -cmatch $keyPattern) {
                $keyLine = [string]$Matches[1]
                $keyIndex = $index
                $keyIndent = $indent
                break
            }
        }
    }
    if ($null -eq $keyLine) { return $null }

    # Commentaire de fin de ligne
    $text = $keyLine.Trim()
    if ($text.StartsWith('#')) { $text = '' }
    $text = ($text -replace '\s+#.*$', '').Trim()

    # Valeur écrite sur la ligne suivante, plus indentée que la clé
    if ($text -eq '' -and $AllowNextLine -and $keyIndex -ge 0) {
        for ($i = $keyIndex + 1; $i -lt $Lines.Count; $i++) {
            $next = $Lines[$i]
            if ($next -match '^\s*(?:#.*)?$') { continue }
            if (($next.Length - $next.TrimStart(' ').Length) -gt $keyIndent) {
                $text = ($next -replace '\s+#.*$', '').Trim()
            }
            break
        }
    }

    # Ancre (&a) ou étiquette (!!int) devant la valeur, puis guillemets
    while ($text -match '^[&!]\S*\s+(.*)$') { $text = $Matches[1] }
    if ($text -match '^"(.*)"$' -or $text -match "^'(.*)'`$") { $text = $Matches[1] }
    return $text
}

# Lignes que yq afficherait pour une liste ou un dictionnaire écrit en bloc.
# Sert à compter les lignes : une valeur qui en occupe plusieurs est refusée, comme en Bash.
function Format-YamlBlock {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return @('{}') }
        $lines = @()
        foreach ($key in @($Value.Keys)) {
            $item = $Value[$key]
            $child = @(Format-YamlBlock $item)
            $isFilledCollection = (($item -is [System.Collections.IDictionary]) -or (Test-YamlList $item)) -and $item.Count -gt 0
            if ($isFilledCollection) {
                $lines += "${key}:"
                $lines += @($child | ForEach-Object { "  $_" })
            }
            else {
                $lines += "${key}: $($child[0])"
                if ($child.Count -gt 1) { $lines += @($child[1..($child.Count - 1)]) }
            }
        }
        return $lines
    }
    if (Test-YamlList $Value) {
        if ($Value.Count -eq 0) { return @('[]') }
        $lines = @()
        foreach ($item in $Value) {
            $child = @(Format-YamlBlock $item)
            $lines += "- $($child[0])"
            if ($child.Count -gt 1) { $lines += @($child[1..($child.Count - 1)] | ForEach-Object { "  $_" }) }
        }
        return $lines
    }
    if ($Value -is [string]) { return @($Value.Split("`n")) }
    return @(ConvertTo-CanonicalText $Value)
}

# Lignes que "yq e <chemin>" afficherait pour un champ, ou $null si le chemin traverse
# une valeur qui n'est pas un dictionnaire (yq échoue ou n'affiche rien).
function Get-FieldLine {
    param($Root, [string]$Path, [string[]]$Lines)

    $segments = $Path.TrimStart('.').Split('.')
    $value = $Root
    foreach ($segment in $segments) {
        if ($null -eq $value) { break }
        if ($value -isnot [System.Collections.IDictionary]) { return $null }
        $value = Get-MapEntry -Map $value -Key $segment
    }

    # Une chaîne est déjà le texte que yq affiche (une ligne par ligne de texte)
    if ($value -is [string]) { return , @($value.Split("`n")) }

    $isCollection = ($value -is [System.Collections.IDictionary]) -or (Test-YamlList $value)
    $isConvertedScalar = ($null -ne $value) -and -not $isCollection
    $raw = Get-RawFieldText -Lines $Lines -Segments $segments -AllowNextLine:$isConvertedScalar

    if ($isCollection) {
        # Style flux ([a, b] ou {a: b}) : yq le conserve sur une ligne
        if (-not [string]::IsNullOrEmpty($raw)) { return , @($raw) }
        return , @(Format-YamlBlock $value)
    }
    if ($null -eq $value) {
        # Absent ou vide : "null" ; sinon le texte écrit (~, Null, NULL)
        if ([string]::IsNullOrEmpty($raw)) { return , @('null') }
        return , @($raw)
    }
    # Booléen ou nombre : le texte d'origine fait foi ("True", "0080", "1e3")
    if ([string]::IsNullOrEmpty($raw)) { return , @(ConvertTo-CanonicalText $value) }
    return , @($raw)
}

# Charge les champs d'un profil dans $Script:LoadedProfiles (équivalent de load_profile).
# Échoue si le fichier n'est pas du YAML valide ou n'est pas exploitable.
function Read-ProfileFile {
    param([string]$ProfilePath)

    try {
        $text = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return $false
    }
    if ($null -eq $text) { $text = '' }

    # Un fichier vide ou sans document donne des champs absents, pas une erreur de syntaxe
    $root = @{}
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $documents = @(ConvertFrom-Yaml -Yaml $text -AllDocuments -ErrorAction Stop)
        }
        catch {
            # powershell-yaml refuse une clé écrite deux fois dans une même section
            if ("$($_.Exception.Message)" -match 'Duplicate key') {
                $Script:DuplicateKeyProfiles[$ProfilePath] = $true
            }
            return $false
        }
        # Documents multiples non supportés
        if ($documents.Count -gt 1) { return $false }
        if ($documents.Count -eq 1 -and $null -ne $documents[0]) { $root = $documents[0] }
    }
    if ($root -isnot [System.Collections.IDictionary]) { return $false }

    $lines = @($text -split "`r?`n")
    $output = @()
    foreach ($field in $Script:ProfileFields) {
        $fieldLines = Get-FieldLine -Root $root -Path $field -Lines $lines
        if ($null -eq $fieldLines) { return $false }
        $output += $fieldLines
    }

    # Comme en Bash : une ligne par champ, les lignes vides de fin étant perdues par $(...).
    # Un écart signale une valeur multi-ligne.
    $values = @(($output -join "`n").TrimEnd("`n").Split("`n"))
    if ($values.Count -ne $Script:ProfileFields.Count) { return $false }

    $fieldValues = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Script:ProfileFields.Count; $i++) {
        $fieldValues[$Script:ProfileFields[$i]] = $values[$i]
    }

    # docker-compose.ports : liste (list), autre valeur (other) ou absent / vide (none)
    $ports = @()
    $portsKind = 'none'
    $compose = Get-MapEntry -Map $root -Key 'docker-compose'
    if ($compose -is [System.Collections.IDictionary]) {
        $composePorts = Get-MapEntry -Map $compose -Key 'ports'
        if (Test-YamlList $composePorts) {
            $ports = @($composePorts)
            $portsKind = 'list'
        }
        elseif ($null -ne $composePorts) {
            $portsKind = 'other'
        }
    }

    $Script:LoadedProfiles[$ProfilePath] = @{ Values = $fieldValues; Text = $text; Ports = $ports; PortsKind = $portsKind }
    return $true
}

$Script:PortFormatsHelp = 'Formats acceptés: "8080:80", "127.0.0.1:8080:80", "80", ou la syntaxe longue (target, published). Retirez la section ports si le service ne publie aucun port.'

# Syntaxe courte d'un port (une variable ${...} compte pour un nombre) :
#   [IP:][PORT_HOTE[-FIN]:]PORT_CONTENEUR[-FIN][/tcp|udp|sctp]
function Test-ShortPort {
    param([string]$Text)

    $normalized = $Text -replace '\$\{[^}]*\}', '1'
    return $normalized -cmatch '^((([0-9]{1,3}[.]){3}[0-9]{1,3}|\[[0-9a-fA-F:]+\]):([0-9]+(-[0-9]+)?)?:|[0-9]+(-[0-9]+)?:)?[0-9]+(-[0-9]+)?(/(tcp|udp|sctp))?$'
}

# Éléments de docker-compose.ports qui ne sont pas un port valide, dans l'ordre de
# validate-profiles.sh : syntaxe longue sans target, éléments vides ou imbriqués, puis texte
function Get-InvalidPort {
    param([object[]]$Ports)

    $maps = @()
    $nested = @()
    $scalars = @()
    foreach ($port in $Ports) {
        if ($port -is [System.Collections.IDictionary]) {
            if (-not ($port.Keys -ccontains 'target')) {
                $keys = [string[]]@($port.Keys | ForEach-Object { "$_" })
                [Array]::Sort($keys, [System.StringComparer]::Ordinal)
                $maps += "syntaxe longue sans target ($($keys -join ', '))"
            }
        }
        elseif ($null -eq $port -or (Test-YamlList $port)) {
            $nested += 'élément vide ou imbriqué'
        }
        else {
            $text = ConvertTo-CanonicalText $port
            if (-not (Test-ShortPort $text)) { $scalars += "'$text'" }
        }
    }
    return @($maps + $nested + $scalars)
}

# Ports sous la forme [ip:][hôte:]conteneur, syntaxe longue (published:target) d'abord,
# comme validate-profiles.sh
function Get-PortSpec {
    param([object[]]$Ports)

    $long = @()
    $short = @()
    foreach ($port in $Ports) {
        if ($port -is [System.Collections.IDictionary]) {
            if (($port.Keys -ccontains 'published') -and ($port.Keys -ccontains 'target')) {
                $long += "$(ConvertTo-CanonicalText $port['published']):$(ConvertTo-CanonicalText $port['target'])"
            }
        }
        elseif ($port -is [string] -or $port -is [int] -or $port -is [long]) {
            $short += "$port"
        }
    }
    return @($long + $short)
}

# Port hôte d'un port "[ip:][hôte:]conteneur[/proto]" s'il est numérique, sinon $null
function Get-HostPort {
    param([string]$Spec)

    $withoutProtocol = ($Spec -split '/')[0]
    if ($withoutProtocol.StartsWith('[')) { return $null }
    $parts = $withoutProtocol -split ':'
    $hostPort = switch ($parts.Count) {
        2 { $parts[0] }
        3 { $parts[1] }
        default { '' }
    }
    if ($hostPort -cmatch '^[0-9]+$') { return $hostPort }
    return $null
}

# Retourne un champ chargé par Read-ProfileFile, ou la valeur par défaut s'il est absent
function Get-FieldValue {
    param([string]$ProfilePath, [string]$Path, [string]$Default = "")

    $value = $Script:LoadedProfiles[$ProfilePath].Values[$Path]
    if ([string]::IsNullOrEmpty($value) -or $value -ceq "null") {
        return $Default
    }
    return $value
}

# Vrai si le texte est un numéro de port (1 à 65535).
# Le nombre de chiffres est borné avant la conversion : un grand nombre ferait échouer [int].
function Test-PortNumber {
    param([string]$Value)

    if ($Value -notmatch '^0*([0-9]{1,5})$') { return $false }
    $port = [int]$Matches[1]
    return ($port -ge 1 -and $port -le 65535)
}

# Validation 1: Syntaxe YAML
function Test-YamlSyntax {
    param([string]$ProfilePath)

    if (-not (Read-ProfileFile $ProfilePath)) {
        $basename = [System.IO.Path]::GetFileName($ProfilePath)
        if ($Script:DuplicateKeyProfiles.ContainsKey($ProfilePath)) {
            Write-Error-Message $basename "Clé YAML en double (une clé ne peut apparaître qu'une fois dans une même section)"
            return $false
        }
        Write-Error-Message $basename "Syntaxe YAML invalide (ou valeur multi-ligne / documents multiples non supportés)"
        return $false
    }
    return $true
}

# Validation 2: Champs requis
function Test-RequiredFields {
    param([string]$ProfilePath)

    $basename = [System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)
    $hasErrors = $false

    # Champs obligatoires au niveau racine
    $name = Get-FieldValue $ProfilePath ".name"
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error-Message $basename "Champ 'name' manquant ou vide"
        $hasErrors = $true
    }

    $enabled = Get-FieldValue $ProfilePath ".enabled"
    if ($enabled -cne "true" -and $enabled -cne "false") {
        Write-Error-Message $basename "Champ 'enabled' doit être true ou false (trouvé: '$enabled')"
        $hasErrors = $true
    }

    # Validation docker-compose (présence de la section en début de ligne, comme en Bash)
    $text = $Script:LoadedProfiles[$ProfilePath].Text
    if ($text -cnotmatch "(?m)^docker-compose:") {
        Write-Error-Message $basename "Section 'docker-compose' manquante"
        return $false
    }

    $image = Get-FieldValue $ProfilePath ".docker-compose.image"
    if ([string]::IsNullOrEmpty($image)) {
        Write-Error-Message $basename "Champ 'docker-compose.image' manquant ou vide"
        $hasErrors = $true
    }

    $containerName = Get-FieldValue $ProfilePath ".docker-compose.container_name"
    if ([string]::IsNullOrEmpty($containerName)) {
        Write-Warning-Message $basename "Champ 'docker-compose.container_name' recommandé"
    }

    return -not $hasErrors
}

# Validation 3: Valeurs et types
function Test-Values {
    param([string]$ProfilePath)

    $basename = [System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)
    $hasErrors = $false
    $loaded = $Script:LoadedProfiles[$ProfilePath]

    # Validation always_active vs docker_profile
    $alwaysActive = Get-FieldValue $ProfilePath ".always_active" "false"
    $dockerProfile = Get-FieldValue $ProfilePath ".docker_profile"

    if ($alwaysActive -ceq "true" -and -not [string]::IsNullOrEmpty($dockerProfile)) {
        Write-Warning-Message $basename "always_active=true mais docker_profile='$dockerProfile' (devrait être null)"
    }

    if ($alwaysActive -ceq "false" -and [string]::IsNullOrEmpty($dockerProfile)) {
        Write-Error-Message $basename "always_active=false nécessite un docker_profile valide"
        $hasErrors = $true
    }

    $exposePorts = Get-FieldValue $ProfilePath ".expose_ports" "false"
    if ($exposePorts -cne "true" -and $exposePorts -cne "false") {
        Write-Error-Message $basename "Champ 'expose_ports' doit être true ou false (trouvé: '$exposePorts')"
        $hasErrors = $true
    }

    # Validation des ports : docker-compose.ports est une liste de ports valides
    if ($loaded.PortsKind -eq 'list') {
        $invalidPorts = @(Get-InvalidPort -Ports $loaded.Ports)
        if ($invalidPorts.Count -gt 0) {
            Write-Error-Message $basename "Port invalide dans docker-compose.ports: $($invalidPorts -join ', '). $Script:PortFormatsHelp"
            $hasErrors = $true
        }
    }
    elseif ($loaded.PortsKind -eq 'other') {
        Write-Error-Message $basename "Champ 'docker-compose.ports' doit être une liste. $Script:PortFormatsHelp"
        $hasErrors = $true
    }

    # Validation Traefik si activé
    if ($loaded.Text -cmatch "(?m)^traefik:") {
        $traefikEnabled = Get-FieldValue $ProfilePath ".traefik.enabled" "false"

        if ($traefikEnabled -ceq "true") {
            $prefix = Get-FieldValue $ProfilePath ".traefik.prefix"
            if ([string]::IsNullOrEmpty($prefix)) {
                Write-Error-Message $basename "traefik.prefix requis quand traefik est activé"
                $hasErrors = $true
            }
            elseif ($prefix -notmatch "^/") {
                Write-Error-Message $basename "traefik.prefix doit commencer par '/' (trouvé: '$prefix')"
                $hasErrors = $true
            }

            $dockerPort = Get-FieldValue $ProfilePath ".traefik.docker_port" "80"
            if (-not (Test-PortNumber $dockerPort)) {
                Write-Error-Message $basename "traefik.docker_port doit être entre 1 et 65535 (trouvé: '$dockerPort')"
                $hasErrors = $true
            }

            $localPort = Get-FieldValue $ProfilePath ".traefik.local_port" "80"
            if (-not (Test-PortNumber $localPort)) {
                Write-Error-Message $basename "traefik.local_port doit être entre 1 et 65535 (trouvé: '$localPort')"
                $hasErrors = $true
            }

            $priority = Get-FieldValue $ProfilePath ".traefik.priority" "10"
            if ($priority -notmatch "^[0-9]+$") {
                Write-Warning-Message $basename "traefik.priority doit être un entier (trouvé: '$priority')"
            }
        }
    }

    return -not $hasErrors
}

# Validation 4: Validations inter-profils
function Test-CrossProfile {
    param($ProfileFiles)

    $containerNames = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $hostPorts = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $hasErrors = $false

    foreach ($profileFile in $ProfileFiles) {
        $profilePath = $profileFile.FullName

        # Ignorer les profils non chargés : déjà signalés par la validation individuelle
        if (-not $Script:LoadedProfiles.ContainsKey($profilePath)) { continue }

        $enabled = Get-FieldValue $profilePath ".enabled" "true"
        if ($enabled -cne "true") { continue }

        $basename = $profileFile.BaseName

        # Vérifier l'unicité des noms de containers
        $containerName = Get-FieldValue $profilePath ".docker-compose.container_name"
        if (-not [string]::IsNullOrEmpty($containerName)) {
            if ($containerNames.ContainsKey($containerName)) {
                Write-Error-Message $basename "Nom de container '$containerName' déjà utilisé par $($containerNames[$containerName])"
                $hasErrors = $true
            }
            else {
                $containerNames[$containerName] = $basename
            }
        }

        # Vérifier les conflits de ports (uniquement si format standard port:port)
        # Sans expose_ports, les ports du profil ne sont pas publiés : aucun conflit possible
        $exposePorts = Get-FieldValue $profilePath ".expose_ports" "false"
        if ($exposePorts -cne "true") { continue }

        foreach ($portSpec in @(Get-PortSpec -Ports $Script:LoadedProfiles[$profilePath].Ports)) {
            $hostPort = Get-HostPort -Spec $portSpec
            if ($null -eq $hostPort) { continue }
            if ($hostPorts.ContainsKey($hostPort)) {
                Write-Warning-Message $basename "Port hôte $hostPort déjà utilisé par $($hostPorts[$hostPort])"
            }
            else {
                $hostPorts[$hostPort] = $basename
            }
        }
    }

    return -not $hasErrors
}

# Fonction principale de validation
function Test-Profile {
    param([string]$ProfilePath)

    if (-not (Test-YamlSyntax $ProfilePath)) { return $false }
    if (-not (Test-RequiredFields $ProfilePath)) { return $false }
    if (-not (Test-Values $ProfilePath)) { return $false }

    return $true
}

# Main : retourne le code de sortie
function Main {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     VALIDATION DES PROFILS DEV.LOCAL 2.0            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Import-YamlModule)) {
        return 1
    }
    Write-Host "✓" -ForegroundColor Green -NoNewline
    Write-Host " module powershell-yaml"
    Write-Host ""

    $profileFiles = @()
    if (Test-Path -LiteralPath $ProfilesDir -PathType Container) {
        $profileFiles = @(Get-ChildItem -LiteralPath $ProfilesDir -Filter "*.yml" -File)
    }
    if ($profileFiles.Count -eq 0) {
        Write-Host "Aucun profil trouvé dans $ProfilesDirName" -ForegroundColor Yellow
        return 0
    }

    Write-Host "📋 Validation individuelle des profils:" -ForegroundColor Cyan
    Write-Host ""

    foreach ($profileFile in $profileFiles) {
        if (Test-Profile $profileFile.FullName) {
            Write-Success-Message $profileFile.BaseName
            $Script:Validated++
        }
    }

    Write-Host ""
    Write-Host "🔍 Validations inter-profils:" -ForegroundColor Cyan
    Write-Host ""

    Test-CrossProfile -ProfileFiles $profileFiles | Out-Null

    # Résumé
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    RÉSUMÉ                            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Profils validés    : " -NoNewline
    Write-Host $Script:Validated -ForegroundColor Green
    Write-Host "  Erreurs            : " -NoNewline
    Write-Host $Script:Errors -ForegroundColor Red
    Write-Host "  Avertissements     : " -NoNewline
    Write-Host $Script:Warnings -ForegroundColor Yellow
    Write-Host ""

    if ($Script:Errors -gt 0) {
        Write-Host "❌ La validation a échoué avec $($Script:Errors) erreur(s)" -ForegroundColor Red
        return 1
    }
    if ($Script:Warnings -gt 0) {
        Write-Host "⚠️  La validation a réussi mais avec $($Script:Warnings) avertissement(s)" -ForegroundColor Yellow
        return 0
    }
    Write-Host "✅ Tous les profils sont valides !" -ForegroundColor Green
    return 0
}

# Afficher l'aide si demandé
if ($Help -or $args -ccontains '--help') {
    Show-Usage
    exit 0
}

# Un argument inconnu est une erreur, comme dans validate-profiles.sh
foreach ($argument in $args) {
    if ($argument -ceq '--json') {
        $Script:JsonOutput = $true
    }
    else {
        Write-Host "Argument inconnu: $argument" -ForegroundColor Red
        Show-Usage
        exit 1
    }
}

# Exécuter
if (-not $Script:JsonOutput) {
    $exitCode = Main | Select-Object -Last 1
    exit $exitCode
}

# --json : le texte destiné à l'utilisateur (flux d'information) est supprimé
$exitCode = Main 6>$null | Select-Object -Last 1
if ($exitCode -ne 0 -and $Script:Errors -eq 0) {
    [Console]::Error.WriteLine("Le module PowerShell 'powershell-yaml' est requis pour valider les profils.")
    exit $exitCode
}
ConvertTo-Json -Compress -Depth 3 -InputObject ([ordered]@{
        valid     = ($Script:Errors -eq 0)
        validated = $Script:Validated
        errors    = @($Script:JsonErrors)
        warnings  = @($Script:JsonWarnings)
    })
exit $exitCode
