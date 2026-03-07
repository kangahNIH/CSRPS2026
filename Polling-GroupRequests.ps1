# Polling-GroupRequests.ps1
# This script runs on the Jump Server, checks the Azure Queue for requests,
# and triggers the member retrieval script.

$StorageAccountName = "stcsps2026" # Replace with your actual Storage Account name
$QueueName = "group-requests"
$LocalScriptPath = "C:\STPS\CSRPS2026\CSRmemberLIST-RSAT.ps1"
$PollIntervalSeconds = 60

# --- CONNECTION ---
# You'll need to set the connection string as an environment variable or secret.
$ConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING

if (-not $ConnectionString) {
    Write-Error "AZURE_STORAGE_CONNECTION_STRING environment variable not found. Please set it before running."
    exit
}

Write-Host "Starting Polling for AD Group Member Retrieval requests..." -ForegroundColor Cyan

while ($true) {
    try {
        # Check if Azure CLI is logged in (optional but helpful)
        # Using PowerShell commands to interact with the queue (requires Az.Storage module)
        # or using the Azure CLI directly for simplicity if already installed.
        
        $messages = az storage message get --queue-name $QueueName --connection-string $ConnectionString --num-messages 1 --output json | ConvertFrom-Json
        
        if ($messages.Count -gt 0) {
            foreach ($msg in $messages) {
                $groupNames = $msg.content
                Write-Host "Received request for groups: $groupNames" -ForegroundColor Green
                
                # Execute the main retrieval script
                # We pipe the group names to the script if modified, or pass as argument
                & $LocalScriptPath -groupNamesInput $groupNames
                
                # Delete the message from the queue after processing
                az storage message delete --id $msg.id --pop-receipt $msg.popReceipt --queue-name $QueueName --connection-string $ConnectionString
                Write-Host "Message processed and deleted from queue." -ForegroundColor Gray
            }
        } else {
            # No messages, wait and loop
            Write-Host "." -NoNewline
        }
    } catch {
        Write-Warning "An error occurred during polling: $($_.Exception.Message)"
    }
    
    Start-Sleep -Seconds $PollIntervalSeconds
}
