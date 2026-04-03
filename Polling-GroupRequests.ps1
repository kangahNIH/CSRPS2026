# Polling-GroupRequests.ps1
# This script runs on the Jump Server (CSRMGMT02)
$StorageAccountName = "csrstpsadminstore"
$QueueName = "group-requests"
$LocalScriptsDir = "C:\STPS\CSRPS2026"
$LocalScriptPath = "$LocalScriptsDir\CSRmemberLIST-RSAT.ps1"
$ServiceAccountScriptPath = "$LocalScriptsDir\Query-ServiceAccounts.ps1"
$ExportPropertiesScriptPath = "$LocalScriptsDir\Export-ServiceAccountProperties.ps1"
$PollIntervalSeconds = 60
$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

# --- Auto-Sync: Download latest scripts from Azure Blob ---
function Sync-ScriptsFromAzure {
    Write-Host "[Sync] Checking for script updates in Azure..." -ForegroundColor DarkCyan
    try {
        $blobs = az storage blob list --container-name "scripts" --connection-string $ConnectionString --output json --auth-mode key --only-show-errors | ConvertFrom-Json
        if (-not $blobs -or $blobs.Count -eq 0) {
            Write-Host "[Sync] No scripts found in Azure 'scripts' container." -ForegroundColor Yellow
            return
        }

        foreach ($blob in $blobs) {
            $blobName = $blob.name
            # Only sync .ps1 files
            if ($blobName -notlike "*.ps1") { continue }

            $localPath = Join-Path $LocalScriptsDir $blobName
            $blobLastModified = [DateTime]::Parse($blob.properties.lastModified).ToUniversalTime()

            $needsUpdate = $true
            if (Test-Path $localPath) {
                $localLastModified = (Get-Item $localPath).LastWriteTimeUtc
                if ($localLastModified -ge $blobLastModified) {
                    $needsUpdate = $false
                }
            }

            if ($needsUpdate) {
                Write-Host "[Sync] Downloading updated script: $blobName" -ForegroundColor Green
                az storage blob download --container-name "scripts" --name $blobName --file $localPath --connection-string $ConnectionString --overwrite --output none --auth-mode key --only-show-errors --no-progress
            }
        }
        Write-Host "[Sync] Script sync complete." -ForegroundColor DarkCyan
    } catch {
        Write-Warning "[Sync] Script sync error: $($_.Exception.Message)"
    }
}

# --- Auto-Run: Export Service Account Properties ---
function Invoke-PropertyExport {
    Write-Host "[Auto] Running Export-ServiceAccountProperties.ps1..." -ForegroundColor Magenta
    try {
        if (Test-Path $ExportPropertiesScriptPath) {
            & $ExportPropertiesScriptPath
            Write-Host "[Auto] Property export completed." -ForegroundColor Green
        } else {
            Write-Warning "[Auto] Export-ServiceAccountProperties.ps1 not found at: $ExportPropertiesScriptPath"
        }
    } catch {
        Write-Warning "[Auto] Property export error: $($_.Exception.Message)"
    }
}

Write-Host "Starting Polling for AD requests..." -ForegroundColor Cyan

# --- Startup: Sync scripts and run property export immediately ---
Sync-ScriptsFromAzure
Invoke-PropertyExport

# Track when the last property export ran (for daily re-run)
$script:lastPropertyExport = Get-Date

while ($true) {
    try {
        # --- HEARTBEAT UPDATE ---
        $heartbeat = @{
            lastSeen = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            status   = "Running"
            machine  = $env:COMPUTERNAME
        }
        $heartbeatPath = "$env:TEMP\poller-heartbeat.json"
        $heartbeat | ConvertTo-Json | Out-String | ForEach-Object { [System.IO.File]::WriteAllText($heartbeatPath, $_.Trim(), [System.Text.UTF8Encoding]::new($false)) }
        az storage blob upload --container-name "config" --file $heartbeatPath --name "poller-heartbeat.json" --connection-string $ConnectionString --overwrite --output none --auth-mode key --only-show-errors --no-progress
        # -------------------------

        # --- Periodic: Sync scripts every 10 minutes ---
        if (-not $script:lastScriptSync -or ((Get-Date) - $script:lastScriptSync).TotalMinutes -ge 10) {
            Sync-ScriptsFromAzure
            $script:lastScriptSync = Get-Date
        }

        # --- Periodic: Re-run property export once daily ---
        if (((Get-Date) - $script:lastPropertyExport).TotalHours -ge 24) {
            Invoke-PropertyExport
            $script:lastPropertyExport = Get-Date
        }

        # --- Poll Queue for Requests ---
        $messages = az storage message get --queue-name $QueueName --connection-string $ConnectionString --num-messages 1 --output json --auth-mode key --only-show-errors | ConvertFrom-Json

        if ($messages.Count -gt 0) {
            foreach ($msg in $messages) {
                # Decode JSON message from web app
                $decodedBytes = [System.Convert]::FromBase64String($msg.content)
                $jsonStr = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
                $data = $jsonStr | ConvertFrom-Json

                $requestId = $data.requestId
                $requestType = $data.type

                if ($requestType -eq "service-account-report") {
                    # Handle Service Account report request
                    $ouDN = $data.ouDN
                    $selectedProperties = $data.selectedProperties
                    Write-Host "Received Service Account Request [$requestId] for OU: $ouDN" -ForegroundColor Magenta

                    if (Test-Path $ServiceAccountScriptPath) {
                        & $ServiceAccountScriptPath -requestId $requestId -ouDN $ouDN -selectedProperties $selectedProperties
                    } else {
                        Write-Error "Service Account script not found at: $ServiceAccountScriptPath"
                    }
                } else {
                    # Handle Group Member request (existing behavior)
                    $groupNames = $data.groupNames
                    Write-Host "Received Request [$requestId] for groups: $groupNames" -ForegroundColor Green

                    if (Test-Path $LocalScriptPath) {
                        & $LocalScriptPath -groupNamesInput $groupNames -requestId $requestId
                    } else {
                        Write-Error "Local script not found at: $LocalScriptPath"
                    }
                }

                az storage message delete --id $msg.id --pop-receipt $msg.popReceipt --queue-name $QueueName --connection-string $ConnectionString --auth-mode key --only-show-errors
            }
        } else {
            Write-Host "." -NoNewline
        }
    } catch {
        Write-Warning "Polling error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
