# WMI Event Consumers are like scripts or programs that run when certain events happen. They can be used for good, but if something bad gets installed here, it can run whenever the right event happens.

# SCM Event Log Consumer with SCM Event Log Filter and their binding should be ok... i think idk anything anymore. If theres anything more listed you probably hacked

# Get-WMIObject -Namespace root\subscription -Class __EventConsumer

param (
    [Alias("t")]
    [switch]$TableView
)

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-WMIEvents.csv"

if (Test-Path $ExportPath) { Remove-Item $ExportPath -Force }

# Define the classes to audit
$WmiClasses = @("__EventConsumer", "__EventFilter", "__FilterToConsumerBinding")

$WmiClasses | ForEach-Object {
    $ClassName = $_
    # Query each class and add a 'Type' property for easy filtering in Excel/CSV
    Get-CimInstance -Namespace root\subscription -ClassName $ClassName -ErrorAction SilentlyContinue |
    Select-Object @{Name = "WmiType"; Expression = { $ClassName } }, Name, Query, Consumer, Filter, ExecutablePath, CommandLineTemplate |
    # We use -Append so all three queries land in the same file
    Export-Csv -Path $ExportPath -NoTypeInformation -Append
}

Write-Host "WMI Subscription audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "WMI Subscriptions"
}