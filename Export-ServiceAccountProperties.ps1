# Export-ServiceAccountProperties.ps1
# This script discovers which AD properties have content for service accounts
# in a given OU and uploads the metadata to Azure Blob Storage.
# Run this on the Jump Server (CSRMGMT02) to populate the property selector in the frontend.

param (
    [Parameter(Mandatory=$false)]
    [string]$OUDistinguishedName = "OU=ServiceAccounts,OU=OPS,OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov"
)

$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

if (-not $ConnectionString) {
    Write-Error "AZURE_STORAGE_CONNECTION_STRING environment variable is not set."
    exit 1
}

# Import AD module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "Failed to import Active Directory module."
    exit 1
}

Write-Host "Discovering properties with content in: $OUDistinguishedName" -ForegroundColor Cyan

# Define the broad set of properties to check
$propertiesToCheck = @(
    "SamAccountName", "Name", "DisplayName", "Description", "Enabled",
    "GivenName", "Surname", "EmailAddress", "mail", "UserPrincipalName",
    "DistinguishedName", "CanonicalName", "ObjectClass", "ObjectGUID",
    "WhenCreated", "WhenChanged", "LastLogonDate", "PasswordLastSet",
    "PasswordNeverExpires", "PasswordExpired", "AccountExpirationDate",
    "LockedOut", "LogonCount", "BadLogonCount", "BadPasswordTime",
    "Office", "Department", "Company", "Title", "Manager",
    "StreetAddress", "City", "State", "PostalCode", "Country",
    "TelephoneNumber", "MobilePhone", "Fax", "HomePhone",
    "HomePage", "Info", "MemberOf",
    "ServicePrincipalNames", "msDS-AllowedToDelegateTo",
    "TrustedForDelegation", "TrustedToAuthForDelegation",
    "AccountNotDelegated", "ProtectedFromAccidentalDeletion",
    "OperatingSystem", "OperatingSystemVersion"
)

$adParams = @{ ErrorAction = 'Stop'; Server = "nih.gov" }

try {
    # Get all service accounts in the OU
    $accounts = Get-ADUser -Filter * -SearchBase $OUDistinguishedName -Properties $propertiesToCheck @adParams
    $totalAccounts = ($accounts | Measure-Object).Count

    Write-Host "Found $totalAccounts service accounts." -ForegroundColor Green

    if ($totalAccounts -eq 0) {
        Write-Warning "No accounts found in the specified OU."
        exit
    }

    # Check which properties have at least one non-null/non-empty value
    $propertiesWithContent = @()

    foreach ($prop in $propertiesToCheck) {
        $hasContent = $false
        foreach ($acct in $accounts) {
            $val = $acct.$prop
            if ($null -ne $val -and "$val" -ne "" -and "$val" -ne "{}") {
                # For collections (like MemberOf), check if non-empty
                if ($val -is [System.Collections.ICollection] -and $val.Count -eq 0) {
                    continue
                }
                $hasContent = $true
                break
            }
        }
        if ($hasContent) {
            $propertiesWithContent += $prop
        }
    }

    Write-Host "Properties with content: $($propertiesWithContent.Count) of $($propertiesToCheck.Count)" -ForegroundColor Cyan

    # Build the output object
    $output = @{
        ou              = $OUDistinguishedName
        ouFriendlyName  = "Service Accounts (OPS)"
        totalAccounts   = $totalAccounts
        properties      = $propertiesWithContent
        lastUpdated     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    # Write to temp file and upload
    $tempPath = "$env:TEMP\service-account-properties.json"
    $output | ConvertTo-Json -Depth 5 | Out-String | ForEach-Object {
        [System.IO.File]::WriteAllText($tempPath, $_.Trim(), [System.Text.UTF8Encoding]::new($false))
    }

    az storage blob upload --container-name "config" --file $tempPath --name "service-account-properties.json" --connection-string $ConnectionString --overwrite --output none --auth-mode key --only-show-errors --no-progress

    Write-Host "Successfully uploaded property metadata to Azure." -ForegroundColor Green
    Write-Host "Properties available: $($propertiesWithContent -join ', ')" -ForegroundColor White

} catch {
    Write-Error "Failed to discover properties: $($_.Exception.Message)"
    exit 1
}
