#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $false)]
    [string]$CompanyName = ""
)

Add-Type -AssemblyName System.Web

# ===================== CONFIGURATION =====================
$HuduBaseUrl         = "https://YOURHUDUDOMAIN/api/v1"
$HuduApiKey          = "YOUR_API_KEY_HERE"
$ComputerLayoutName  = "Configurations"
$BitLockerLayoutName = "Bitlocker"
# =========================================================

$HuduBaseUrl = $HuduBaseUrl.TrimEnd("/")

try { $null = [System.Uri]::new($HuduBaseUrl) }
catch { Write-Error "HuduBaseUrl is invalid: '$HuduBaseUrl'"; exit 1 }

$Headers = @{
    "x-api-key"    = $HuduApiKey
    "Content-Type" = "application/json"
}

$EncMethodMap = @{
    "0" = "None"
    "1" = "AES128WithDiffuser"
    "2" = "AES256WithDiffuser"
    "3" = "Aes128"
    "4" = "Aes256"
    "6" = "XtsAes128"
    "7" = "XtsAes256"
}

$VolStatusMap = @{
    "0" = "FullyDecrypted"
    "1" = "FullyEncrypted"
    "2" = "EncryptionInProgress"
    "3" = "DecryptionInProgress"
    "4" = "EncryptionPaused"
    "5" = "DecryptionPaused"
}

function Invoke-HuduGet {
    param([string]$Endpoint, [hashtable]$Query = @{})
    try {
        $builder = [System.UriBuilder]::new($HuduBaseUrl + $Endpoint)
        if ($Query.Count -gt 0) {
            $qs = [System.Web.HttpUtility]::ParseQueryString("")
            foreach ($key in $Query.Keys) { $qs[$key] = $Query[$key] }
            $builder.Query = $qs.ToString()
        }
        return Invoke-RestMethod -Uri $builder.Uri -Headers $Headers -Method Get
    }
    catch { Write-Warning "GET $Endpoint failed: $_"; return $null }
}

function Invoke-HuduPost {
    param([string]$Endpoint, [hashtable]$Body)
    try {
        return Invoke-RestMethod -Uri ($HuduBaseUrl + $Endpoint) -Headers $Headers `
            -Method Post -Body ($Body | ConvertTo-Json -Depth 10)
    }
    catch { Write-Warning "POST $Endpoint failed: $_"; return $null }
}

function Invoke-HuduPut {
    param([string]$Endpoint, [hashtable]$Body)
    try {
        return Invoke-RestMethod -Uri ($HuduBaseUrl + $Endpoint) -Headers $Headers `
            -Method Put -Body ($Body | ConvertTo-Json -Depth 10)
    }
    catch { Write-Warning "PUT $Endpoint failed: $_"; return $null }
}

function Get-AllHuduPages {
    param([string]$Endpoint, [string]$ResultKey, [hashtable]$Query = @{})
    $all  = @()
    $page = 1
    do {
        $Query["page"] = $page.ToString()
        $response      = Invoke-HuduGet -Endpoint $Endpoint -Query $Query
        if ($null -eq $response) { break }
        $results = $response.$ResultKey
        if ($null -eq $results -or $results.Count -eq 0) { break }
        $all  += $results
        $page++
    } while ($results.Count -eq 25)
    return $all
}

# ===================== GATHER SYSTEM INFO =====================
Write-Host "`nGathering computer information..." -ForegroundColor Cyan

$CS           = Get-WmiObject Win32_ComputerSystem
$OS           = Get-WmiObject Win32_OperatingSystem
$BIOS         = Get-WmiObject Win32_BIOS
$ComputerName = $env:COMPUTERNAME
$DomainName   = $CS.Domain
$OSCaption    = $OS.Caption
$OSVersion    = $OS.Version
$SerialNumber = $BIOS.SerialNumber
$Manufacturer = $CS.Manufacturer
$Model        = $CS.Model
$LastUser     = $CS.UserName

Write-Host "  Hostname:      $ComputerName"
Write-Host "  Domain:        $DomainName"
Write-Host "  OS:            $OSCaption ($OSVersion)"
Write-Host "  Serial Number: $SerialNumber"
Write-Host "  Make/Model:    $Manufacturer $Model"
Write-Host "  Last User:     $LastUser"

# ===================== GATHER BITLOCKER INFO =====================
Write-Host "`nGathering BitLocker information..." -ForegroundColor Cyan

$BitLockerVolumes = @()

try {
    $blvs = Get-BitLockerVolume -ErrorAction Stop
    foreach ($blv in $blvs) {
        $isEncrypted = $blv.ProtectionStatus -eq "On" -or $blv.VolumeStatus -like "*Encrypted*"
        if ($isEncrypted) {
            $keyProtector = $blv.KeyProtector |
                Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
                Select-Object -First 1

            $rawEncMethod = $blv.EncryptionMethod.ToString()
            $rawVolStatus = $blv.VolumeStatus.ToString()
            $encMethod    = if ($EncMethodMap.ContainsKey($rawEncMethod)) { $EncMethodMap[$rawEncMethod] } else { $rawEncMethod }
            $volStatus    = if ($VolStatusMap.ContainsKey($rawVolStatus)) { $VolStatusMap[$rawVolStatus] } else { $rawVolStatus }

            $autoUnlock = $false
            try { $autoUnlock = [bool]$blv.AutoUnlockEnabled } catch {}

            $BitLockerVolumes += [PSCustomObject]@{
                MountPoint       = $blv.MountPoint
                VolumeStatus     = $volStatus
                EncryptionMethod = $encMethod
                ProtectionStatus = $blv.ProtectionStatus
                AutoUnlock       = $autoUnlock
                RecoveryKeyID    = if ($keyProtector) { $keyProtector.KeyProtectorId } else { "N/A" }
                RecoveryPassword = if ($keyProtector) { $keyProtector.RecoveryPassword } else { "N/A" }
            }
        }
    }
} catch {
    Write-Warning "  Get-BitLockerVolume unavailable, falling back to manage-bde..."
    $drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\" }).Root
    foreach ($drive in $drives) {
        $status = manage-bde -status $drive 2>$null
        if ($status -match "Protection Status:\s+Protection On") {
            $protectors = manage-bde -protectors -get $drive 2>$null
            $recoveryPw = ($protectors |
                Select-String -Pattern "^\s{6}[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}" |
                Select-Object -First 1).ToString().Trim()
            $BitLockerVolumes += [PSCustomObject]@{
                MountPoint       = $drive
                VolumeStatus     = "FullyEncrypted"
                EncryptionMethod = "Unknown"
                ProtectionStatus = "On"
                AutoUnlock       = $false
                RecoveryKeyID    = "See description"
                RecoveryPassword = if ($recoveryPw) { $recoveryPw } else { "N/A" }
            }
        }
    }
}

if ($BitLockerVolumes.Count -eq 0) {
    Write-Host "  No BitLocker-encrypted volumes found. Exiting." -ForegroundColor Yellow
    exit
}

foreach ($vol in $BitLockerVolumes) {
    Write-Host "  Drive $($vol.MountPoint) | $($vol.VolumeStatus) | $($vol.EncryptionMethod) | AutoUnlock: $($vol.AutoUnlock) | Key: $($vol.RecoveryPassword)"
}

# ===================== FIND HUDU COMPANY =====================
Write-Host "`nSearching for matching Hudu company..." -ForegroundColor Cyan

$Company = $null

if (-not [string]::IsNullOrWhiteSpace($CompanyName)) {
    $companies = Get-AllHuduPages -Endpoint "/companies" -ResultKey "companies" `
        -Query @{ search = $CompanyName }
    $Company = $companies | Where-Object { $_.name -eq $CompanyName } | Select-Object -First 1

    if ($null -eq $Company -and $companies.Count -gt 0) {
        Write-Host "  Exact match not found, using closest result: $($companies[0].name)" -ForegroundColor Yellow
        $Company = $companies[0]
    }
}

if ($null -eq $Company) {
    Write-Error "Could not find company '$CompanyName' in Hudu. Re-run with: .\Invoke-BitLockerToHudu.ps1 -CompanyName 'Exact Company Name'"
    exit 1
}

Write-Host "  Using company: $($Company.name) (ID: $($Company.id))" -ForegroundColor Green

# ===================== FIND ASSET LAYOUTS =====================
Write-Host "`nLooking up asset layouts..." -ForegroundColor Cyan

$allLayouts      = Get-AllHuduPages -Endpoint "/asset_layouts" -ResultKey "asset_layouts"
$ComputerLayout  = $allLayouts | Where-Object { $_.name -eq $ComputerLayoutName }  | Select-Object -First 1
$BitLockerLayout = $allLayouts | Where-Object { $_.name -eq $BitLockerLayoutName } | Select-Object -First 1

if ($null -eq $ComputerLayout) {
    Write-Error "'$ComputerLayoutName' layout not found. Available layouts:"
    $allLayouts | ForEach-Object { Write-Host "  - $($_.name)" }
    exit 1
}
if ($null -eq $BitLockerLayout) {
    Write-Error "'$BitLockerLayoutName' layout not found. Available layouts:"
    $allLayouts | ForEach-Object { Write-Host "  - $($_.name)" }
    exit 1
}

Write-Host "  Computer layout : $($ComputerLayout.name) (ID: $($ComputerLayout.id))" -ForegroundColor Green
Write-Host "  BitLocker layout: $($BitLockerLayout.name) (ID: $($BitLockerLayout.id))" -ForegroundColor Green

Write-Host "`n  Configurations layout fields:" -ForegroundColor DarkGray
$ComputerLayout.fields | ForEach-Object { Write-Host "    - '$($_.label)' (type: $($_.field_type))" }

Write-Host "`n  BitLocker layout fields:" -ForegroundColor DarkGray
$BitLockerLayout.fields | ForEach-Object { Write-Host "    - '$($_.label)' (type: $($_.field_type))" }

# ===================== FIND OR CREATE COMPUTER ASSET =====================
Write-Host "`nSearching for existing computer asset '$ComputerName'..." -ForegroundColor Cyan

$existingAssets = Get-AllHuduPages -Endpoint "/companies/$($Company.id)/assets" `
    -ResultKey "assets" -Query @{ name = $ComputerName }
$ExistingAsset  = $existingAssets |
    Where-Object { $_.name -eq $ComputerName -and $_.asset_layout_id -eq $ComputerLayout.id } |
    Select-Object -First 1

# All possible computer fields.
# Labels are filtered dynamically against your Configurations layout.
# To populate a field, the label here must exactly match the field name in Hudu.
# Add a "Serial Number" text field to your Configurations layout in Hudu Admin
# and it will automatically populate on the next run.
$allComputerFields = @(
    @{ "Hostname"            = $ComputerName },
    @{ "Serial Number"       = $SerialNumber },
    @{ "Manufacturer"        = $Manufacturer },
    @{ "Model"               = $Model },
    @{ "Operating System"    = "$OSCaption ($OSVersion)" },
    @{ "Domain"              = $DomainName },
    @{ "Last Logged In User" = $LastUser }
)

$validComputerLabels  = $ComputerLayout.fields | Select-Object -ExpandProperty label
$computerCustomFields = $allComputerFields | Where-Object {
    $validComputerLabels -contains ($_.Keys | Select-Object -First 1)
}

Write-Host "`n  Computer fields being sent:" -ForegroundColor DarkGray
$computerCustomFields | ForEach-Object { Write-Host "    - $($_.Keys | Select-Object -First 1)" }

if ($computerCustomFields.Count -eq 0) {
    Write-Warning "  No matching fields found between script and Configurations layout. Asset name will still be created/updated."
}

$assetBody = @{
    asset = @{
        name            = $ComputerName
        asset_layout_id = $ComputerLayout.id
        custom_fields   = $computerCustomFields
    }
}

if ($null -eq $ExistingAsset) {
    Write-Host "`n  No existing asset found. Creating..."
    $assetResponse = Invoke-HuduPost -Endpoint "/companies/$($Company.id)/assets" -Body $assetBody
    $Asset = $assetResponse.asset
    Write-Host "  Asset created. ID: $($Asset.id)" -ForegroundColor Green
} else {
    Write-Host "`n  Found existing asset (ID: $($ExistingAsset.id)). Updating..."
    $assetResponse = Invoke-HuduPut -Endpoint "/companies/$($Company.id)/assets/$($ExistingAsset.id)" -Body $assetBody
    $Asset = if ($assetResponse.asset) { $assetResponse.asset } else { $ExistingAsset }
    Write-Host "  Asset updated. ID: $($Asset.id)" -ForegroundColor Green
}

# ===================== UPLOAD BITLOCKER KEYS AS ASSETS =====================
Write-Host "`nUploading BitLocker data into '$BitLockerLayoutName' layout..." -ForegroundColor Cyan

foreach ($vol in $BitLockerVolumes) {
    if ($vol.RecoveryPassword -eq "N/A") {
        Write-Warning "  No recovery password for $($vol.MountPoint). Skipping."
        continue
    }

    # Serial number is included in the asset name so it is always visible
    # regardless of what fields exist in the BitLocker layout
    $blAssetName = "BitLocker - $ComputerName (S/N: $SerialNumber) ($($vol.MountPoint))"

    $blCustomFields = @(
        @{ "Drive"              = $vol.MountPoint },
        @{ "Encryption Method"  = $vol.EncryptionMethod },
        @{ "Recovery Key"       = $vol.RecoveryPassword },
        @{ "Volume Status"      = $vol.VolumeStatus },
        @{ "Autounlock-Enabled" = $vol.AutoUnlock },
        @{ "Operating System"   = "$OSCaption ($OSVersion)" },
        @{ "Last Updated"       = (Get-Date -Format "yyyy-MM-dd HH:mm") }
    )

    $blAssetBody = @{
        asset = @{
            name            = $blAssetName
            asset_layout_id = $BitLockerLayout.id
            custom_fields   = $blCustomFields
        }
    }

    $existingBlAssets = Get-AllHuduPages -Endpoint "/companies/$($Company.id)/assets" `
        -ResultKey "assets" -Query @{ name = $blAssetName }
    $existingBlAsset  = $existingBlAssets |
        Where-Object { $_.name -eq $blAssetName -and $_.asset_layout_id -eq $BitLockerLayout.id } |
        Select-Object -First 1

    $blAsset = $null

    if ($null -eq $existingBlAsset) {
        Write-Host "  Creating BitLocker asset for drive $($vol.MountPoint)..."
        $blResponse = Invoke-HuduPost -Endpoint "/companies/$($Company.id)/assets" -Body $blAssetBody
        $blAsset    = $blResponse.asset
        Write-Host "  Created. Asset ID: $($blAsset.id)" -ForegroundColor Green
    } else {
        Write-Host "  Updating existing BitLocker asset (ID: $($existingBlAsset.id)) for drive $($vol.MountPoint)..."
        $blResponse = Invoke-HuduPut -Endpoint "/companies/$($Company.id)/assets/$($existingBlAsset.id)" -Body $blAssetBody
        $blAsset    = if ($blResponse.asset) { $blResponse.asset } else { $existingBlAsset }
        Write-Host "  Updated. Asset ID: $($blAsset.id)" -ForegroundColor Green
    }

    if ($null -ne $Asset -and $null -ne $blAsset -and $Asset.id -and $blAsset.id -and ($Asset.id -ne $blAsset.id)) {
        Write-Host "  Checking for existing relation (BitLocker ID: $($blAsset.id) -> Computer ID: $($Asset.id))..."

        $existingRelations = Get-AllHuduPages -Endpoint "/relations" -ResultKey "relations" `
            -Query @{ fromable_id = $blAsset.id.ToString() }
        $relationExists = $existingRelations |
            Where-Object { $_.fromable_id -eq $blAsset.id -and $_.toable_id -eq $Asset.id }

        if ($null -eq $relationExists) {
            Write-Host "  Linking BitLocker asset to computer asset..."
            $relResponse = Invoke-HuduPost -Endpoint "/relations" -Body @{
                relation = @{
                    fromable_type = "Asset"
                    fromable_id   = $blAsset.id
                    toable_type   = "Asset"
                    toable_id     = $Asset.id
                }
            }
            if ($relResponse) {
                Write-Host "  Relation created. ID: $($relResponse.relation.id)" -ForegroundColor Green
            }
        } else {
            Write-Host "  Relation already exists. Skipping."
        }
    } else {
        Write-Warning "  Skipping relation - asset IDs missing or identical. Computer ID: $($Asset.id) | BitLocker ID: $($blAsset.id)"
    }
}

Write-Host "`nAll done. BitLocker assets uploaded and linked in Hudu." -ForegroundColor Green
