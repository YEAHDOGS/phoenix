Write-Host "Checking for WMI Persistence mechanisms..." -ForegroundColor Yellow

Get-WmiObject -Namespace root\subscription -Class __EventFilter | 
Select-Object Name, Query | 
Format-List

Get-WmiObject -Namespace root\subscription -Class __EventConsumer | 
Select-Object Name, @{N = 'Command'; E = { $_.CommandLineTemplate } } | 
Format-List