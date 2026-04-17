param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Programs.csv"
$BackupFolder = Join-Path (Split-Path $PSScriptRoot -Parent) "data-backup"

if (Test-Path $ExportPath) {
    # Ensure backup directory exists
    if (-not (Test-Path $BackupFolder)) { 
        New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null 
    }

    # Create timestamp (e.g., 20260417-1655)
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FileName = Split-Path $ExportPath -Leaf
    $BackupPath = Join-Path $BackupFolder "$Timestamp-$FileName"

    # Move and rename
    Move-Item -Path $ExportPath -Destination $BackupPath -Force
    Write-Host "[!] Existing audit archived to: $BackupPath" -ForegroundColor Gray
}


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