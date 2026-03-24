# Export-GroupLists.ps1
# This script exports AD group names to JSON and uploads to Azure.
# Run this on CSRMGMT02 as a scheduled task.

$SG_OU = "OU=Groups,OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov"
$DL_OU = "OU=Distribution Lists,OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov"
$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

if (-not $ConnectionString) {
    Write-Error "AZURE_STORAGE_CONNECTION_STRING not set."
    exit
}

Write-Host "Fetching Security Groups from: $SG_OU"
# 1. Get Security Groups
$SGs = Get-ADGroup -Filter * -SearchBase $SG_OU | Select-Object -ExpandProperty Name | Sort-Object

Write-Host "Fetching Distribution Lists from: $DL_OU"
# 2. Get Distribution Lists
$DLs = Get-ADGroup -Filter * -SearchBase $DL_OU | Select-Object -ExpandProperty Name | Sort-Object

# 3. Create JSON object
$GroupLists = @{
    securityGroups = $SGs
    distributionLists = $DLs
    lastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

# 4. Save and Upload
$tempPath = "$env:TEMP\group-lists.json"
$GroupLists | ConvertTo-Json | Set-Content -Path $tempPath -Encoding UTF8

Write-Host "Uploading to Azure (Container: config)..."
# Ensure container exists (silently continue if it does)
az storage container create --name "config" --connection-string $ConnectionString --output none 2>$null

# Upload the file
az storage blob upload --container-name "config" --file $tempPath --name "group-lists.json" --connection-string $ConnectionString --overwrite --output none

Write-Host "Successfully exported and uploaded group lists."
