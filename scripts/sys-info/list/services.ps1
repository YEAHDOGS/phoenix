param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Services.csv"
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


# Query all services, select relevant properties, and filter out those without a name
Get-Service | 
Select-Object Name, DisplayName, Status, StartType | 
Where-Object { $_.DisplayName -ne $null } | 
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Service audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Installed Services"
}