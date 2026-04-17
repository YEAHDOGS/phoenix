# List COM objects from the registry and export to CSV. COM Objects are like app dependencies. They can be used by multiple applications, and if they are vulnerable, they can be exploited by any application that uses them. If anything bad gets installed here, anything can use it.
param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Com.csv"
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

Get-ChildItem HKLM:\Software\Classes -ErrorAction SilentlyContinue | 
Where-Object { $_.PSChildName -match '^\w+\.\w+$' } | 
Select-Object PSChildName |
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "COM Object audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "COM Objects"
}