# Export-OUProperties.ps1
# Samples objects in a specific OU (users, computers, groups, contacts, managed
# service accounts, etc. — nested OUs excluded) and discovers which AD properties
# have actual content. Uses Get-ADObject so it works across all schema classes.
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

# Fallback property list used only when the OU is empty. Includes attributes
# common across users, computers, and groups so the UI has something to show.
$fallbackProperties = @(
    'Name','SamAccountName','DisplayName','Description',
    'DistinguishedName','ObjectClass','ObjectGUID','WhenCreated','WhenChanged'
)

# AD attributes that are noisy, internal, or huge and shouldn't be offered to users.
$excludedProperties = @(
    'nTSecurityDescriptor','msDS-AllowedToActOnBehalfOfOtherIdentity',
    'msExchMailboxSecurityDescriptor','PropertyNames','PropertyCount',
    'AddedProperties','RemovedProperties','ModifiedProperties','DistinguishedName'
) | ForEach-Object { $_.ToLower() }

Update-RequestStatus -status "Processing" -message "Scanning OU properties for: $ouDN"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Update-RequestStatus -status "Failed" -message "ActiveDirectory module not available: $($_.Exception.Message)"
    exit 1
}

# Exclude nested OUs and AD infrastructure plumbing (DFSR replication metadata,
# SCPs registered by VMs, legacy FRS objects, internal CN= containers). Keeping
# the filter in sync with Query-OUAccounts.ps1 so the property scan reflects the
# same population the actual report will produce.
$excludedClasses = @(
    'organizationalUnit',
    'container',
    'msDFSR-Subscription','msDFSR-Subscriber','msDFSR-LocalSettings',
    'msDFSR-Topology','msDFSR-Content','msDFSR-ContentSet','msDFSR-Member',
    'serviceConnectionPoint',
    'rpcContainer',
    'nTFRSSubscriber','nTFRSSubscriptions','nTFRSReplicaSet','nTFRSSettings','nTFRSMember'
)
$ldapFilter = '(&' + (($excludedClasses | ForEach-Object { "(!(objectClass=$_))" }) -join '') + ')'

try {
    # Sample up to $SampleSize objects from the OU (recursive). Get-ADObject with
    # -Properties * returns every populated attribute, so we can discover the real
    # schema in use rather than guessing from a hardcoded candidate list.
    $accounts = Get-ADObject -LDAPFilter $ldapFilter -SearchBase $ouDN -SearchScope Subtree `
        -Properties * -Server "nih.gov" -ErrorAction Stop |
        Select-Object -First $SampleSize

    $totalAccounts = (Get-ADObject -LDAPFilter $ldapFilter -SearchBase $ouDN -SearchScope Subtree `
        -Server "nih.gov" -ErrorAction SilentlyContinue | Measure-Object).Count

    $sampledCount = ($accounts | Measure-Object).Count

    if ($sampledCount -eq 0) {
        Update-RequestStatus -status "Completed" -message "No objects found in OU. Showing fallback property list."
        $populatedProperties = $fallbackProperties
    } else {
        Update-RequestStatus -status "Processing" -message "Sampled $sampledCount of $totalAccounts objects. Discovering non-empty properties..."

        # Walk every sampled object and collect the union of property names that
        # have a real value. This covers mixed-type OUs (e.g., users + groups + MSAs).
        $populatedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($obj in $accounts) {
            foreach ($prop in $obj.PSObject.Properties) {
                if ($excludedProperties -contains $prop.Name.ToLower()) { continue }
                $val = $prop.Value
                if ($null -eq $val) { continue }
                if ($val -is [System.Collections.ICollection] -and $val -isnot [string]) {
                    if ($val.Count -le 0) { continue }
                } elseif ($val.ToString().Trim() -eq '') {
                    continue
                }
                [void]$populatedSet.Add($prop.Name)
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

        Update-RequestStatus -status "Completed" -message "Property scan complete: $($populatedProperties.Count) properties with content found in $ouFriendlyName ($totalAccounts accounts total)"
    } else {
        Update-RequestStatus -status "Completed" -message "Property scan complete (saved locally): $($populatedProperties.Count) properties found."
    }

} catch {
    Update-RequestStatus -status "Failed" -message "Property scan error: $($_.Exception.Message)"
    exit 1
}
