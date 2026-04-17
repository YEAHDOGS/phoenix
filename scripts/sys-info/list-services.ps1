param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = ".\Sys-Services.csv"

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