param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Tasks.csv"
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


Get-ScheduledTask | Sort-Object TaskName | ForEach-Object {
    [PSCustomObject]@{
        TaskName = $_.TaskName
        Path     = $_.TaskPath
        State    = $_.State
        # Shows the command being executed
        Action   = ($_.Actions.Execute + " " + $_.Actions.Arguments)
        # Shows the account the task runs under
        RunAs    = $_.Principal.UserId
        # Shows the last time this task actually triggered
        LastRun  = (Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath).LastRunTime
    }
} | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Scheduled Tasks audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Scheduled Tasks"
}