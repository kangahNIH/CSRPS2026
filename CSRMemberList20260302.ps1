# Requires -Module ActiveDirectory

# Step 0: Initial Setup
# Check if the Active Directory module is available. If not, the script will stop.
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "The Active Directory module is not installed on this system. Please install the Remote Server Administration Tools (RSAT) for Active Directory."
    exit
}
Import-Module ActiveDirectory

# Create the directory for the report if it doesn't already exist.
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


# Step 1: Handle Credentials
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

# Step 2: Get Group Names from User
$groupNamesInput = Read-Host "Enter the AD group names, separated by a comma (,)"
if ([string]::IsNullOrWhiteSpace($groupNamesInput)) {
    Write-Warning "No group names were entered. Exiting script."
    exit
}
$groupNames = $groupNamesInput.Split(',') | ForEach-Object { $_.Trim() }

# Initialize an array to hold all member data.
$allMembers = @()
Write-Host "" # Add a blank line for better readability.

# Step 3: Process Each Group
foreach ($groupName in $groupNames) {
    if ([string]::IsNullOrWhiteSpace($groupName)) { continue } # Skip empty entries

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
        Write-Host "Processing Group: '$($group.Name)'" -ForegroundColor Green
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

# Step 4: Sort, Number, and Export Data to CSV
if ($allMembers.Count -gt 0) {
    try {
        # === FINAL CORRECTED LOGIC ===
        # 1. Sort the collected members first by GroupName, then by LastName.
        $sortedMembers = $allMembers | Sort-Object -Property GroupName, LastName

        # 2. Loop through the sorted list to build the final report, resetting the counter for each new group.
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

        # 3. Export the final, correctly numbered and sorted data to CSV.
        $reportData | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        
        Write-Host "Success! Report has been generated at: $csvFilePath" -ForegroundColor Cyan
        Write-Host "Total members exported: $($reportData.Count)"
    }
    catch {
        Write-Error "Failed to export data to CSV. Please check permissions for the path: $csvFilePath"
    }
}
else {
    Write-Host "No members were found in the specified groups, or all group names were invalid."
}
