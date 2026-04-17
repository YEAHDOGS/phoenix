# List COM objects from the registry and export to CSV. COM Objects are like app dependencies. They can be used by multiple applications, and if they are vulnerable, they can be exploited by any application that uses them. If anything bad gets installed here, anything can use it.
param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = ".\Sys-Com.csv"

Get-ChildItem HKLM:\Software\Classes -ErrorAction SilentlyContinue | 
Where-Object { $_.PSChildName -match '^\w+\.\w+$' } | 
Select-Object PSChildName |
Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "COM Object audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "COM Objects"
}