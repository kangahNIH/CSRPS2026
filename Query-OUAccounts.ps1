# Query-OUAccounts.ps1
# Queries all objects within a specified OU (recursively) — users, computers, groups,
# contacts, managed service accounts, etc. — with user-selected AD attributes and
# exports a CSV named {OUName}_{timestamp}.csv to Azure Blob Storage.
# Nested organizational units are excluded; everything else is included.
# Triggered by the Polling script on the Jump Server (CSRMGMT02).

param (
    [Parameter(Mandatory=$false)]
    [string]$requestId,

    [Parameter(Mandatory=$false)]
    [string]$ouDN = "OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov",

    [Parameter(Mandatory=$false)]
    [string]$selectedProperties = "Name,SamAccountName,DisplayName,Description,WhenCreated,DistinguishedName"
)

$script:statusHistory = @()

function Update-RequestStatus {
    param([string]$status, [string]$message)
    if ($requestId -and $env:AZURE_STORAGE_CONNECTION_STRING) {
        $script:statusHistory += @{
            message   = $message
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $statusObj = @{
            status      = $status
            history     = $script:statusHistory
            lastUpdated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $tempPath = "$env:TEMP\$requestId.json"
        $statusObj | ConvertTo-Json -Depth 5 | Out-String | ForEach-Object {
            [System.IO.File]::WriteAllText($tempPath, $_.Trim(), [System.Text.UTF8Encoding]::new($false))
        }
        az storage blob upload --container-name "status" --file $tempPath --name "$requestId.json" `
            --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none `
            --auth-mode key --only-show-errors --no-progress
    }
}

Update-RequestStatus -status "Processing" -message "Jump Server received OU account query request..."

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Update-RequestStatus -status "Failed" -message "Failed to import Active Directory module: $($_.Exception.Message)"
    exit 1
}

# Parse selected properties
$properties = $selectedProperties.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($properties.Count -eq 0) {
    Update-RequestStatus -status "Failed" -message "No properties were selected."
    exit 1
}

# Extract a friendly OU name from the DN for the filename (first OU= segment)
$ouParts  = $ouDN -split ','
$ouShortName = ($ouParts[0] -replace 'OU=', '').Trim()

Update-RequestStatus -status "Processing" -message "Querying OU: $ouShortName ($ouDN) with $($properties.Count) properties..."

$reportPath = "C:\STPS\CSRPS2026\Reports"
if (-not (Test-Path -Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath -Force -ErrorAction Stop | Out-Null
}

$adParams = @{ ErrorAction = 'Stop'; Server = "nih.gov" }

# Column ordering: Name first (most useful identifier for users scanning the
# CSV), then ObjectClass, then whatever else the user picked in their original
# selection order. Both Name and ObjectClass are auto-included even if the user
# didn't tick them — they're cheap, universally useful columns.
$leadingColumns = @('Name','ObjectClass')
$outputColumns  = @($leadingColumns) + @($properties | Where-Object { $leadingColumns -notcontains $_ })

# Include only standard account-bearing object classes. Inclusion-based filtering
# is more robust than exclusion: AD has dozens of infrastructure classes (DFSR
# metadata, SCPs, crypto-policy contacts, printQueues, FRS, foreignSecurityPrincipal,
# rpcContainer, ...) and chasing them all is fragile. Three classes cover what an
# operator actually wants in a report:
#   user     → user, inetOrgPerson
#   computer → computer, msDS-ManagedServiceAccount, msDS-GroupManagedServiceAccount
#   group    → all group types (security, distribution, universal/global/local)
# This matches the population AD Users and Computers shows by default in the
# Users/Computers/Builtin views.
$includedClasses = @('user','computer','group')
$ldapFilter = '(|' + (($includedClasses | ForEach-Object { "(objectClass=$_)" }) -join '') + ')'

# Get-ADObject only accepts raw LDAP attribute names. The legacy Get-ADUser cmdlet
# exposed many friendly/computed properties (Enabled, PasswordLastSet, EmailAddress,
# ...) that have no direct LDAP counterpart. We map those to the underlying LDAP
# attribute(s) for the query, then derive the friendly value when building the row.
$friendlyAttrMap = @{
    'Enabled'                = @('userAccountControl')
    'PasswordLastSet'        = @('pwdLastSet')
    'PasswordNeverExpires'   = @('userAccountControl')
    'PasswordNotRequired'    = @('userAccountControl')
    'SmartcardLogonRequired' = @('userAccountControl')
    'AccountExpirationDate'  = @('accountExpires')
    'LastLogonDate'          = @('lastLogonTimestamp')
    'LockedOut'              = @('lockoutTime')
    'EmailAddress'           = @('mail')
    'OfficePhone'            = @('telephoneNumber')
    'MobilePhone'            = @('mobile')
    'HomePage'               = @('wWWHomePage')
    'Surname'                = @('sn')
    'GivenName'              = @('givenName')
    'Office'                 = @('physicalDeliveryOfficeName')
    'Country'                = @('c')
    'BadLogonCount'          = @('badPwdCount')
    'ServicePrincipalNames'  = @('servicePrincipalName')
}

# UAC bit masks for computed flags
$UAC_ACCOUNTDISABLE      = 0x0002
$UAC_PASSWD_NOTREQD      = 0x0020
$UAC_DONT_EXPIRE_PASSWORD= 0x10000
$UAC_SMARTCARD_REQUIRED  = 0x40000

# Build the actual LDAP attribute list we need to fetch (deduplicated).
$ldapAttrSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($p in $outputColumns) {
    if ($friendlyAttrMap.ContainsKey($p)) {
        foreach ($a in $friendlyAttrMap[$p]) { [void]$ldapAttrSet.Add($a) }
    } else {
        [void]$ldapAttrSet.Add($p)
    }
}
$ldapAttrs = @($ldapAttrSet)

# Translate one row's LDAP values into a friendly column value.
function Get-FriendlyValue {
    param($obj, [string]$friendlyName)
    switch ($friendlyName) {
        'Enabled'                { $uac = $obj.userAccountControl; if ($null -eq $uac) { return $null }; return -not [bool]($uac -band $UAC_ACCOUNTDISABLE) }
        'PasswordNeverExpires'   { $uac = $obj.userAccountControl; if ($null -eq $uac) { return $null }; return [bool]($uac -band $UAC_DONT_EXPIRE_PASSWORD) }
        'PasswordNotRequired'    { $uac = $obj.userAccountControl; if ($null -eq $uac) { return $null }; return [bool]($uac -band $UAC_PASSWD_NOTREQD) }
        'SmartcardLogonRequired' { $uac = $obj.userAccountControl; if ($null -eq $uac) { return $null }; return [bool]($uac -band $UAC_SMARTCARD_REQUIRED) }
        'PasswordLastSet'        { $ft = $obj.pwdLastSet;          if (-not $ft -or $ft -eq 0) { return $null }; return [DateTime]::FromFileTime([int64]$ft) }
        'LastLogonDate'          { $ft = $obj.lastLogonTimestamp;  if (-not $ft -or $ft -eq 0) { return $null }; return [DateTime]::FromFileTime([int64]$ft) }
        'AccountExpirationDate'  { $ft = $obj.accountExpires;      if (-not $ft -or $ft -eq 0 -or [int64]$ft -eq [int64]::MaxValue) { return $null }; return [DateTime]::FromFileTime([int64]$ft) }
        'LockedOut'              { $lt = $obj.lockoutTime;         return ($lt -and [int64]$lt -gt 0) }
        default {
            # For aliased single-attr maps, read the LDAP value directly.
            if ($friendlyAttrMap.ContainsKey($friendlyName)) {
                return $obj.($friendlyAttrMap[$friendlyName][0])
            }
            return $obj.$friendlyName
        }
    }
}

try {
    # Query all non-OU objects recursively within the OU. Get-ADObject works across
    # all schema classes, unlike Get-ADUser which only returns user objects.
    $accounts = Get-ADObject -LDAPFilter $ldapFilter -SearchBase $ouDN -SearchScope Subtree -Properties $ldapAttrs @adParams

    $totalAccounts = ($accounts | Measure-Object).Count
    Update-RequestStatus -status "Processing" -message "Found $totalAccounts objects. Building CSV..."

    if ($totalAccounts -eq 0) {
        Update-RequestStatus -status "Completed" -message "No objects found in OU: $ouShortName"
        exit
    }

    # Build report rows using friendly column names; values are translated per-attribute.
    $counter = 1
    $reportData = $accounts | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ "No." = $counter++ }
        foreach ($prop in $outputColumns) {
            $val = Get-FriendlyValue -obj $_ -friendlyName $prop
            if ($val -is [System.Collections.ICollection] -and $val -isnot [string]) {
                $row[$prop] = ($val -join "; ")
            } else {
                $row[$prop] = $val
            }
        }
        [PSCustomObject]$row
    }

    $currentDateTime = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvFileName = "$ouShortName-$currentDateTime.csv"
    $csvFilePath = Join-Path -Path $reportPath -ChildPath $csvFileName

    $reportData | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8 -Force
    Write-Host "Report generated: $csvFilePath" -ForegroundColor Green

    Update-RequestStatus -status "Processing" -message "CSV generated ($totalAccounts accounts). Uploading to Azure..."

    if ($env:AZURE_STORAGE_CONNECTION_STRING) {
        az storage blob upload --container-name "reports" --file $csvFilePath --name $csvFileName `
            --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none `
            --auth-mode key --only-show-errors --no-progress
        Update-RequestStatus -status "Completed" -message "Report ready: $csvFileName ($totalAccounts accounts, $($properties.Count) columns)"
    } else {
        Update-RequestStatus -status "Completed" -message "Report saved locally (no Azure): $csvFilePath"
    }

} catch {
    Write-Warning "Error querying OU accounts: $($_.Exception.Message)"
    Update-RequestStatus -status "Failed" -message "AD query error: $($_.Exception.Message)"
    exit 1
}
