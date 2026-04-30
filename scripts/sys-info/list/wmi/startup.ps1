Write-Host "`n--- AUDITING WMI PERSISTENCE (Hidden Startups) ---" -ForegroundColor Cyan
$Consumers = Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer
foreach ($C in $Consumers) {
    [PSCustomObject]@{
        Name    = $C.Name
        Type    = $C.CimClass.CimClassName
        Details = if ($C.CommandLineTemplate) { $C.CommandLineTemplate } else { $C.ScriptText }
    } | Format-Table -AutoSize
}