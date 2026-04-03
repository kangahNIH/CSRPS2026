# Query-ServiceAccounts.ps1
# This script queries service accounts from a specified OU with user-selected properties
# and exports the results to a CSV file, then uploads to Azure Blob Storage.
# Triggered by the Polling script on the Jump Server (CSRMGMT02).

param (
    [Parameter(Mandatory=$false)]
    [string]$requestId,

    [Parameter(Mandatory=$false)]
    [string]$ouDN = "OU=ServiceAccounts,OU=OPS,OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov",

    [Parameter(Mandatory=$false)]
    [string]$selectedProperties = "SamAccountName,Name,DisplayName,Description,Enabled,PasswordLastSet,LastLogonDate,WhenCreated"
)

# Global variable to track status history
$script:statusHistory = @()

# Helper function to update status in Azure
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
        az storage blob upload --container-name "status" --file $tempPath --name "$requestId.json" --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none --auth-mode key --only-show-errors --no-progress
    }
}

Update-RequestStatus -status "Processing" -message "Jump Server has started the Service Account query..."

# Import AD module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Update-RequestStatus -status "Failed" -message "Failed to import Active Directory module."
    exit 1
}

# Parse the selected properties (comma-separated)
$properties = $selectedProperties.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($properties.Count -eq 0) {
    Update-RequestStatus -status "Failed" -message "No properties were selected."
    exit 1
}

Update-RequestStatus -status "Processing" -message "Querying OU: $ouDN with $($properties.Count) properties: [$($properties -join ', ')]"

$reportPath = "C:\STPS\CSRPS2026\Reports"
if (-not (Test-Path -Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath -Force -ErrorAction Stop | Out-Null
}

$adParams = @{ ErrorAction = 'Stop'; Server = "nih.gov" }

try {
    # Query service accounts with selected properties
    $accounts = Get-ADUser -Filter * -SearchBase $ouDN -Properties $properties @adParams

    $totalAccounts = ($accounts | Measure-Object).Count
    Update-RequestStatus -status "Processing" -message "Found $totalAccounts service accounts. Building report..."

    if ($totalAccounts -eq 0) {
        Update-RequestStatus -status "Completed" -message "No service accounts found in the specified OU."
        exit
    }

    # Build report data with row numbers and selected properties
    $counter = 1
    $reportData = $accounts | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ "No." = $counter++ }
        foreach ($prop in $properties) {
            $val = $_.$prop
            # Handle collection properties (like MemberOf, ServicePrincipalNames)
            if ($val -is [System.Collections.ICollection]) {
                $row[$prop] = ($val -join "; ")
            } else {
                $row[$prop] = $val
            }
        }
        [PSCustomObject]$row
    }

    # Extract a friendly name from the OU for the filename
    $ouParts = $ouDN -split ','
    $ouShortName = ($ouParts[0] -replace 'OU=','').Trim()
    $currentDateTime = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvFileName = "SvcAcct-$ouShortName-$currentDateTime.csv"
    $csvFilePath = Join-Path -Path $reportPath -ChildPath $csvFileName

    $reportData | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8 -Force
    Write-Host "Report generated: $csvFilePath" -ForegroundColor Green

    Update-RequestStatus -status "Processing" -message "Report generated locally. Uploading to Azure..."

    # Upload to Azure Blob Storage
    if ($env:AZURE_STORAGE_CONNECTION_STRING) {
        az storage blob upload --container-name "reports" --file $csvFilePath --name $csvFileName --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none --auth-mode key --only-show-errors --no-progress
        Update-RequestStatus -status "Completed" -message "Service Account report uploaded: $csvFileName ($totalAccounts accounts, $($properties.Count) properties)"
    } else {
        Update-RequestStatus -status "Completed" -message "Report saved locally (no Azure connection): $csvFileName"
    }

} catch {
    Write-Warning "Error querying service accounts: $($_.Exception.Message)"
    Update-RequestStatus -status "Failed" -message "Error: $($_.Exception.Message)"
    exit 1
}
