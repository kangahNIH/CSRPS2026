# Query-OUAccounts.ps1
# Queries all user accounts within a specified OU (recursively) with user-selected
# AD attributes and exports a CSV named {OUName}_{timestamp}.csv to Azure Blob Storage.
# Triggered by the Polling script on the Jump Server (CSRMGMT02).

param (
    [Parameter(Mandatory=$false)]
    [string]$requestId,

    [Parameter(Mandatory=$false)]
    [string]$ouDN = "OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov",

    [Parameter(Mandatory=$false)]
    [string]$selectedProperties = "SamAccountName,Name,DisplayName,Description,Enabled,PasswordLastSet,LastLogonDate,WhenCreated,DistinguishedName"
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

try {
    # Query all users recursively within the OU
    $accounts = Get-ADUser -Filter * -SearchBase $ouDN -SearchScope Subtree -Properties $properties @adParams

    $totalAccounts = ($accounts | Measure-Object).Count
    Update-RequestStatus -status "Processing" -message "Found $totalAccounts accounts. Building CSV..."

    if ($totalAccounts -eq 0) {
        Update-RequestStatus -status "Completed" -message "No user accounts found in OU: $ouShortName"
        exit
    }

    # Build report rows
    $counter = 1
    $reportData = $accounts | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ "No." = $counter++ }
        foreach ($prop in $properties) {
            $val = $_.$prop
            if ($val -is [System.Collections.ICollection]) {
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
