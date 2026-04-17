param (
    [Alias("t")]
    [switch]$TableView
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "ScheduledTasks"

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