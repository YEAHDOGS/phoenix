# This lists out all .exe files that can run when using Start-Process "example.exe" from powershell. If it's listed here, the command line can quickly run it.

param (
    [Alias("t")]
    [switch]$TableView
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Path"

$env:Path.Split(';') |
Get-ChildItem -Filter *.exe -ErrorAction SilentlyContinue |
Select-Object Name, Directory  |
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Path variable audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Sort-Object Directory | Out-GridView -Title "PATH Variable Executables"
}