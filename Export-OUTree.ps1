# Export-OUTree.ps1
# Enumerates all OUs under the CSR root OU and exports a nested JSON tree
# to Azure Blob Storage (config/ou-tree.json).
# Runs on the Jump Server (CSRMGMT02) at startup and daily.

param (
    [string]$RootOU = "OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov"
)

$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

Write-Host "[OUTree] Starting OU tree export from: $RootOU" -ForegroundColor Cyan

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Warning "[OUTree] Failed to import ActiveDirectory module: $($_.Exception.Message)"
    exit 1
}

# Recursive function to build the OU tree
function Get-OUNode {
    param ([string]$OU)

    $parts = $OU -split ','
    $name = ($parts[0] -replace 'OU=', '').Trim()

    # Count accounts (users + computers) directly in this OU (non-recursive)
    try {
        $userCount = (Get-ADUser -Filter * -SearchBase $OU -SearchScope OneLevel -Server "nih.gov" -ErrorAction SilentlyContinue | Measure-Object).Count
        $computerCount = (Get-ADComputer -Filter * -SearchBase $OU -SearchScope OneLevel -Server "nih.gov" -ErrorAction SilentlyContinue | Measure-Object).Count
        $accountCount = $userCount + $computerCount
    } catch {
        $accountCount = 0
    }

    # Get child OUs
    $childOUs = @()
    try {
        $childOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $OU -SearchScope OneLevel -Server "nih.gov" -ErrorAction Stop |
            Sort-Object Name
    } catch {
        Write-Warning "[OUTree] Could not get children of ${OU}: $($_.Exception.Message)"
    }

    $children = @()
    foreach ($child in $childOUs) {
        $childNode = Get-OUNode -OU $child.DistinguishedName
        $children += $childNode
    }

    return [ordered]@{
        name         = $name
        dn           = $OU
        accountCount = $accountCount
        children     = $children
    }
}

try {
    Write-Host "[OUTree] Building OU tree..." -ForegroundColor DarkCyan
    $tree = Get-OUNode -OU $RootOU

    $tempPath = "$env:TEMP\ou-tree.json"
    $tree | ConvertTo-Json -Depth 20 | Out-String | ForEach-Object {
        [System.IO.File]::WriteAllText($tempPath, $_.Trim(), [System.Text.UTF8Encoding]::new($false))
    }

    Write-Host "[OUTree] Tree built. Uploading to Azure Blob (config/ou-tree.json)..." -ForegroundColor DarkCyan

    if ($ConnectionString) {
        az storage blob upload `
            --container-name "config" `
            --file $tempPath `
            --name "ou-tree.json" `
            --connection-string $ConnectionString `
            --overwrite `
            --output none `
            --auth-mode key `
            --only-show-errors `
            --no-progress
        Write-Host "[OUTree] Upload complete." -ForegroundColor Green
    } else {
        Write-Warning "[OUTree] AZURE_STORAGE_CONNECTION_STRING not set. Tree saved locally only: $tempPath"
    }
} catch {
    Write-Warning "[OUTree] Error building OU tree: $($_.Exception.Message)"
    exit 1
}
