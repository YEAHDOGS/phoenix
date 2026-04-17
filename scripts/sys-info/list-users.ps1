param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = ".\Sys-Users.csv"

# Get all local users
$AllUsers = Get-LocalUser

$Report = foreach ($User in $AllUsers) {
    # Find all local groups this specific user is a member of
    $Groups = (Get-LocalGroup | Where-Object {
            try {
                Get-LocalGroupMember -Group $_.Name -ErrorAction SilentlyContinue | 
                Where-Object { $_.SID -eq $User.SID }
            }
            catch { $null }
        }).Name -join " | "

    [PSCustomObject]@{
        UserName         = $User.Name
        Enabled          = $User.Enabled
        Groups           = $Groups
        Description      = $User.Description
        PasswordLastSet  = $User.PasswordLastSet
        LastLogon        = $User.LastLogon
        SID              = $User.SID
        AccountExpires   = $User.AccountExpires
        PasswordRequired = $User.PasswordRequired
    }
}

# Export to CSV in the current directory
$Report | Sort-Object Enabled, UserName | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Users audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Users"
}