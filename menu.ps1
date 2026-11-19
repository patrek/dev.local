<#
.SYNOPSIS
    Menu interactif pour Dev.Local 2.0

.DESCRIPTION
    Interface simple pour gérer services et profils

.EXAMPLE
    .\menu.ps1
#>

# Le module powershell-yaml n'est installé que s'il est absent
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Write-Warning "Le module 'powershell-yaml' est requis. Installation..."
    try {
        Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    catch {
        Write-Host "❌ Impossible d'installer le module 'powershell-yaml' : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Installez-le manuellement : Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
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

function Wait-AnyKey {
    Write-Host "`n[Appuyez sur n'importe quelle touche pour continuer...]" -ForegroundColor DarkGray
    if ([Console]::IsInputRedirected) {
        # ReadKey échoue quand l'entrée n'est pas une console
        $null = [Console]::In.Read()
        return
    }
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Variable globale pour stocker les derniers profils utilisés
$script:LastProfiles = $null

# Valeur d'un champ YAML sous forme de texte, telle que yq la donne à menu.sh
# ("null" si le champ est absent). Les booléens sont ensuite comparés comme du texte :
# un "false" entre guillemets est une chaîne non vide, donc vraie pour PowerShell.
function ConvertTo-YamlText {
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    return [string]$Value
}

# Lit les champs d'un profil utilisés par le menu, avec les règles de menu.sh :
#   - enabled       : activé sauf si la valeur est "false"
#   - always_active : toujours actif seulement si la valeur est "true" ; absent, le
#                     service est placé derrière son profil Docker Compose par le générateur
# Lève une exception si le fichier n'est pas du YAML valide.
function Read-ProfileEntry {
    param($File)

    $data = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Yaml

    $name = ConvertTo-YamlText $data.name
    if ($name -eq 'null' -or $name -eq '') { $name = $File.BaseName }

    $dockerProfile = ConvertTo-YamlText $data.docker_profile
    if ($dockerProfile -eq 'null' -or $dockerProfile -eq '') { $dockerProfile = $null }

    return @{
        Name          = $name
        DockerProfile = $dockerProfile
        Enabled       = (ConvertTo-YamlText $data.enabled) -cne 'false'
        AlwaysActive  = (ConvertTo-YamlText $data.always_active) -ceq 'true'
    }
}

# Exécute un script du projet dans le processus du menu. La commande affichée est
# construite à partir de ce qui est réellement lancé. Un échec (exit non nul ou
# exception) est signalé sans quitter le menu.
function Invoke-MenuScript {
    param(
        [string]$Name,
        [System.Collections.IDictionary]$Parameters = @{}
    )

    $commandLine = ".\$Name"
    foreach ($key in $Parameters.Keys) {
        $commandLine += " -$key $($Parameters[$key])"
    }
    Write-Host "Commande: " -NoNewline -ForegroundColor DarkGray
    Write-Host $commandLine -ForegroundColor Yellow

    try {
        & (Join-Path '.' $Name) @Parameters
        $succeeded = $?
        $failure = "code de sortie : $LASTEXITCODE"
    }
    catch {
        $succeeded = $false
        $failure = $_.Exception.Message
    }

    if (-not $succeeded) {
        Write-Host "`n⚠️  La commande a échoué ($failure)" -ForegroundColor Red
    }
}

# Ouvre README.md : VS Code si disponible, sinon le Bloc-notes sous Windows,
# ou nano puis less ailleurs (comme menu.sh)
function Open-Readme {
    # $IsWindows n'existe pas dans Windows PowerShell 5.1, qui ne tourne que sous Windows
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

    if (Get-Command code -ErrorAction SilentlyContinue) {
        & code README.md
    }
    elseif ($onWindows) {
        & notepad README.md
    }
    elseif (Get-Command nano -ErrorAction SilentlyContinue) {
        & nano README.md
    }
    elseif (Get-Command less -ErrorAction SilentlyContinue) {
        & less README.md
    }
    else {
        Write-Warning "Aucun programme trouvé pour ouvrir README.md (code, nano, less)"
        Wait-AnyKey
    }
}

function Show-Menu {
    Clear-Host
    Write-Host @"
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
  10. ✏️  Éditer les secrets (sops secrets.env)
  11. 👁️  Voir les secrets déchiffrés
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

"@
}

function Show-Profiles {
    Write-Host @"
╔═══════════════════════════════════════════════════════════════╗
║            📋 PROFILS DISPONIBLES                             ║
╚═══════════════════════════════════════════════════════════════╝

"@
    
    $profiles = Get-ChildItem -Path "profiles" -Filter "*.yml" -ErrorAction SilentlyContinue

    if ($profiles.Count -eq 0) {
        Write-Host "  Aucun profil disponible" -ForegroundColor Yellow
        Write-Host "  Utilisez l'option 6 pour créer un profil`n"
        return
    }

    $profileMap = @{}
    $i = 1

    foreach ($profileFile in $profiles) {
        try {
            $entry = Read-ProfileEntry $profileFile
            $name = $entry.Name
            $dockerProfile = if ($entry.DockerProfile) { $entry.DockerProfile } else { $name }

            if ($entry.Enabled) {
                Write-Host "  [$i] ✅ $name" -ForegroundColor Cyan
                $profileMap[$i] = $dockerProfile
                $i++
            }
            else {
                Write-Host "  [-] ❌ $name (Désactivé)" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "  ⚠️ Erreur lecture $($profileFile.Name)" -ForegroundColor Red
        }
    }

    Write-Host "`nExemples:"
    Write-Host "  1,2         (par numéros)"
    Write-Host "  api,web     (par noms)`n"

    $userInput = Read-Host "Entrez les profils (noms ou numéros, séparés par virgules)"

    $selectedProfiles = @()
    foreach ($part in ("$userInput" -split ",")) {
        $val = $part -replace '\s', ''
        if ($val -eq '') { continue }
        if ($val -match '^\d+$') {
            $idx = [int]$val
            if ($profileMap.ContainsKey($idx)) {
                $selectedProfiles += $profileMap[$idx]
            }
        }
        else {
            $selectedProfiles += $val
        }
    }

    # Sans profil valide, rien n'est lancé : "launch.ps1 -p ''" démarrerait les services de base
    $finalProfiles = $selectedProfiles -join ","
    if (-not $finalProfiles) {
        Write-Host "Aucun profil valide sélectionné - rien n'a été démarré" -ForegroundColor Yellow
        return
    }

    $script:LastProfiles = $finalProfiles
    Write-Host "▶️ Démarrage avec profils: $finalProfiles" -ForegroundColor Cyan
    Invoke-MenuScript 'launch.ps1' ([ordered]@{ p = $finalProfiles })
}

function Main {
    do {
        Show-Menu
        $choice = Read-Host "Choisissez une option (0-17) ou 'q' pour quitter"

        # Fin de l'entrée (pas de console, Ctrl+D) : quitter au lieu de boucler
        if ($null -eq $choice) {
            Write-Host ""
            exit 0
        }

        switch ($choice.Trim()) {
            "1" {
                Write-Host "▶️  Démarrage de tous les services..." -ForegroundColor Cyan

                # Profils Docker Compose des services activés qui ne sont pas toujours actifs
                $activeProfiles = @()
                $profileFiles = Get-ChildItem -Path "profiles" -Filter "*.yml" -ErrorAction SilentlyContinue

                foreach ($file in $profileFiles) {
                    try {
                        $entry = Read-ProfileEntry $file
                    }
                    catch {
                        # Ignorer les erreurs de parsing pour ne pas bloquer
                        Write-Warning "Erreur lecture $($file.Name)"
                        continue
                    }

                    if ($entry.Enabled -and -not $entry.AlwaysActive -and $entry.DockerProfile) {
                        $activeProfiles += $entry.DockerProfile
                    }
                }

                $uniqueProfiles = $activeProfiles | Select-Object -Unique | Sort-Object
                $profileArg = $uniqueProfiles -join ","

                if ($profileArg) {
                    $script:LastProfiles = $profileArg
                    Write-Host "Profils inclus: $profileArg" -ForegroundColor DarkGray
                    Invoke-MenuScript 'launch.ps1' ([ordered]@{ p = $profileArg })
                }
                else {
                    $script:LastProfiles = $null
                    Invoke-MenuScript 'launch.ps1'
                }
                Wait-AnyKey
            }
            "m" {
                Write-Host "▶️  Démarrage des services minimums (sans profils)..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1'
                Wait-AnyKey
            }
            "2" {
                Show-Profiles
                Wait-AnyKey
            }
            "3" {
                Write-Host "🔄 Recréation des services..." -ForegroundColor Yellow

                if ($script:LastProfiles) {
                    Write-Host "Utilisation des derniers profils : $script:LastProfiles" -ForegroundColor DarkGray
                    Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'recreate'; p = $script:LastProfiles })
                }
                else {
                    Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'recreate' })
                }
                Wait-AnyKey
            }
            "4" {
                Write-Host "⏹️  Arrêt de tous les services..." -ForegroundColor Red
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'stop' })
                Wait-AnyKey
            }
            "5" {
                Write-Host "📋 Listing des containers actifs..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'ps' })
                Wait-AnyKey
            }
            "6" {
                Write-Host "➕ Ajout d'un nouveau profil..." -ForegroundColor Cyan
                Invoke-MenuScript 'manage-profiles.ps1' ([ordered]@{ Action = 'add' })
                Wait-AnyKey
            }
            "7" {
                Write-Host "📝 Liste des profils..." -ForegroundColor Cyan
                Invoke-MenuScript 'manage-profiles.ps1' ([ordered]@{ Action = 'list' })
                Wait-AnyKey
            }
            "8" {
                Write-Host "🔧 Regénération de docker-compose.yml..." -ForegroundColor Yellow
                Invoke-MenuScript 'manage-profiles.ps1' ([ordered]@{ Action = 'generate' })
                Wait-AnyKey
            }
            "9" {
                Write-Host "✅ Validation des profils..." -ForegroundColor Cyan
                Invoke-MenuScript 'validate-profiles.ps1'
                Wait-AnyKey
            }
            "10" {
                Write-Host "✏️  Édition des secrets..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'edit-secrets' })
                Wait-AnyKey
            }
            "11" {
                Write-Host "👁️  Affichage des secrets..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'view-secrets' })
                Wait-AnyKey
            }
            "12" {
                Write-Host "🆕 Initialisation de secrets.env..." -ForegroundColor Cyan
                Invoke-MenuScript 'manage-profiles.ps1' ([ordered]@{ Action = 'init-secrets' })
                Wait-AnyKey
            }
            "13" {
                Write-Host "🔄 Synchronisation de secrets.env..." -ForegroundColor Cyan
                Invoke-MenuScript 'manage-profiles.ps1' ([ordered]@{ Action = 'sync-secrets' })
                Wait-AnyKey
            }
            "14" {
                Write-Host "🔐 Connexion AWS SSO..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'sso' })
                Wait-AnyKey
            }
            "15" {
                Write-Host "🪪 Identité AWS actuelle:" -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'id' })
                Wait-AnyKey
            }
            "16" {
                Write-Host "🐳 Connexion Docker à AWS ECR..." -ForegroundColor Cyan
                Invoke-MenuScript 'launch.ps1' ([ordered]@{ c = 'ecr-login' })
                Wait-AnyKey
            }
            "17" {
                Write-Host "📖 Ouverture de README.md..." -ForegroundColor Cyan
                if (Test-Path README.md) {
                    Open-Readme
                }
                else {
                    Write-Warning "README.md non trouvé"
                    Wait-AnyKey
                }
            }
            "0" {
                Write-Host "👋 Au revoir!" -ForegroundColor Green
                exit 0
            }
            "q" {
                Write-Host "👋 Au revoir!" -ForegroundColor Green
                exit 0
            }
            default {
                Write-Host "❌ Option invalide. Veuillez réessayer." -ForegroundColor Red
                Wait-AnyKey
            }
        }
    } while ($true)
}

# Le menu travaille dans le dossier du script, quel que soit le dossier d'où il est lancé.
# Comme il peut être lancé dans une session existante, le dossier, l'encodage de la console
# et les paramètres par défaut de l'appelant sont rétablis à la sortie, y compris sur Ctrl+C.
$callerLocation = Get-Location
$callerOutputEncoding = [Console]::OutputEncoding
$callerHadEncodingDefault = $PSDefaultParameterValues.ContainsKey('*:Encoding')
$callerEncodingDefault = $PSDefaultParameterValues['*:Encoding']

try {
    Set-Location -LiteralPath $PSScriptRoot

    $PSDefaultParameterValues['*:Encoding'] = 'UTF8'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Vérifier que les fichiers nécessaires existent
    foreach ($requiredScript in 'launch.ps1', 'manage-profiles.ps1') {
        if (-not (Test-Path ".\$requiredScript")) {
            Write-Host "❌ $requiredScript non trouvé" -ForegroundColor Red
            exit 1
        }
    }

    # Lancer le menu
    Main
}
finally {
    if ($callerHadEncodingDefault) {
        $PSDefaultParameterValues['*:Encoding'] = $callerEncodingDefault
    }
    else {
        $PSDefaultParameterValues.Remove('*:Encoding')
    }
    [Console]::OutputEncoding = $callerOutputEncoding
    Set-Location -LiteralPath $callerLocation.Path
}
