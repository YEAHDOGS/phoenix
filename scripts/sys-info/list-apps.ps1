$Paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
Get-ItemProperty $Paths | Select-Object DisplayName, DisplayVersion | Where-Object { $_.DisplayName -ne $null }
| Export-Csv -Path ".\Registry_Apps.csv" -NoTypeInformation