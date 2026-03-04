# Step 0: Prerequisite Check - Admin Rights & Required Modules (ActiveDirectory, ImportExcel)

# 0a. Check for Administrator Privileges (required for module installation)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script needs to be run with Administrator privileges to check for and install required modules."
    Write-Warning "Please right-click the PowerShell icon, select 'Run as Administrator', and run the script again."
    Read-Host "Press Enter to exit"
    exit
}
Write-Host "Administrator privileges detected. Checking for required modules..." -ForegroundColor Green

# 0b. Check and Install ActiveDirectory Module
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "Active Directory module not found. Attempting to install RSAT Tools..." -ForegroundColor Yellow
    try {
        $capabilityName = "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
        Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
        Write-Host "Successfully installed the Active Directory module." -ForegroundColor Green
    } catch {
        Write-Error "Failed to auto-install the Active Directory module. Please install 'RSAT: Active Directory Tools' from Windows Settings -> Apps -> Optional features."
        Read-Host "Press Enter to exit"
        exit
    }
}

# 0c. Check and Install ImportExcel Module
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "Module 'ImportExcel' not found. Attempting to install from PowerShell Gallery..." -ForegroundColor Yellow
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Install-Module ImportExcel -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Write-Host "Successfully installed the 'ImportExcel' module." -ForegroundColor Green
    } catch {
        Write-Error "Failed to install 'ImportExcel' module. Please run 'Install-Module ImportExcel' in an Administrator PowerShell window."
        Read-Host "Press Enter to exit"
        exit
    }
}

# Import modules for the current session
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module ImportExcel -ErrorAction Stop
} catch {
    Write-Error "Failed to import required modules even after installation. Please restart PowerShell and try again."
    Read-Host "Press Enter to exit"
    exit
}

# --- SCRIPT CONTINUES ---

# Step 1: File and Path Setup
$reportPath = "C:\STPS"
if (-not (Test-Path -Path $reportPath)) {
    try {
        New-Item -ItemType Directory -Path $reportPath -ErrorAction Stop | Out-Null
        Write-Host "Successfully created directory: $reportPath"
    } catch {
        Write-Error "Failed to create directory: $reportPath. Please ensure you have the necessary permissions."
        exit
    }
}
$currentDateTime = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
$excelFilePath = Join-Path -Path $reportPath -ChildPath "Report-$currentDateTime.xlsx"


# Step 2: Handle Credentials
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$targetUser = "nih\aakangah"
$credential = $null

if ($currentUser -ne $targetUser) {
    Write-Host "Current user ($currentUser) is not the target user ($targetUser)."
    try {
        $password = Read-Host -AsSecureString "Please enter the password for the '$targetUser' account"
        $credential = New-Object System.Management.Automation.PSCredential($targetUser, $password)
        Get-ADRootDSE -Server "nih.gov" -Credential $credential -ErrorAction Stop | Out-Null
        Write-Host "Credential accepted for $targetUser."
    } catch {
        Write-Error "Authentication failed. Please check the password and try again."
        exit
    }
} else {
    Write-Host "Running with current user credentials ($currentUser)."
}

# Step 3: Get Group Names from User
$groupNamesInput = Read-Host "Enter the AD group names, separated by a comma (,)"
if ([string]::IsNullOrWhiteSpace($groupNamesInput)) {
    Write-Warning "No group names were entered. Exiting script."
    exit
}
$groupNames = $groupNamesInput.Split(',') | ForEach-Object { $_.Trim() }

Write-Host ""

# Step 4: Process Each Group and Export to its Own Excel Sheet
$groupsProcessed = 0
foreach ($groupName in $groupNames) {
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

    try {
        $adParams = @{ ErrorAction = 'Stop' }
        if ($credential) { $adParams['Credential'] = $credential }

        $group = Get-ADGroup -Identity $groupName -Properties Members, GroupCategory @adParams
        $groupType = switch ($group.GroupCategory) {
            "Security"     { "Security Group" }
            "Distribution" { "Distribution List" }
            default        { "Unknown Type" }
        }

        $allGroupMembers = Get-ADGroupMember -Identity $group -Recursive @adParams | Where-Object { $_.ObjectClass -eq 'user' }
        $userMemberCount = if ($null -ne $allGroupMembers) { ($allGroupMembers | Measure-Object).Count } else { 0 }

        Write-Host "Processing Group: '$($group.Name)'" -ForegroundColor Cyan
        Write-Host " - Type: $groupType"
        Write-Host " - Total User Members: $userMemberCount"
        
        if ($userMemberCount -gt 0) {
            $members = $allGroupMembers | Get-ADUser -Properties SamaccountName, GivenName, SurName, EmailAddress, DisplayName, Office, Department, Company @adParams

            $reportDataForGroup = @()
            $counter = 1
            $members | Sort-Object -Property SurName | ForEach-Object {
                $reportDataForGroup += [PSCustomObject]@{
                    "No."                 = $counter++
                    "SamAccountName"      = $_.SamaccountName
                    "FirstName"           = $_.GivenName
                    "LastName"            = $_.SurName
                    "PrimaryEmailAddress" = $_.EmailAddress
                    "Display"             = $_.DisplayName
                    "Office"              = $_.Office
                    "Department"          = $_.Department
                    "Company"             = $_.Company
                }
            }

            $sheetName = $group.Name -replace '[\\/:\*\?\[\]]', ''
            if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }

            # === CORRECTED LINE ===
            # Replaced -BoldHeader with -AutoSize, -FreezeTopRow, and -AutoFilter for a better, more compatible result.
            $reportDataForGroup | Export-Excel -Path $excelFilePath -WorksheetName $sheetName -AutoSize -FreezeTopRow -AutoFilter
            
            Write-Host " - Successfully exported to sheet '$sheetName' in the Excel file." -ForegroundColor Green
            $groupsProcessed++
        }
        Write-Host "----------------------------------------"
    } catch {
        Write-Warning "Could not process group '$groupName'. Please ensure the group name is correct."
        Write-Warning "Error details: $($_.Exception.Message)"
        Write-Host "----------------------------------------"
    }
}

# Final Confirmation
if ($groupsProcessed -gt 0) {
    Write-Host "Success! Report has been generated at: $excelFilePath" -ForegroundColor Cyan
} else {
    Write-Host "No members were found in the specified groups, or all group names were invalid."
}
