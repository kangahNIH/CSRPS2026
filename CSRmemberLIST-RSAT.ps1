# CSRmemberLIST-RSAT.ps1
# This script retrieves AD group members and exports them to a CSV file.
# It can be run manually or triggered automatically by the Polling script.

param (
    [Parameter(Mandatory=$false)]
    [string]$groupNamesInput,
    [Parameter(Mandatory=$false)]
    [string]$requestId
)

# Helper function to update status in Azure
function Update-RequestStatus {
    param([string]$status, [string]$message)
    if ($requestId -and $env:AZURE_STORAGE_CONNECTION_STRING) {
        $statusObj = @{
            status = $status
            message = $message
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $tempPath = "$env:TEMP\$requestId.json"
        $statusObj | ConvertTo-Json | Set-Content -Path $tempPath -Encoding UTF8
        az storage blob upload --container-name "status" --file $tempPath --name "$requestId.json" --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none
    }
}

Update-RequestStatus -status "Processing" -message "Jump Server has started the AD query process..."

# Step 0: Prerequisite Check - Active Directory Module & Admin Rights
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "Active Directory module not found. Checking for administrator privileges to attempt installation..." -ForegroundColor Yellow

    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Administrator privileges are required to install the Active Directory module."
        exit
    }

    Write-Host "Administrator privileges detected. Attempting to install RSAT: Active Directory Tools..."
    try {
        $capabilityName = "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
        $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction SilentlyContinue

        if ($capability.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
            Write-Host "Successfully installed the Active Directory module." -ForegroundColor Green
        } else {
             Write-Host "The required Windows feature is already installed." -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed to install the Active Directory module. Please install 'RSAT: Active Directory Domain Services and Lightweight Directory Services Tools' manually."
        exit
    }
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Error "Failed to import the Active Directory Module."
    exit
}

# Step 1: Create Report Directory
$reportPath = "C:\STPS\CSRPS2026\Reports"
if (-not (Test-Path -Path $reportPath)) {
    try {
        New-Item -ItemType Directory -Path $reportPath -Force -ErrorAction Stop | Out-Null
        Write-Host "Successfully created directory: $reportPath"
    }
    catch {
        Write-Error "Failed to create directory: $reportPath."
        exit
    }
}

# Filename variables
$currentDateTime = Get-Date -Format "yyyyMMdd-HHmmss"
$filePrefix = "Report"

# Step 2: Handle Credentials
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$targetUser = "nih\aakangah"
$credential = $null

if ($currentUser -ne $targetUser) {
    Write-Host "Current user ($currentUser) is not the target user ($targetUser)."
}

# Step 3: Get Group Names
if ([string]::IsNullOrWhiteSpace($groupNamesInput)) {
    $groupNamesInput = Read-Host "Enter the AD group names, separated by a comma (,)"
}

if ([string]::IsNullOrWhiteSpace($groupNamesInput)) {
    Write-Warning "No group names were entered. Exiting script."
    Update-RequestStatus -status "Failed" -message "No group names were provided."
    exit
}
$groupNames = $groupNamesInput.Split(',') | ForEach-Object { $_.Trim() }
$totalGroups = $groupNames.Count
$currentGroupIdx = 0

# Initialize an array to hold all member data.
$allMembers = @()
Write-Host ""

# Step 4: Process Each Group
foreach ($groupName in $groupNames) {
    $currentGroupIdx++
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

    Update-RequestStatus -status "Processing" -message "Processing group $currentGroupIdx of $($totalGroups): [$groupName]..."

    try {
        # Define parameters for AD cmdlets, ensuring we target the correct server
        $adParams = @{ ErrorAction = 'Stop'; Server = "nih.gov" }
        if ($credential) { $adParams['Credential'] = $credential }

        # Search by Name OR SamAccountName for maximum reliability (Version 2.2)
        $group = Get-ADGroup -Filter "Name -eq '$groupName' -or SamAccountName -eq '$groupName'" -Properties GroupCategory @adParams | Select-Object -First 1

        if (-not $group) {
            throw "Group '$groupName' was not found in AD via Name or SamAccountName filter."
        }

        # Determine group type
        $groupTypeCode = switch ($group.GroupCategory) {
            "Security"     { "SG" }
            "Distribution" { "DL" }
            default        { "GRP" }
        }
        $groupType = if ($groupTypeCode -eq "SG") { "Security Group" } else { "Distribution List" }

        # Generate a unique prefix for THIS specific group
        $thisGroupPrefix = "$($groupTypeCode)-$($group.Name)"

        # Use the absolute DistinguishedName for the member lookup to avoid 'Identity' errors
        $allGroupMembers = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive @adParams | Where-Object { $_.ObjectClass -eq 'user' }
        $userMemberCount = if ($null -ne $allGroupMembers) { ($allGroupMembers | Measure-Object).Count } else { 0 }

        Write-Host "Processing Group: '$($group.Name)'" -ForegroundColor Cyan
        Write-Host " - Type: $groupType"
        Write-Host " - Total User Members: $userMemberCount"

        # --- Step 5: Export and Upload this specific Group ---
        if ($userMemberCount -gt 0) {
            # ... (existing export logic) ...
            $members = $allGroupMembers | Get-ADUser -Properties SamaccountName, GivenName, SurName, EmailAddress, DisplayName, Office, Department, Company @adParams
            $localCounter = 1
            $reportData = foreach ($member in $members) {
                [PSCustomObject]@{
                    "No."                 = $localCounter++
                    "GroupName"           = $group.Name
                    "SamAccountName"      = $member.SamAccountName
                    "FirstName"           = $member.GivenName
                    "LastName"            = $member.SurName
                    "PrimaryEmailAddress" = $member.EmailAddress
                    "Display"             = $member.DisplayName
                    "Office"              = $member.Office
                    "Department"          = $member.Department
                    "Company"             = $member.Company
                }
            }

            $csvFilePath = Join-Path -Path $reportPath -ChildPath "$($thisGroupPrefix)-$currentDateTime.csv"
            $reportData | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8 -Force
            Write-Host "Success! Group report generated: $csvFilePath" -ForegroundColor Green

            if ($env:AZURE_STORAGE_CONNECTION_STRING) {
                $blobName = Split-Path $csvFilePath -Leaf
                az storage blob upload --container-name "reports" --file $csvFilePath --name $blobName --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none
            }
        }
        else {
            Write-Host "No user members found for group '$groupName'." -ForegroundColor Yellow
            Update-RequestStatus -status "Processing" -message "Group [$groupName] has 0 members. Skipping file generation."
        }
        Write-Host "----------------------------------------"
    }
    catch {
        Write-Warning "Could not process group '$groupName'. Error: $($_.Exception.Message)"
        Update-RequestStatus -status "Processing" -message "Warning: Could not find or access group [$groupName]. Error: $($_.Exception.Message)"
    }
}

# Step 7: Final Status Update
Update-RequestStatus -status "Completed" -message "All requested groups have been processed and uploaded individually."
