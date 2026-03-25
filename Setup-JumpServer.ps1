# Setup-JumpServer.ps1
# This script configures and verifies the Jump Server environment for AD Group Retrieval.

$reportPath = "C:\STPS\CSRPS2026\Reports"
$scriptPath = "C:\STPS\CSRPS2026"

Write-Host "--- Jump Server Setup & Diagnostics ---" -ForegroundColor Cyan

# 1. Create Directories
if (-not (Test-Path $reportPath)) {
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
    Write-Host "[OK] Created directory: $reportPath" -ForegroundColor Green
}

# 2. Check for Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning "[ERROR] Azure CLI (az) not found! Please install it: https://aka.ms/installazurecliwindows"
} else {
    Write-Host "[OK] Azure CLI is installed." -ForegroundColor Green
}

# 3. Check for Connection String
if (-not $env:AZURE_STORAGE_CONNECTION_STRING) {
    Write-Warning "[ERROR] AZURE_STORAGE_CONNECTION_STRING is NOT set in environment variables."
    Write-Host "To fix this, run: [System.Environment]::SetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', 'YOUR_CONNECTION_STRING', 'Machine')" -ForegroundColor Yellow
} else {
    Write-Host "[OK] Connection string found." -ForegroundColor Green
}

# 4. Check for Active Directory Module
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Warning "[ERROR] Active Directory module not found. Run CSRmemberLIST-RSAT.ps1 once as Admin to install it."
} else {
    Write-Host "[OK] Active Directory module is available." -ForegroundColor Green
}

# 5. Check for local script path
$LocalScript = Join-Path $scriptPath "CSRmemberLIST-RSAT.ps1"
if (-not (Test-Path $LocalScript)) {
    Write-Warning "[ERROR] CSRmemberLIST-RSAT.ps1 NOT found at $LocalScript"
} else {
    Write-Host "[OK] Found worker script: $LocalScript" -ForegroundColor Green
}

Write-Host "`nTo start the poller, run: .\Polling-GroupRequests.ps1" -ForegroundColor Cyan
