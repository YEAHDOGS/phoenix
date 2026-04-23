$AuditMenu = [ordered]@{
    "&All"                            = { . "$PSScriptRoot/list/all.ps1" }
    "&Devices"                        = { . "$PSScriptRoot/list/devices.ps1" }
    "D&rivers"                        = { . "$PSScriptRoot/list/drivers.ps1" }
    "Dr&ivers with Store"             = { . "$PSScriptRoot/list/driver-store.ps1" }
    "&Programs"                       = { . "$PSScriptRoot/list/programs.ps1" -t }
    "&Services"                       = { . "$PSScriptRoot/list/services.ps1" -t }
    "Scheduled&Tasks"                 = { . "$PSScriptRoot/list/tasks.ps1" -t }
    "App&X"                           = { . "$PSScriptRoot/list/appx.ps1" -t }
    "&COM"                            = { . "$PSScriptRoot/list/com.ps1" -t }
    "&Users"                          = { . "$PSScriptRoot/list/users.ps1" -t }
    "&WMI"                            = { . "$PSScriptRoot/list/wmi.ps1" -t }
    "&Filters"                        = { . "$PSScriptRoot/list/filters.ps1" -t }
    "&Hosts"                          = { . "$PSScriptRoot/list/hosts.ps1" }
    "&ENV Vars"                       = { . "$PSScriptRoot/list/envs.ps1" }
    "Path &Vars"                      = { . "$PSScriptRoot/list/path.ps1" -t }
    "UEFI&BIOSVars"                   = { . "$PSScriptRoot/list/UEFI.ps1" }
    "Browser Native &Messaging Hosts" = { . "$PSScriptRoot/list/messaging-hosts.ps1" -t }
}

$title = "System Information"
$message = "Select a category to audit:"

$choices = foreach ($key in $AuditMenu.Keys) {
    New-Object System.Management.Automation.Host.ChoiceDescription $key, ""
}

$result = $Host.UI.PromptForChoice($title, $message, $choices, 0)

if ($result -ge 0) {
    $selectionName = ($AuditMenu.Keys)[$result]
    $action = $AuditMenu[$selectionName]

    Write-Host "`n[+] Executing: $($selectionName.Replace('&',''))" -ForegroundColor Cyan
    
    Invoke-Command -ScriptBlock $action
}
else {
    Write-Host "`nCya later alligator" -ForegroundColor Yellow
}