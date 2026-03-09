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
        $statusObj | ConvertTo-Json | Out-File $tempPath
        az storage blob upload --container-name "status" --file $tempPath --name "$requestId.json" --connection-string $env:AZURE_STORAGE_CONNECTION_STRING --overwrite --output none
    }
}

Update-RequestStatus -status "Processing" -message "Jump Server has started the AD query process..."

# Step 0: Prerequisite Check - Active Directory Module & Admin Rights
# ... (rest of the prerequisite check code) ...
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "Active Directory module not found. Checking for administrator privileges to attempt installation..." -ForegroundColor Yellow

    # Check for elevated permissions, which are required to install a Windows Capability.
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Administrator privileges are required to install the Active Directory module. Please right-click the PowerShell icon and select 'Run as Administrator', then run the script again."
        # Use a pause to ensure the user can read the error message before the window closes if run from a file.
        Read-Host "Press Enter to exit"
        exit
    }
    
    Write-Host "Administrator privileges detected. Attempting to install RSAT: Active Directory Tools..."
    try {
        # The name of the capability for modern Windows versions (10/11)
        $capabilityName = "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
        
        # Check if the capability is already installed but somehow the module isn't being detected
        $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction SilentlyContinue
        
        if ($capability.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
            Write-Host "Successfully installed the Active Directory module. The script will now proceed." -ForegroundColor Green
        } else {
             Write-Host "The required Windows feature is already installed. The script will now proceed." -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed to install the Active Directory module. Please install 'RSAT: Active Directory Domain Services and Lightweight Directory Services Tools' from Windows Settings -> Apps -> Optional features and try again."
        Read-Host "Press Enter to exit"
        exit
    }
}

# Import the module for the current session.
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Error "Failed to import the Active Directory Module even after installation. Please restart PowerShell and try again."
    Read-Host "Press Enter to exit"
    exit
}

# --- SCRIPT CONTINUES AS BEFORE ---

# Step 1: Create Report Directory
$reportPath = "C:\STPS"
if (-not (Test-Path -Path $reportPath)) {
    try {
        New-Item -ItemType Directory -Path $reportPath -ErrorAction Stop | Out-Null
        Write-Host "Successfully created directory: $reportPath"
    }
    catch {
        Write-Error "Failed to create directory: $reportPath. Please ensure you have the necessary permissions."
        exit
    }
}

# Generate the file path for the CSV report with the current date and time.
$currentDateTime = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
$csvFilePath = Join-Path -Path $reportPath -ChildPath "Report-$currentDateTime.csv"


# Step 2: Handle Credentials
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$targetUser = "nih\aakangah"
$credential = $null

# If the logged-in user is not the target user, prompt for a password.
if ($currentUser -ne $targetUser) {
    Write-Host "Current user ($currentUser) is not the target user ($targetUser)."
    try {
        $password = Read-Host -AsSecureString "Please enter the password for the '$targetUser' account"
        $credential = New-Object System.Management.Automation.PSCredential($targetUser, $password)
        # Test the credential to ensure it is valid before proceeding.
        Get-ADRootDSE -Server "nih.gov" -Credential $credential -ErrorAction Stop | Out-Null
        Write-Host "Credential accepted for $targetUser."
    }
    catch {
        Write-Error "Authentication failed. Please check the password and try again."
        exit
    }
}
else {
    Write-Host "Running with current user credentials ($currentUser)."
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
Write-Host "" # Add a blank line for better readability.

# Step 4: Process Each Group
foreach ($groupName in $groupNames) {
    $currentGroupIdx++
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue } 

    Update-RequestStatus -status "Processing" -message "Processing group $currentGroupIdx of $totalGroups: [$groupName]..."

    try {
        # Define parameters for AD cmdlets, including credentials if provided.
        $adParams = @{ ErrorAction = 'Stop' }
        if ($credential) {
            $adParams['Credential'] = $credential
        }

        # Retrieve the group from Active Directory.
        $group = Get-ADGroup -Identity $groupName -Properties Members, GroupCategory @adParams

        # Determine if the group is a Security or Distribution group.
        $groupType = switch ($group.GroupCategory) {
            "Security"     { "Security Group" }
            "Distribution" { "Distribution List" }
            default        { "Unknown Type" }
        }

        # Get all recursively found user members.
        $allGroupMembers = Get-ADGroupMember -Identity $group -Recursive @adParams | Where-Object { $_.ObjectClass -eq 'user' }
        $userMemberCount = if ($null -ne $allGroupMembers) { ($allGroupMembers | Measure-Object).Count } else { 0 }

        # Display the group information to the console.
        Write-Host "Processing Group: '$($group.Name)'" -ForegroundColor Cyan
        Write-Host " - Type: $groupType"
        Write-Host " - Total User Members (including nested): $userMemberCount"
        
        # If the group has user members, retrieve their details.
        if ($userMemberCount -gt 0) {
            $members = $allGroupMembers | Get-ADUser -Properties SamaccountName, GivenName, SurName, EmailAddress, DisplayName, Office, Department, Company @adParams

            # Format the member data, adding a 'GroupName' column.
            $memberData = $members | Select-Object -Property `
                @{Name = "GroupName"; Expression = { $group.Name }}, `
                SamAccountName, `
                @{Name = "FirstName"; Expression = { $_.GivenName }}, `
                @{Name = "LastName"; Expression = { $_.SurName }}, `
                @{Name = "PrimaryEmailAddress"; Expression = { $_.EmailAddress }}, `
                @{Name = "Display"; Expression = { $_.DisplayName }}, `
                Office, `
                Department, `
                Company
            
            $allMembers += $memberData
        }
        Write-Host "----------------------------------------"
    }
    catch {
        Write-Warning "Could not process group '$groupName'. Please ensure the group name is correct."
        Write-Warning "Error details: $($_.Exception.Message)"
        Write-Host "----------------------------------------"
    }
}

# Step 5: Sort, Number, and Export Data to CSV
if ($allMembers.Count -gt 0) {
    try {
        # Sort the collected members first by GroupName, then by LastName.
        $sortedMembers = $allMembers | Sort-Object -Property GroupName, LastName

        # Loop through the sorted list to build the final report, resetting the counter for each new group.
        $reportData = @()
        $groupCounter = 1
        $currentGroupName = $sortedMembers[0].GroupName

        foreach ($member in $sortedMembers) {
            # Check if the group name has changed.
            if ($member.GroupName -ne $currentGroupName) {
                $groupCounter = 1 # Reset the counter.
                $currentGroupName = $member.GroupName # Update the current group name.
            }

            $reportData += [PSCustomObject]@{
                "No."                 = $groupCounter # Use the per-group counter.
                "GroupName"           = $member.GroupName
                "SamAccountName"      = $member.SamAccountName
                "FirstName"           = $member.FirstName
                "LastName"            = $member.LastName
                "PrimaryEmailAddress" = $member.PrimaryEmailAddress
                "Display"             = $member.Display
                "Office"              = $member.Office
                "Department"          = $member.Department
                "Company"             = $member.Company
            }
            $groupCounter++ # Increment the counter for the next user.
        }

        # Export the final, correctly numbered and sorted data to CSV.
        $reportData | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        
        Write-Host "Success! Report has been generated at: $csvFilePath" -ForegroundColor Green
        Write-Host "Total members exported: $($reportData.Count)"

        # --- STEP 6: RETURN PATH (UPLOAD TO AZURE BLOB STORAGE) ---
        $storageContainer = "reports"
        $connectionString = $env:AZURE_STORAGE_CONNECTION_STRING

        if ($connectionString) {
            Write-Host "Uploading report to Azure Blob Storage..." -ForegroundColor Cyan
            try {
                $blobName = Split-Path $csvFilePath -Leaf
                az storage blob upload --container-name $storageContainer --file $csvFilePath --name $blobName --connection-string $connectionString --overwrite
                Write-Host "Successfully uploaded to Azure: $blobName" -ForegroundColor Green

                # --- STEP 7: STATUS UPDATE ---
                Update-RequestStatus -status "Completed" -message "Report generated and uploaded! You can download it below."

                # --- STEP 8: EMAIL NOTIFICATION ---
                $SendNotification = $true # Set to $false to disable
                $NotificationEmail = "kangah@nih.gov"
                $SMTPServer = "YOUR_SMTP_SERVER_HERE" # e.g., "smtp.nih.gov"

                if ($SendNotification -and $SMTPServer -ne "YOUR_SMTP_SERVER_HERE") {
                    Write-Host "Sending email notification to $NotificationEmail..." -ForegroundColor Cyan
                    try {
                        $subject = "AD Group Member Retrieval Complete: $blobName"
                        $body = "The AD group member retrieval process is complete. <br><br><b>Filename:</b> $blobName<br><b>Total Members:</b> $($reportData.Count)<br><br>You can download the report from the web portal."
                        
                        Send-MailMessage -To $NotificationEmail `
                                         -From "AD-Automation@nih.gov" `
                                         -Subject $subject `
                                         -Body $body `
                                         -BodyAsHtml `
                                         -SmtpServer $SMTPServer `
                                         -ErrorAction Stop
                        Write-Host "Notification sent successfully." -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "Failed to send email notification. Error: $($_.Exception.Message)"
                    }
                }
                elseif ($SendNotification) {
                    Write-Host "Email notification skipped: SMTP Server not configured." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Warning "Failed to upload to Azure Blob Storage. Error: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "AZURE_STORAGE_CONNECTION_STRING not found. Skipping Azure upload."
        }
    }
    catch {
        Write-Error "Failed to export data to CSV. Please check permissions for the path: $csvFilePath"
        Update-RequestStatus -status "Failed" -message "Error exporting CSV: $($_.Exception.Message)"
    }
}
else {
    Write-Host "No members were found in the specified groups, or all group names were invalid."
    Update-RequestStatus -status "Completed" -message "Process finished, but no members were found in the requested groups."
}
