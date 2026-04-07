# Export-OUProperties.ps1
# Samples accounts in a specific OU and discovers which AD properties have actual content.
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

# Candidate properties to probe (common AD user attributes)
$candidateProperties = @(
    'SamAccountName','Name','DisplayName','GivenName','Surname',
    'Description','Title','Department','Company','Division',
    'Office','OfficePhone','MobilePhone','EmailAddress','HomePage',
    'Manager','StreetAddress','City','State','Country','PostalCode',
    'Enabled','PasswordLastSet','PasswordNeverExpires','PasswordNotRequired',
    'CannotChangePassword','AccountExpirationDate','SmartcardLogonRequired',
    'LastLogonDate','LogonCount','BadLogonCount','LockedOut',
    'WhenCreated','WhenChanged',
    'DistinguishedName','UserPrincipalName','ObjectGUID',
    'MemberOf','ServicePrincipalNames',
    'HomeDirectory','HomeDrive','ProfilePath','ScriptPath'
)

Update-RequestStatus -status "Processing" -message "Scanning OU properties for: $ouDN"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Update-RequestStatus -status "Failed" -message "ActiveDirectory module not available: $($_.Exception.Message)"
    exit 1
}

try {
    # Sample up to $SampleSize accounts from the OU (recursive)
    $accounts = Get-ADUser -Filter * -SearchBase $ouDN -SearchScope Subtree `
        -Properties $candidateProperties -Server "nih.gov" -ErrorAction Stop |
        Select-Object -First $SampleSize

    $totalAccounts = (Get-ADUser -Filter * -SearchBase $ouDN -SearchScope Subtree `
        -Server "nih.gov" -ErrorAction SilentlyContinue | Measure-Object).Count

    $sampledCount = ($accounts | Measure-Object).Count

    if ($sampledCount -eq 0) {
        Update-RequestStatus -status "Completed" -message "No accounts found in OU. Showing all candidate properties."
        $populatedProperties = $candidateProperties
    } else {
        Update-RequestStatus -status "Processing" -message "Sampled $sampledCount of $totalAccounts accounts. Discovering non-empty properties..."

        # Find properties that have at least one non-null, non-empty value in the sample
        $populatedProperties = @()
        foreach ($prop in $candidateProperties) {
            $hasValue = $accounts | Where-Object {
                $val = $_.$prop
                if ($null -eq $val) { return $false }
                if ($val -is [System.Collections.ICollection]) { return $val.Count -gt 0 }
                return ($val.ToString().Trim() -ne "")
            }
            if ($hasValue) {
                $populatedProperties += $prop
            }
        }
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
