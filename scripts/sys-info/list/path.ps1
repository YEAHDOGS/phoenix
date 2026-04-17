# This lists out all .exe files that can run when using Start-Process "example.exe" from powershell. If it's listed here, the command line can quickly run it.

param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Path.csv"
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


$env:Path.Split(';') |
Get-ChildItem -Filter *.exe -ErrorAction SilentlyContinue |
Select-Object Name, Directory  |
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Path variable audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Sort-Object Directory | Out-GridView -Title "PATH Variable Executables"
}