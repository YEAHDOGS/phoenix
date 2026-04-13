$ExportPath = ".\Sys-Programs.csv"

$Paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
Get-ItemProperty $Paths | Select-Object DisplayName, DisplayVersion | Where-Object { $_.DisplayName -ne $null }
| Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "Programs audit exported to $ExportPath" -ForegroundColor Cyan