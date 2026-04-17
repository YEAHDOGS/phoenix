param (
    [Alias("t")]
    [switch]$TableView
)

#Requires -RunAsAdministrator

# I fucking hate filters

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Filters.csv"
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

$rawOutput = fltmc filters | Select-Object -Skip 3

$results = foreach ($line in $rawOutput) {
    # Split by whitespace
    $parts = $line -split '\s{1,}'

    if ($parts.Count -ge 3) {
        [PSCustomObject]@{
            FilterName = $parts[0].Trim()
            Instances  = $parts[1].Trim()
            Altitude   = $parts[2].Trim()
            Frame      = $parts[3].Trim()
        }
    }
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Filters"
}