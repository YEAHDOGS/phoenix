param (
    [Alias("t")]
    [switch]$TableView
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Programs"

$Paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

# Fetching properties and formatting the date
$Programs = Get-ItemProperty $Paths | Where-Object { $null -ne $_.DisplayName } | Select-Object `
    DisplayName, 
DisplayVersion, 
@{Name = "InstallDate"; Expression = {
        if ($_.InstallDate) {
            $_.InstallDate.Insert(4, '-').Insert(7, '-')
        }
        else {
            "Unknown"
        }
    }
}

# Export to CSV
$Programs | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Programs audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Installed Programs"
}