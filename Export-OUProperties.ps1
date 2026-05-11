# Export-OUProperties.ps1
# Samples objects in a specific OU (users, computers, groups, contacts, managed
# service accounts, etc. — nested OUs and AD plumbing excluded) and discovers
# which AD properties have actual content. Uses Get-ADObject so it works across
# all schema classes.
# Uploads result to Azure Blob: config/ou-props/{sanitizedDN}.json
# Called on-demand when a user selects an OU in the OU Browser.

param (
    [Parameter(Mandatory=$true)]
    [string]$ouDN,

    [Parameter(Mandatory=$false)]
    [string]$requestId,

    [Parameter(Mandatory=$false)]
    [int]$SampleSize = 50
)

$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

# Status helper (reuses existing status blob pattern)
$script:statusHistory = @()
function Update-RequestStatus {
    param([string]$status, [string]$message)
    Write-Host "[$status] $message" -ForegroundColor $(if ($status -eq 'Failed') { 'Red' } elseif ($status -eq 'Completed') { 'Green' } else { 'Cyan' })
    if ($requestId -and $ConnectionString) {
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
            --connection-string $ConnectionString --overwrite --output none `
            --auth-mode key --only-show-errors --no-progress
    }
}

# Curated candidate property list. LDAP-native attribute names that Get-ADObject
# accepts across users, computers, groups, contacts, and MSAs. Avoids the slowness
# of -Properties * (which fetches the entire object including security descriptors).
$candidateProperties = @(
    # Identity
    'Name','SamAccountName','DisplayName','UserPrincipalName','Description',
    'DistinguishedName','ObjectClass','ObjectGUID','ObjectSid','CanonicalName',
    # Lifecycle
    'WhenCreated','WhenChanged',
    # Authentication / account flags (raw LDAP)
    'userAccountControl','pwdLastSet','lastLogonTimestamp','accountExpires',
    'lockoutTime','logonCount','badPwdCount',
    # Contact / person
    'givenName','sn','mail','telephoneNumber','mobile','info',
    'title','department','company','manager','employeeID','employeeType',
    'physicalDeliveryOfficeName','streetAddress','l','st','postalCode','c','co',
    # Group
    'groupType','member','memberOf','managedBy',
    # Computer
    'dNSHostName','operatingSystem','operatingSystemVersion','operatingSystemServicePack',
    'servicePrincipalName','primaryGroupID','location',
    # MSA / gMSA
    'msDS-ManagedPasswordInterval','msDS-HostServiceAccount','msDS-GroupMSAMembership',
    'msDS-SupportedEncryptionTypes',
    # Home / profile
    'homeDirectory','homeDrive','profilePath','scriptPath'
)

# Friendly synthetic properties — surfaced in the UI when the underlying LDAP
# attribute is populated. Query-OUAccounts.ps1 translates these back to LDAP at
# query time and converts the raw value into a readable form (DateTime, bool, etc).
$syntheticByLdapAttr = @{
    'userAccountControl' = @('Enabled','PasswordNeverExpires','PasswordNotRequired','SmartcardLogonRequired')
    'pwdLastSet'         = @('PasswordLastSet')
    'lastLogonTimestamp' = @('LastLogonDate')
    'accountExpires'     = @('AccountExpirationDate')
    'lockoutTime'        = @('LockedOut')
    'mail'               = @('EmailAddress')
    'telephoneNumber'    = @('OfficePhone')
    'mobile'             = @('MobilePhone')
    'sn'                 = @('Surname')
    'physicalDeliveryOfficeName' = @('Office')
    'c'                  = @('Country')
    'badPwdCount'        = @('BadLogonCount')
    'servicePrincipalName' = @('ServicePrincipalNames')
}

# Always-offered properties (even if the OU is empty) so the picker isn't blank.
$fallbackProperties = @(
    'Name','SamAccountName','DisplayName','Description','ObjectClass',
    'DistinguishedName','ObjectGUID','WhenCreated','WhenChanged'
)

Update-RequestStatus -status "Processing" -message "Scanning OU properties for: $ouDN"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Update-RequestStatus -status "Failed" -message "ActiveDirectory module not available: $($_.Exception.Message)"
    exit 1
}

# Include only standard account-bearing object classes (user, computer, group).
# Inclusion-based filter mirrors Query-OUAccounts.ps1 so the property scan covers
# exactly the population the actual report will produce.
#   user     → user, inetOrgPerson
#   computer → computer, msDS-ManagedServiceAccount, msDS-GroupManagedServiceAccount
#   group    → all group types
# Infrastructure classes (DFSR, SCP, FRS, container, contact-as-crypto-policy,
# printQueue, foreignSecurityPrincipal, etc.) are out by virtue of not being
# listed — robust against new schema additions.
$includedClasses = @('user','computer','group')
$ldapFilter = '(|' + (($includedClasses | ForEach-Object { "(objectClass=$_)" }) -join '') + ')'

try {
    # ResultSetSize limits the server-side LDAP page, so we don't drag the whole
    # subtree across the wire just to keep the first 50.
    $accounts = @(Get-ADObject -LDAPFilter $ldapFilter -SearchBase $ouDN -SearchScope Subtree `
        -ResultSetSize $SampleSize -Properties $candidateProperties `
        -Server "nih.gov" -ErrorAction Stop)

    # Total count (no -Properties, no result limit) — used to tell the user how
    # representative the sample is.
    $totalAccounts = (Get-ADObject -LDAPFilter $ldapFilter -SearchBase $ouDN -SearchScope Subtree `
        -Server "nih.gov" -ErrorAction SilentlyContinue | Measure-Object).Count

    $sampledCount = $accounts.Count

    # Count objects by ObjectClass so the UI can show a breakdown like
    # "26 computer, 4 user". Helps users understand what a parent-OU sample contains.
    $classCounts = @{}
    foreach ($obj in $accounts) {
        $cls = $obj.ObjectClass
        if ($cls) {
            if ($classCounts.ContainsKey($cls)) { $classCounts[$cls] = $classCounts[$cls] + 1 }
            else { $classCounts[$cls] = 1 }
        }
    }

    $isEmpty = ($totalAccounts -eq 0)

    if ($sampledCount -eq 0) {
        if ($isEmpty) {
            Update-RequestStatus -status "Completed" -message "OU is empty — no eligible objects found. Sub-OUs and AD infrastructure objects (DFSR, SCPs, etc.) are excluded by design."
        } else {
            Update-RequestStatus -status "Completed" -message "Sampled 0 of $totalAccounts objects. Returning fallback property list."
        }
        $populatedProperties = if ($isEmpty) { @() } else { $fallbackProperties }
    } else {
        Update-RequestStatus -status "Processing" -message "Sampled $sampledCount of $totalAccounts objects. Discovering populated properties..."

        # Collect the union of populated LDAP attributes across the sample.
        $populatedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($obj in $accounts) {
            foreach ($candidate in $candidateProperties) {
                $val = $obj.$candidate
                if ($null -eq $val) { continue }
                if ($val -is [System.Collections.ICollection] -and $val -isnot [string]) {
                    if ($val.Count -le 0) { continue }
                } elseif ($val.ToString().Trim() -eq '') {
                    continue
                }
                [void]$populatedSet.Add($candidate)
            }
        }

        # Add friendly synthetic property names whose underlying LDAP attr is populated.
        # Query-OUAccounts.ps1 knows how to decode these into readable column values.
        foreach ($ldapAttr in $syntheticByLdapAttr.Keys) {
            if ($populatedSet.Contains($ldapAttr)) {
                foreach ($synth in $syntheticByLdapAttr[$ldapAttr]) {
                    [void]$populatedSet.Add($synth)
                }
            }
        }

        $populatedProperties = $populatedSet | Sort-Object
    }

    # Extract a friendly name from the OU DN
    $ouParts = $ouDN -split ','
    $ouFriendlyName = ($ouParts[0] -replace 'OU=', '').Trim()

    # Build a safe filename from the DN
    $safeName = $ouDN -replace 'OU=|DC=', '' -replace '[,=]', '_' -replace '__+', '_' -replace '^_|_$', ''

    $result = @{
        ou              = $ouDN
        ouFriendlyName  = $ouFriendlyName
        totalAccounts   = $totalAccounts
        sampleSize      = $sampledCount
        properties      = $populatedProperties
        objectClassCounts = $classCounts
        isEmpty         = $isEmpty
        searchScope     = 'Subtree'
        lastUpdated     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    $tempPath = "$env:TEMP\ou-props-$safeName.json"
    $result | ConvertTo-Json -Depth 5 | Out-String | ForEach-Object {
        [System.IO.File]::WriteAllText($tempPath, $_.Trim(), [System.Text.UTF8Encoding]::new($false))
    }

    if ($ConnectionString) {
        az storage blob upload `
            --container-name "config" `
            --file $tempPath `
            --name "ou-props/$safeName.json" `
            --connection-string $ConnectionString `
            --overwrite --output none --auth-mode key --only-show-errors --no-progress

        if ($isEmpty) {
            Update-RequestStatus -status "Completed" -message "$ouFriendlyName is empty (0 eligible objects). The OU Browser will show this clearly."
        } else {
            $breakdown = ($classCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { "$($_.Value) $($_.Name)" }) -join ', '
            Update-RequestStatus -status "Completed" -message "Property scan complete: $($populatedProperties.Count) properties found in $ouFriendlyName. Sample breakdown: $breakdown. (Total objects in subtree: $totalAccounts)"
        }
    } else {
        Update-RequestStatus -status "Completed" -message "Property scan complete (saved locally): $($populatedProperties.Count) properties found."
    }

} catch {
    Update-RequestStatus -status "Failed" -message "Property scan error: $($_.Exception.Message)"
    exit 1
}
