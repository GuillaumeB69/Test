<#
.SYNOPSIS
    Extraction pour Lecteur Global - Multi-Tenants Entra ID
.DESCRIPTION
    Script optimisé pour permissions lecture seule (rôle Lecteur Global / Global Reader).
    Extrait ~95% des paramètres nécessaires pour un inventaire comparatif multi-tenants.

    Paramètres extraits automatiquement :
    - Propriétés du tenant (nom, ID, pays, type de licence)
    - Domaines (primaire, custom, initial)
    - Utilisateurs (format UPN, DisplayName, attributs standards)
    - Extension Attributes 1-15 (usage, exemples, pourcentage peuplé)
    - Groupes (total, M365, sécurité, dynamiques)
    - Conditional Access (policies, named locations)
    - Identity Protection (activé/non)
    - Rôles administrateurs (Global Admins)
    - Administrative Units
    - Licences (SKUs, achetées, consommées)
    - Appareils (par type de join, par OS)
    - Applications (Enterprise Apps, App Registrations)
    - Identité hybride (AAD Connect)
    - Utilisateurs invités
    - Secure Score

    Les ~5% restants nécessitent une vérification manuelle dans le portail :
    - Password Policies détaillées / SSPR
    - Configuration Intune avancée
    - Naming policy groupes
    - Détails complets des policies Conditional Access

.PARAMETER Tenants
    Hashtable des tenants à analyser. Chaque entrée doit contenir :
    - TenantId   : l'ID du tenant Azure AD
    - TenantName : le nom d'affichage du tenant

.EXAMPLE
    $tenants = @{
        "Tenant1" = @{ TenantId = "xxxx-xxxx"; TenantName = "Mon Tenant 1" }
        "Tenant2" = @{ TenantId = "yyyy-yyyy"; TenantName = "Mon Tenant 2" }
    }
    $results = .\Extract-TenantInventory-GlobalReader.ps1 -Tenants $tenants

.OUTPUTS
    - TenantComparison_YYYYMMDD_HHMMSS.json : données complètes de tous les tenants
    - Differences_YYYYMMDD_HHMMSS.csv       : uniquement les différences entre tenants

.NOTES
    Version     : 1.0
    Date        : Février 2026
    Permissions : Rôle Lecteur Global (Global Reader) requis sur chaque tenant
    Modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Users,
                  Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
#>
param(
    [Parameter(Mandatory=$true)]
    [hashtable]$Tenants
)

# ========== CONFIGURATION ==========
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   EXTRACTION MULTI-TENANTS - LECTEUR GLOBAL             ║
║   Inventaire Comparatif Entra ID                         ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Vérifier modules
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Groups",
    "Microsoft.Graph.Identity.DirectoryManagement"
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installation de $module..." -ForegroundColor Yellow
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
}

# Importer modules
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Identity.DirectoryManagement

# Structure pour stocker les données
$global:inventoryData = @{}

# ========== FONCTION D'EXTRACTION ==========
function Extract-TenantInventory {
    param(
        [string]$TenantKey,
        [hashtable]$TenantInfo
    )

    $data = @{}

    Write-Host "`n╔═══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  TENANT: $($TenantInfo.TenantName)" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

    # Connexion avec scope Global Reader
    Write-Host "Connexion au tenant..." -ForegroundColor Yellow
    try {
        Connect-MgGraph -TenantId $TenantInfo.TenantId -Scopes "Directory.Read.All" -NoWelcome
        Write-Host "✓ Connecté avec succès" -ForegroundColor Green
    } catch {
        Write-Host "✗ Erreur de connexion: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    # ========== 1. TENANT PROPERTIES ==========
    Write-Host "`n[1/16] Propriétés du tenant..." -ForegroundColor Yellow
    try {
        $org = Get-MgOrganization
        $data["Tenant - Nom"] = $org.DisplayName
        $data["Tenant - ID"] = $org.Id
        $data["Tenant - Pays"] = $org.CountryLetterCode

        # Déterminer le type de tenant basé sur les SKUs
        $skus = Get-MgSubscribedSku
        if ($skus | Where-Object {$_.SkuPartNumber -like "*AAD_PREMIUM_P2*"}) {
            $data["Tenant - Type"] = "Azure AD P2"
        } elseif ($skus | Where-Object {$_.SkuPartNumber -like "*AAD_PREMIUM*"}) {
            $data["Tenant - Type"] = "Azure AD P1"
        } else {
            $data["Tenant - Type"] = "Free/M365"
        }

        Write-Host "  ✓ Tenant: $($org.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Erreur: $($_.Exception.Message)" -ForegroundColor Red
        $data["Tenant - Nom"] = "Erreur d'accès"
    }

    # ========== 2. DOMAINES ==========
    Write-Host "[2/16] Domaines..." -ForegroundColor Yellow
    try {
        $domains = Get-MgDomain
        $primaryDomain = ($domains | Where-Object {$_.IsDefault -eq $true}).Id
        $customDomains = ($domains | Where-Object {$_.IsVerified -and -not $_.Id.EndsWith(".onmicrosoft.com")}).Id -join "; "
        $initialDomain = ($domains | Where-Object {$_.Id.EndsWith(".onmicrosoft.com") -and $_.IsInitial}).Id

        $data["Domaine - Primary"] = $primaryDomain
        $data["Domaine - Custom"] = if ($customDomains) {$customDomains} else {"Aucun"}
        $data["Domaine - Initial"] = $initialDomain

        Write-Host "  ✓ $($domains.Count) domaines trouvés" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Erreur domaines" -ForegroundColor Red
    }

    # ========== 3. USERS - ÉCHANTILLON POUR ANALYSE ==========
    Write-Host "[3/16] Utilisateurs (échantillon 200)..." -ForegroundColor Yellow
    try {
        # Récupérer échantillon avec extensionAttributes
        $users = Get-MgUser -Top 200 -Property "DisplayName,UserPrincipalName,GivenName,Surname,Mail,EmployeeId,Department,JobTitle,CompanyName,City,Country,Manager,OnPremisesExtensionAttributes" -ConsistencyLevel eventual -CountVariable userCount

        $data["Users - Total"] = "~$userCount (échantillon: 200)"

        # ===== CONVENTIONS UPN =====
        $upnSamples = $users | Where-Object {$_.UserPrincipalName} | Select-Object -First 10 -ExpandProperty UserPrincipalName

        # Analyser le pattern
        $prenomNom = 0
        $initNom = 0
        $autre = 0

        foreach ($upn in $upnSamples) {
            if ($upn -match '^([a-z]+)\.([a-z]+)@') {
                $prenomNom++
            } elseif ($upn -match '^([a-z])\.([a-z]+)@') {
                $initNom++
            } else {
                $autre++
            }
        }

        if ($prenomNom -gt 5) {
            $data["UPN - Format"] = "prenom.nom@domain (majoritaire)"
        } elseif ($initNom -gt 5) {
            $data["UPN - Format"] = "p.nom@domain (majoritaire)"
        } else {
            $data["UPN - Format"] = "Format mixte ou autre"
        }

        $data["UPN - Exemples"] = ($upnSamples | Select-Object -First 5) -join "; "

        # ===== DISPLAYNAME =====
        $displaySamples = $users | Where-Object {$_.DisplayName} | Select-Object -First 10 -ExpandProperty DisplayName

        if (($displaySamples[0] -match '^[A-Z]+ [A-Z][a-z]+')) {
            $data["DisplayName - Format"] = "NOM Prénom"
        } elseif (($displaySamples[0] -match '^[A-Z][a-z]+ [A-Z]+')) {
            $data["DisplayName - Format"] = "Prénom NOM"
        } else {
            $data["DisplayName - Format"] = "Format mixte"
        }

        $data["DisplayName - Exemples"] = ($displaySamples | Select-Object -First 5) -join "; "

        Write-Host "  ✓ $($users.Count) users analysés" -ForegroundColor Green

    } catch {
        Write-Host "  ✗ Erreur: $($_.Exception.Message)" -ForegroundColor Red
        $data["Users - Total"] = "Erreur d'accès"
    }

    # ========== 4. USERS - ATTRIBUTS ==========
    Write-Host "[4/16] Attributs utilisateurs..." -ForegroundColor Yellow

    # EMPLOYEEID
    $usersWithEmployeeId = $users | Where-Object {$_.EmployeeId}
    if ($usersWithEmployeeId.Count -gt 0) {
        $employeeIdSamples = $usersWithEmployeeId | Select-Object -First 5 -ExpandProperty EmployeeId
        $employeeIdLengths = $usersWithEmployeeId | ForEach-Object {$_.EmployeeId.Length}
        $minLen = ($employeeIdLengths | Measure-Object -Minimum).Minimum
        $maxLen = ($employeeIdLengths | Measure-Object -Maximum).Maximum

        $data["EmployeeID - Format"] = "Min: $minLen, Max: $maxLen caractères"
        $data["EmployeeID - Exemples"] = $employeeIdSamples -join "; "
        $data["EmployeeID - % Peuplé"] = [math]::Round(($usersWithEmployeeId.Count / $users.Count) * 100, 1).ToString() + "%"
    } else {
        $data["EmployeeID - Format"] = "Non utilisé"
        $data["EmployeeID - Exemples"] = "-"
        $data["EmployeeID - % Peuplé"] = "0%"
    }

    # DEPARTMENT
    $usersWithDept = $users | Where-Object {$_.Department}
    $deptSamples = $usersWithDept | Select-Object -First 5 -ExpandProperty Department
    $data["Department - Exemples"] = if ($deptSamples) {$deptSamples -join "; "} else {"-"}
    $data["Department - % Peuplé"] = [math]::Round(($usersWithDept.Count / $users.Count) * 100, 1).ToString() + "%"

    # JOBTITLE
    $usersWithTitle = $users | Where-Object {$_.JobTitle}
    $titleSamples = $usersWithTitle | Select-Object -First 5 -ExpandProperty JobTitle
    $data["JobTitle - Exemples"] = if ($titleSamples) {$titleSamples -join "; "} else {"-"}
    $data["JobTitle - % Peuplé"] = [math]::Round(($usersWithTitle.Count / $users.Count) * 100, 1).ToString() + "%"

    # COMPANY
    $usersWithCompany = $users | Where-Object {$_.CompanyName}
    $companySamples = $usersWithCompany | Select-Object -Unique -ExpandProperty CompanyName
    $data["Company - Valeurs"] = if ($companySamples) {$companySamples -join "; "} else {"-"}

    # MANAGER
    $usersWithManager = ($users | Where-Object {$_.Manager -ne $null}).Count
    $data["Manager - % Peuplé"] = [math]::Round(($usersWithManager / $users.Count) * 100, 1).ToString() + "%"

    Write-Host "  ✓ Attributs standards extraits" -ForegroundColor Green

    # ========== 5. EXTENSION ATTRIBUTES (CRITIQUE !) ==========
    Write-Host "[5/16] Extension Attributes (1-15)..." -ForegroundColor Yellow

    for ($i = 1; $i -le 15; $i++) {
        $attrName = "extensionAttribute$i"

        # Compter les users avec cet attribut peuplé
        $populated = @($users | Where-Object {
            $_.OnPremisesExtensionAttributes -and
            $_.OnPremisesExtensionAttributes.$attrName -ne $null -and
            $_.OnPremisesExtensionAttributes.$attrName -ne ""
        })

        if ($populated.Count -gt 0) {
            # Extraire des exemples
            $samples = $populated | Select-Object -First 5 | ForEach-Object {
                $_.OnPremisesExtensionAttributes.$attrName
            }

            $percentage = [math]::Round(($populated.Count / $users.Count) * 100, 1)

            $data["ExtAttr$i - Usage"] = "UTILISÉ"
            $data["ExtAttr$i - Exemples"] = $samples -join "; "
            $data["ExtAttr$i - % Peuplé"] = "$percentage%"

            Write-Host "  ✓ extensionAttribute$i : $($populated.Count) users ($percentage%)" -ForegroundColor Green
        } else {
            $data["ExtAttr$i - Usage"] = "Non utilisé"
            $data["ExtAttr$i - Exemples"] = "-"
            $data["ExtAttr$i - % Peuplé"] = "0%"
        }
    }

    # ========== 6. GROUPES ==========
    Write-Host "[6/16] Groupes..." -ForegroundColor Yellow
    try {
        $allGroups = Get-MgGroup -All -Property "DisplayName,GroupTypes,MailEnabled,SecurityEnabled"

        $data["Groupes - Total"] = $allGroups.Count

        $m365Groups = @($allGroups | Where-Object {$_.GroupTypes -contains "Unified"})
        $data["Groupes - M365"] = $m365Groups.Count

        $secGroups = @($allGroups | Where-Object {$_.SecurityEnabled -and -not ($_.GroupTypes -contains "Unified")})
        $data["Groupes - Sécurité"] = $secGroups.Count

        $dynamicGroups = @($allGroups | Where-Object {$_.GroupTypes -contains "DynamicMembership"})
        $data["Groupes - Dynamiques"] = $dynamicGroups.Count

        Write-Host "  ✓ $($allGroups.Count) groupes trouvés (M365: $($m365Groups.Count), Sécurité: $($secGroups.Count))" -ForegroundColor Green

    } catch {
        Write-Host "  ✗ Erreur groupes" -ForegroundColor Red
        $data["Groupes - Total"] = "Erreur d'accès"
    }

    # ========== 7. CONDITIONAL ACCESS ==========
    Write-Host "[7/16] Conditional Access..." -ForegroundColor Yellow
    try {
        $caPolicies = Get-MgIdentityConditionalAccessPolicy

        $data["CA - Total Policies"] = $caPolicies.Count
        $data["CA - Enabled"] = @($caPolicies | Where-Object {$_.State -eq "enabled"}).Count
        $data["CA - Report-Only"] = @($caPolicies | Where-Object {$_.State -eq "enabledForReportingButNotEnforced"}).Count

        # Named Locations
        $namedLocations = Get-MgIdentityConditionalAccessNamedLocation
        $data["CA - Named Locations"] = "$($namedLocations.Count) locations"

        Write-Host "  ✓ $($caPolicies.Count) policies CA ($($data['CA - Enabled']) enabled)" -ForegroundColor Green

    } catch {
        Write-Host "  ⚠️ Conditional Access: Vérifier permissions" -ForegroundColor Yellow
        $data["CA - Total Policies"] = "Vérification manuelle requise"
    }

    # ========== 8. IDENTITY PROTECTION ==========
    Write-Host "[8/16] Identity Protection..." -ForegroundColor Yellow
    try {
        # Test si Identity Protection est activé
        $riskyUsers = Get-MgRiskyUser -Top 1 -ErrorAction SilentlyContinue
        $data["Identity Protection"] = "Activé (P2)"
    } catch {
        $data["Identity Protection"] = "Non activé ou pas de licence P2"
    }

    # ========== 9. ROLES ADMIN ==========
    Write-Host "[9/16] Rôles administrateurs..." -ForegroundColor Yellow
    try {
        $globalAdminRole = Get-MgDirectoryRole -Filter "displayName eq 'Global Administrator'"

        if ($globalAdminRole) {
            $globalAdmins = Get-MgDirectoryRoleMember -DirectoryRoleId $globalAdminRole.Id
            $data["Global Admins - Nombre"] = $globalAdmins.Count

            # Récupérer les UPNs
            $adminUPNs = @()
            foreach ($admin in $globalAdmins) {
                $user = Get-MgUser -UserId $admin.Id -ErrorAction SilentlyContinue
                if ($user) {
                    $adminUPNs += $user.UserPrincipalName
                }
            }
            $data["Global Admins - UPNs"] = $adminUPNs -join "; "
        }

        Write-Host "  ✓ $($globalAdmins.Count) Global Admins" -ForegroundColor Green

    } catch {
        Write-Host "  ⚠️ Rôles: Erreur d'accès" -ForegroundColor Yellow
    }

    # ========== 10. ADMINISTRATIVE UNITS ==========
    Write-Host "[10/16] Administrative Units..." -ForegroundColor Yellow
    try {
        $adminUnits = Get-MgDirectoryAdministrativeUnit
        $data["Admin Units - Nombre"] = $adminUnits.Count
        if ($adminUnits.Count -gt 0) {
            $data["Admin Units - Noms"] = ($adminUnits.DisplayName) -join "; "
        } else {
            $data["Admin Units - Noms"] = "Aucune"
        }
    } catch {
        $data["Admin Units - Nombre"] = "0"
    }

    # ========== 11. LICENCES ==========
    Write-Host "[11/16] Licences..." -ForegroundColor Yellow
    try {
        $skus = Get-MgSubscribedSku

        # SKU principal (le plus consommé)
        $mainSku = $skus | Sort-Object -Property ConsumedUnits -Descending | Select-Object -First 1
        $data["Licences - SKU Principal"] = $mainSku.SkuPartNumber

        # Totaux
        $totalEnabled = ($skus | ForEach-Object {$_.PrepaidUnits.Enabled} | Measure-Object -Sum).Sum
        $totalConsumed = ($skus | Measure-Object -Property ConsumedUnits -Sum).Sum

        $data["Licences - Achetées"] = $totalEnabled
        $data["Licences - Consommées"] = $totalConsumed
        $data["Licences - Disponibles"] = $totalEnabled - $totalConsumed

        Write-Host "  ✓ SKU principal: $($mainSku.SkuPartNumber) ($($mainSku.ConsumedUnits) consommées)" -ForegroundColor Green

    } catch {
        Write-Host "  ⚠️ Licences: Erreur d'accès" -ForegroundColor Yellow
    }

    # ========== 12. DEVICES ==========
    Write-Host "[12/16] Appareils..." -ForegroundColor Yellow
    try {
        $devices = Get-MgDevice -All -Property "DisplayName,DeviceId,OperatingSystem,TrustType"

        $data["Devices - Total"] = $devices.Count

        # Par type de trust
        $aadJoined = @($devices | Where-Object {$_.TrustType -eq "AzureAd"})
        $data["Devices - AAD Joined"] = $aadJoined.Count

        $hybridJoined = @($devices | Where-Object {$_.TrustType -eq "ServerAd"})
        $data["Devices - Hybrid Joined"] = $hybridJoined.Count

        $registered = @($devices | Where-Object {$_.TrustType -eq "Workplace"})
        $data["Devices - Registered"] = $registered.Count

        # Par OS
        $windowsDevices = @($devices | Where-Object {$_.OperatingSystem -like "Windows*"})
        $data["Devices - Windows"] = $windowsDevices.Count

        $macDevices = @($devices | Where-Object {$_.OperatingSystem -like "*Mac*"})
        $data["Devices - macOS"] = $macDevices.Count

        $iosDevices = @($devices | Where-Object {$_.OperatingSystem -like "iOS*"})
        $data["Devices - iOS"] = $iosDevices.Count

        $androidDevices = @($devices | Where-Object {$_.OperatingSystem -like "Android*"})
        $data["Devices - Android"] = $androidDevices.Count

        Write-Host "  ✓ $($devices.Count) devices (Win: $($windowsDevices.Count), AAD Join: $($aadJoined.Count))" -ForegroundColor Green

    } catch {
        Write-Host "  ⚠️ Devices: Erreur d'accès" -ForegroundColor Yellow
        $data["Devices - Total"] = "Erreur d'accès"
    }

    # ========== 13. APPLICATIONS ==========
    Write-Host "[13/16] Applications..." -ForegroundColor Yellow
    try {
        $servicePrincipals = Get-MgServicePrincipal -All -Property "DisplayName,AppId,ServicePrincipalType"
        $data["Apps - Enterprise Apps"] = $servicePrincipals.Count

        $appRegistrations = Get-MgApplication -All -Property "DisplayName,AppId"
        $data["Apps - App Registrations"] = $appRegistrations.Count

        Write-Host "  ✓ $($servicePrincipals.Count) Enterprise Apps, $($appRegistrations.Count) App Registrations" -ForegroundColor Green

    } catch {
        Write-Host "  ⚠️ Applications: Erreur d'accès" -ForegroundColor Yellow
    }

    # ========== 14. HYBRID IDENTITY ==========
    Write-Host "[14/16] Identité hybride..." -ForegroundColor Yellow
    try {
        $dirSyncEnabled = $org.OnPremisesSyncEnabled
        $data["Hybrid - AAD Connect"] = if ($dirSyncEnabled) {"Oui"} else {"Non"}

        if ($dirSyncEnabled) {
            $data["Hybrid - Dernière Sync"] = $org.OnPremisesLastSyncDateTime
        }
    } catch {
        $data["Hybrid - AAD Connect"] = "Erreur d'accès"
    }

    # ========== 15. GUESTS ==========
    Write-Host "[15/16] Utilisateurs invités..." -ForegroundColor Yellow
    try {
        $guests = Get-MgUser -Filter "userType eq 'Guest'" -Top 999 -ConsistencyLevel eventual -CountVariable guestCount
        $data["Guests - Nombre"] = $guestCount

        Write-Host "  ✓ $guestCount guests" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠️ Guests: Erreur" -ForegroundColor Yellow
    }

    # ========== 16. SECURITY ==========
    Write-Host "[16/16] Security..." -ForegroundColor Yellow
    try {
        # Secure Score (nécessite permissions spéciales)
        $secureScore = Get-MgSecuritySecureScore -Top 1 -ErrorAction SilentlyContinue
        if ($secureScore) {
            $data["Secure Score"] = "$($secureScore.CurrentScore) / $($secureScore.MaxScore)"
        } else {
            $data["Secure Score"] = "Non disponible (permissions)"
        }
    } catch {
        $data["Secure Score"] = "Vérification portail requise"
    }

    Write-Host "`n✓ Extraction terminée pour $($TenantInfo.TenantName)" -ForegroundColor Green

    return $data
}

# ========== EXÉCUTION POUR LES TENANTS ==========
foreach ($key in $Tenants.Keys) {
    $tenantData = Extract-TenantInventory -TenantKey $key -TenantInfo $Tenants[$key]

    if ($tenantData) {
        $global:inventoryData[$key] = $tenantData
    }

    # Déconnexion
    Disconnect-MgGraph | Out-Null
}

# ========== GÉNÉRATION RAPPORT ==========
Write-Host "`n╔═══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  ANALYSE DES DIFFÉRENCES" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Comparer les valeurs entre tenants
$differences = @()
$identical = @()

# Obtenir toutes les clés uniques
$allKeys = $global:inventoryData.Values | ForEach-Object {$_.Keys} | Select-Object -Unique

foreach ($key in $allKeys) {
    $values = @()
    foreach ($tenant in $Tenants.Keys) {
        if ($global:inventoryData[$tenant].ContainsKey($key)) {
            $values += $global:inventoryData[$tenant][$key]
        }
    }

    # Vérifier si toutes les valeurs sont identiques
    $uniqueValues = $values | Select-Object -Unique

    if ($uniqueValues.Count -gt 1) {
        $diff = [PSCustomObject]@{
            Paramètre = $key
        }

        foreach ($tenant in $Tenants.Keys) {
            $diff | Add-Member -NotePropertyName $Tenants[$tenant].TenantName -NotePropertyValue $global:inventoryData[$tenant][$key]
        }

        $differences += $diff
    } else {
        $identical += $key
    }
}

# Afficher le résumé
Write-Host "RÉSUMÉ DE LA COMPARAISON" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`nParamètres identiques : $($identical.Count)" -ForegroundColor Green
Write-Host "Paramètres différents : $($differences.Count)" -ForegroundColor $(if($differences.Count -gt 0){"Red"}else{"Green"})

if ($differences.Count -gt 0) {
    Write-Host "`nDIFFÉRENCES DÉTECTÉES :" -ForegroundColor Red
    Write-Host "`nTop 20 différences :`n" -ForegroundColor Yellow

    $differences | Select-Object -First 20 | Format-Table -AutoSize

    if ($differences.Count -gt 20) {
        Write-Host "`n... et $($differences.Count - 20) autres différences`n" -ForegroundColor Yellow
    }
}

# Export JSON
$outputFile = "TenantComparison_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$global:inventoryData | ConvertTo-Json -Depth 10 | Out-File $outputFile
Write-Host "`n✓ Données exportées : $outputFile" -ForegroundColor Green

# Export CSV des différences
if ($differences.Count -gt 0) {
    $diffFile = "Differences_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $differences | Export-Csv -Path $diffFile -NoTypeInformation -Encoding UTF8
    Write-Host "✓ Différences exportées : $diffFile" -ForegroundColor Green
}

Write-Host "`n╔═══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✓ EXTRACTION COMPLÈTE TERMINÉE" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════╝`n" -ForegroundColor Green

# Retourner les données pour usage ultérieur
return $global:inventoryData
