# This lists out all .exe files that can run when using Start-Process "example.exe" from powershell. If it's listed here, the command line can quickly run it.

$ExportPath = ".\Sys-Path.csv"

$env:Path.Split(';') |
Get-ChildItem -Filter *.exe -ErrorAction SilentlyContinue |
Select-Object Name, Directory  |
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Path variable audit exported to $ExportPath" -ForegroundColor Cyan