<#
.SYNOPSIS
    Génération de certificats SSL locaux avec mkcert

.DESCRIPTION
    Ce script génère des certificats SSL auto-signés mais approuvés localement
    pour permettre du HTTPS sans warnings dans le navigateur.

.PARAMETER Domain
    Domaine personnalisé (défaut: dev.local)

.PARAMETER Force
    Régénérer même si les certificats existent

.EXAMPLE
    .\generate-certs.ps1

.EXAMPLE
    .\generate-certs.ps1 -Domain "myapp.local"

.EXAMPLE
    .\generate-certs.ps1 -Force

.NOTES
    Prérequis:
    - mkcert installé (le script propose l'installation si absent)
    - Windows: Chocolatey ou Scoop recommandé

    Génère:
    - traefik/certs/cert.pem (certificat)
    - traefik/certs/key.pem (clé privée)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Domain = "dev.local",

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# =============================================================================
# Configuration
# =============================================================================

$CertsDir = "traefik/certs"
$CertFile = "$CertsDir/cert.pem"
$KeyFile = "$CertsDir/key.pem"

# =============================================================================
# Fonctions utilitaires
# =============================================================================

function Write-Header {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "  Dev.Local - Génération de certificats HTTPS" -ForegroundColor Blue
    Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "✗ " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

# =============================================================================
# Vérification de mkcert
# =============================================================================

function Test-MkcertInstalled {
    $mkcert = Get-Command mkcert -ErrorAction SilentlyContinue

    if ($mkcert) {
        $version = & mkcert -version 2>&1 | Select-Object -First 1
        Write-Success "mkcert est installé: $version"
        return $true
    }
    else {
        Write-ErrorMsg "mkcert n'est pas installé"
        Write-Host ""
        Write-Info "mkcert est requis pour générer des certificats locaux approuvés"
        Write-Host ""
        Write-Host "Installation selon votre méthode préférée:"
        Write-Host ""
        Write-Host "  Chocolatey (recommandé):"
        Write-Host "    choco install mkcert"
        Write-Host ""
        Write-Host "  Scoop:"
        Write-Host "    scoop bucket add extras"
        Write-Host "    scoop install mkcert"
        Write-Host ""
        Write-Host "  Winget:"
        Write-Host "    winget install FiloSottile.mkcert"
        Write-Host ""
        Write-Host "  Téléchargement manuel:"
        Write-Host "    https://github.com/FiloSottile/mkcert/releases"
        Write-Host "    Placez mkcert.exe dans un dossier du PATH"
        Write-Host ""
        Write-Host "Plus d'infos: https://github.com/FiloSottile/mkcert"
        Write-Host ""
        return $false
    }
}

# =============================================================================
# Installation de la CA locale
# =============================================================================

function Install-LocalCA {
    Write-Info "Installation de l'autorité de certification locale..."

    try {
        & mkcert -install 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "CA installée avec succès"
            Write-Host ""
            Write-Info "Les certificats générés seront maintenant approuvés par:"
            Write-Host "  • Chrome/Edge/Opera"
            Write-Host "  • Firefox"
            Write-Host "  • curl et autres outils système"
            Write-Host ""
            return $true
        }
        else {
            Write-ErrorMsg "Échec de l'installation de la CA"
            Write-Host ""
            Write-Warning "Vous devrez peut-être exécuter en tant qu'administrateur"
            Write-Host ""
            return $false
        }
    }
    catch {
        Write-ErrorMsg "Erreur lors de l'installation de la CA: $_"
        return $false
    }
}

# =============================================================================
# Génération des certificats
# =============================================================================

function New-Certificates {
    param([string]$DomainName)

    # Créer le répertoire si nécessaire
    if (-not (Test-Path $CertsDir)) {
        Write-Info "Création du répertoire $CertsDir"
        New-Item -ItemType Directory -Path $CertsDir -Force | Out-Null
    }

    # Vérifier si les certificats existent déjà
    if ((Test-Path $CertFile) -and (Test-Path $KeyFile) -and (-not $Force)) {
        Write-Warning "Les certificats existent déjà"
        Write-Host ""
        Write-Host "  Certificat: $CertFile"
        Write-Host "  Clé privée: $KeyFile"
        Write-Host ""
        Write-Info "Utilisez -Force pour régénérer"
        return $true
    }

    Write-Info "Génération des certificats pour:"
    Write-Host "  • localhost"
    Write-Host "  • 127.0.0.1"
    Write-Host "  • ::1"
    Write-Host "  • $DomainName"
    Write-Host "  • *.$DomainName"
    Write-Host ""

    # Générer les certificats
    Push-Location $CertsDir

    try {
        $output = & mkcert -cert-file cert.pem -key-file key.pem `
            localhost 127.0.0.1 ::1 `
            $DomainName "*.$DomainName" 2>&1

        if ($LASTEXITCODE -eq 0) {
            Pop-Location
            Write-Success "Certificats générés avec succès!"
            Write-Host ""
            Write-Host "  Certificat: $CertFile"
            Write-Host "  Clé privée: $KeyFile"
            Write-Host ""

            # Afficher les informations du certificat
            Write-Info "Informations du certificat:"
            try {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertFile)
                Write-Host "  Sujet: $($cert.Subject)"
                Write-Host "  Émetteur: $($cert.Issuer)"
                Write-Host "  Valide du: $($cert.NotBefore) au $($cert.NotAfter)"
            }
            catch {
                # Si openssl est disponible, l'utiliser
                if (Get-Command openssl -ErrorAction SilentlyContinue) {
                    & openssl x509 -in $CertFile -noout -subject -issuer -dates 2>$null
                }
            }
            Write-Host ""

            return $true
        }
        else {
            Pop-Location
            Write-ErrorMsg "Échec de la génération des certificats"
            Write-Host $output
            return $false
        }
    }
    catch {
        Pop-Location
        Write-ErrorMsg "Erreur lors de la génération: $_"
        return $false
    }
}

# =============================================================================
# Configuration du fichier hosts
# =============================================================================

function Test-HostsFileEntry {
    param([string]$DomainName)

    Write-Info "Vérification du fichier hosts..."

    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -ErrorAction SilentlyContinue

    if ($hostsContent -match "127\.0\.0\.1.*$DomainName") {
        Write-Success "Le domaine $DomainName est configuré dans le fichier hosts"
    }
    else {
        Write-Warning "Le domaine $DomainName n'est pas dans le fichier hosts"
        Write-Host ""
        Write-Info "Pour utiliser https://$DomainName, ajoutez cette ligne au fichier hosts:"
        Write-Host ""
        Write-Host "  127.0.0.1    $DomainName"
        Write-Host ""
        Write-Info "Emplacement du fichier: $hostsFile"
        Write-Host ""
        Write-Warning "Vous devez modifier le fichier hosts en tant qu'administrateur"
        Write-Host ""
    }
}

# =============================================================================
# Instructions post-installation
# =============================================================================

function Show-UsageInstructions {
    param([string]$DomainName)

    Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Configuration terminée!" -ForegroundColor Green
    Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Info "Prochaines étapes:"
    Write-Host ""
    Write-Host "  1. Assurez-vous que Traefik est configuré pour HTTPS"
    Write-Host "     (vérifiez traefik/traefik.yml)"
    Write-Host ""
    Write-Host "  2. Régénérez la configuration Docker Compose:"
    Write-Host "     .\manage-profiles.ps1 -Action generate"
    Write-Host ""
    Write-Host "  3. Redémarrez les services:"
    Write-Host "     .\launch.ps1 -c restart"
    Write-Host ""
    Write-Host "  4. Accédez à vos services via HTTPS:"
    Write-Host "     • https://localhost"
    Write-Host "     • https://$DomainName"
    Write-Host "     • https://<service>.$DomainName (selon vos profils)"
    Write-Host ""
    Write-Success "Aucun warning de sécurité n'apparaîtra dans votre navigateur!"
    Write-Host ""
}

# =============================================================================
# Main
# =============================================================================

function Main {
    Write-Header

    # Vérifier mkcert
    if (-not (Test-MkcertInstalled)) {
        exit 1
    }

    Write-Host ""

    # Vérifier si la CA est installée
    try {
        $caRoot = & mkcert -CAROOT 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "CA déjà installée: $caRoot"
            Write-Host ""
        }
        else {
            Write-Warning "L'autorité de certification n'est pas installée"
            Write-Host ""
            if (-not (Install-LocalCA)) {
                exit 1
            }
        }
    }
    catch {
        Write-Warning "L'autorité de certification n'est pas installée"
        Write-Host ""
        if (-not (Install-LocalCA)) {
            exit 1
        }
    }

    # Générer les certificats
    if (-not (New-Certificates -DomainName $Domain)) {
        exit 1
    }

    # Vérifier le fichier hosts
    Test-HostsFileEntry -DomainName $Domain

    Write-Host ""

    # Instructions finales
    Show-UsageInstructions -DomainName $Domain
}

# =============================================================================
# Exécution
# =============================================================================

Main