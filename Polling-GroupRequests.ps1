# Polling-GroupRequests.ps1
# This script runs on the Jump Server (CSRMGMT02)
$StorageAccountName = "csrstpsadminstore" 
$QueueName = "group-requests"
$LocalScriptPath = "C:\STPS\CSRPS2026\CSRmemberLIST-RSAT.ps1"
$PollIntervalSeconds = 60
$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

Write-Host "Starting Polling for AD Group Member Retrieval requests..." -ForegroundColor Cyan

while ($true) {
    try {
        # --- HEARTBEAT UPDATE ---
        $heartbeat = @{
            lastSeen = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            status   = "Running"
            machine  = $env:COMPUTERNAME
        }
        $heartbeatPath = "$env:TEMP\poller-heartbeat.json"
        $heartbeat | ConvertTo-Json | Set-Content -Path $heartbeatPath -Encoding UTF8
        # Added --only-show-errors and suppressed progress to reduce noise
        az storage blob upload --container-name "config" --file $heartbeatPath --name "poller-heartbeat.json" --connection-string $ConnectionString --overwrite --output none --auth-mode key --only-show-errors --no-progress
        # -------------------------

        # Get message and ensure we handle the encoding
        $messages = az storage message get --queue-name $QueueName --connection-string $ConnectionString --num-messages 1 --output json --auth-mode key --only-show-errors | ConvertFrom-Json
        
        if ($messages.Count -gt 0) {
            foreach ($msg in $messages) {
                # Decode JSON message from web app
                $decodedBytes = [System.Convert]::FromBase64String($msg.content)
                $jsonStr = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
                $data = $jsonStr | ConvertFrom-Json
                
                $requestId = $data.requestId
                $groupNames = $data.groupNames
                
                Write-Host "Received Request [$requestId] for groups: $groupNames" -ForegroundColor Green
                
                if (Test-Path $LocalScriptPath) {
                    # Execute with RequestID for status tracking
                    & $LocalScriptPath -groupNamesInput $groupNames -requestId $requestId
                    
                    az storage message delete --id $msg.id --pop-receipt $msg.popReceipt --queue-name $QueueName --connection-string $ConnectionString --auth-mode key --only-show-errors
                } else {
                    Write-Error "Local script not found at: $LocalScriptPath"
                }
            }
        } else {
            Write-Host "." -NoNewline
        }
    } catch {
        Write-Warning "Polling error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
