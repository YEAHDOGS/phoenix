$AuditMenu = [ordered]@{
    "All"                            = { . "$PSScriptRoot/list/all.ps1" }
    "Devices"                        = { . "$PSScriptRoot/list/devices.ps1" }
    "Drivers"                        = { . "$PSScriptRoot/list/drivers.ps1" }
    "Drivers with Store"             = { . "$PSScriptRoot/list/driver-store.ps1" }
    "Programs"                       = { . "$PSScriptRoot/list/programs.ps1" -t }
    "Services"                       = { . "$PSScriptRoot/list/services.ps1" -t }
    "Scheduled Tasks"                = { . "$PSScriptRoot/list/tasks.ps1" -t }
    "AppX"                           = { . "$PSScriptRoot/list/appx.ps1" -t }
    "COM"                            = { . "$PSScriptRoot/list/com.ps1" -t }
    "Users"                          = { . "$PSScriptRoot/list/users.ps1" -t }
    "WMI"                            = { . "$PSScriptRoot/list/wmi/wmi.ps1" -t }
    "Filters"                        = { . "$PSScriptRoot/list/filters.ps1" -t }
    "Pipes"                          = { . "$PSScriptRoot/list/pipes.ps1" -t }
    "Hosts"                          = { . "$PSScriptRoot/list/hosts.ps1" }
    "ENV Vars"                       = { . "$PSScriptRoot/list/envs.ps1" }
    "Path Vars"                      = { . "$PSScriptRoot/list/path.ps1" -t }
    "UEFI BIOS Vars"                 = { . "$PSScriptRoot/list/UEFI.ps1" }
    "Browser Native Messaging Hosts" = { . "$PSScriptRoot/list/messaging-hosts.ps1" -t }
}

$title = "System Information"
$message = "Select a category:"

$UsedKeys = @()
$NextNumber = 0

$choices = foreach ($key in $AuditMenu.Keys) {
    $found = $false
    
    # 1. Primary Attempt: Find a unique letter INSIDE the name
    for ($charIndex = 0; $charIndex -lt $key.Length; $charIndex++) {
        $char = $key[$charIndex].ToString().ToLower()
        # Filter for alphanumeric only to avoid ampersanding spaces
        if ($char -match '[a-z]' -and $UsedKeys -notcontains $char) {
            $UsedKeys += $char
            $label = $key.Insert($charIndex, "&")
            $found = $true
            break
        }
    }

    # 2. Secondary Fallback: If no unique letter, use a Number (0-9)
    if (-not $found) {
        while ($UsedKeys -contains $NextNumber.ToString() -and $NextNumber -le 9) {
            $NextNumber++
        }

        if ($NextNumber -le 9) {
            $label = "&$NextNumber. $key"
            $UsedKeys += $NextNumber.ToString()
            $found = $true
        }
        else {
            # 3. Final Fail-safe: Use the first available symbol or letter
            $label = $key # At this point, you have > 36 menu items!
        }
    }
    
    New-Object System.Management.Automation.Host.ChoiceDescription $label, ""
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