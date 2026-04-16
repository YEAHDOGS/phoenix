# WMI Event Consumers are like scripts or programs that run when certain events happen. They can be used for good, but if something bad gets installed here, it can run whenever the right event happens.

# SCM Event Log Consumer with SCM Event Log Filter and its binding should be good...

# Get-WMIObject -Namespace root\subscription -Class __EventConsumer

Write-Host "Listing WMI Event Consumers, Filters, and Bindings..." -ForegroundColor Cyan

Write-Host "WMI Event Consumers: " -ForegroundColor Yellow
Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer
Write-Host "WMI Event Filters: " -ForegroundColor Yellow
Get-CimInstance -Namespace root\subscription -ClassName __EventFilter

Write-Host "WMI Event Consumer Bindings (Binds two from the above lists together): " -ForegroundColor Yellow
Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding