# 🔐 Guide de Gestion des Secrets avec SOPS et Age

> **Rôle de ce document :** configurer SOPS avec une clé Age. Les commandes de gestion des secrets (initialiser, éditer, synchroniser) et la variante AWS KMS sont décrites dans le [README](../README.md#-gestion-des-secrets-avec-sops).

Ce guide explique comment configurer et utiliser SOPS avec Age pour chiffrer les secrets dans ce projet.

## 1. Prérequis

Assurez-vous que `sops` et `age` sont installés sur votre machine : aucun script du projet ne les installe. Pour SOPS, voir [Installation de SOPS](../README.md#installation-de-sops) ; pour Age, voir https://github.com/FiloSottile/age.

## 2. Configuration de la Clé Age

Une clé Age est une paire de clés (privée/publique) utilisée pour chiffrer et déchiffrer les secrets.

### Générer une nouvelle clé

Si vous n'avez pas encore de clé, générez-en une :

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Cela créera un fichier `keys.txt` contenant votre clé privée. **Ne partagez jamais ce fichier.**

### Obtenir votre clé publique

Pour voir votre clé publique (nécessaire pour la configuration) :

```bash
grep "public key" ~/.config/sops/age/keys.txt
```

Exemple de sortie :
`# public key: age1l6gmgtjxjx9jx09j3umljfkren9dy8nmuet5tnqatxfddjkj89js2gn27m`

### Utiliser un autre emplacement

`~/.config/sops/age/keys.txt` est l'emplacement où SOPS cherche la clé par défaut sous Linux. Si la clé est ailleurs (par exemple `age-key.txt` à la racine du projet, ignoré par Git), indiquez son chemin avec la variable `SOPS_AGE_KEY_FILE` :

```bash
export SOPS_AGE_KEY_FILE="$PWD/age-key.txt"
```

```powershell
$env:SOPS_AGE_KEY_FILE = "$(Get-Location)\age-key.txt"
```

Pour rendre la variable persistante sous Windows, ajoutez-la à votre profil PowerShell (`$PROFILE`) :

```powershell
$env:SOPS_AGE_KEY_FILE = "C:\Src\Dev.Local.2.0\age-key.txt"
```

## 3. Configuration du Projet (.sops.yaml)

`.sops.yaml` n'est pas fourni dans le dépôt : créez-le à partir du modèle (`cp .sops.example.yaml .sops.yaml`). Pour que SOPS sache quelle clé utiliser pour chiffrer les fichiers, ouvrez ensuite ce fichier et ajoutez votre clé publique dans la section `age` (ligne à décommenter).

```yaml
creation_rules:
  - path_regex: secrets\.env$
    age: 'age1l6gmgtjxjx9jx09j3umljfkren9dy8nmuet5tnqatxfddjkj89js2gn27m' # Remplacez par VOTRE clé publique
    encrypted_regex: '^.*$' # Chiffre tout sauf les commentaires
```

## 4. Utilisation

Pour modifier ou ajouter des secrets, n'éditez **jamais** `secrets.env` directement avec un éditeur de texte standard : passez par SOPS, qui ouvre le fichier déchiffré dans votre éditeur par défaut et le rechiffre à la fermeture.

| Action | Bash | PowerShell |
|--------|------|------------|
| Créer `secrets.env` s'il n'existe pas (chiffré immédiatement, exige `.sops.yaml`) | `./manage-profiles.sh init-secrets` | `.\manage-profiles.ps1 -Action init-secrets` |
| Éditer les secrets | `./launch.sh edit-secrets` | `.\launch.ps1 -c edit-secrets` |
| Afficher les secrets déchiffrés dans le terminal | `./launch.sh view-secrets` | `.\launch.ps1 -c view-secrets` |

Le comportement détaillé de ces commandes est décrit dans le [README](../README.md#-gestion-des-secrets-avec-sops).

## 5. Dépannage

- **Erreur ".sops.yaml non trouvé" ou "Fichier .sops.yaml introuvable"** : Créez le fichier à partir de `.sops.example.yaml` (voir section 3).
- **Erreur "Aucune méthode de chiffrement configurée"** : Vérifiez que `.sops.yaml` contient bien une ligne `age:` ou `kms:` valide et non commentée.
- **Erreur de déchiffrement** : Assurez-vous que votre clé privée est bien dans `~/.config/sops/age/keys.txt` (ou à l'emplacement indiqué par `SOPS_AGE_KEY_FILE`) et qu'elle correspond à la clé publique dans `.sops.yaml` qui a été utilisée pour chiffrer le fichier.

Autres problèmes (SOPS non installé, secrets non chargés) : voir [Dépannage](../README.md#-dépannage) dans le README.
