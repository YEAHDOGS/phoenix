# Your list of categories with embedded hotkeys
$categories = @("&All", "&Drivers", "D&rivers with Store", "&Programs", "&Services", "Scheduled&Tasks", "App&X", "&COM", "&Users", "&WMI", "&ENV Vars", "&Filters", "&Hosts", "Path&Vars", "UEFI&BIOSVars")

$title = "System Investigation"
$message = "Select a category to audit (Use Arrow Keys or Hotkeys):"

# Build choices using the existing ampersands in your strings
$choices = foreach ($item in $categories) {
    New-Object System.Management.Automation.Host.ChoiceDescription $item, ""
}

# Prompt the user
$result = $Host.UI.PromptForChoice($title, $message, $choices, 0)

if ($result -ge 0) {
    # Get the raw string and strip the '&' so the switch case matches correctly
    $selection = $categories[$result].Replace('&', '')
    Write-Host "`n[+] You chose: $selection" -ForegroundColor Cyan
    
    switch ($selection) {
        "All" { . ./list/all.ps1 }
        "Drivers" { . ./list/drivers.ps1 }
        "Drivers with Store" { . ./list/driver-store.ps1 }
        "Programs" { . ./list/programs.ps1 -t }
        "Services" { . ./list/services.ps1 -t }
        "ScheduledTasks" { . ./list/tasks.ps1 -t }
        "AppX" { . ./list/appx.ps1 -t }
        "COM" { . ./list/com.ps1 -t }
        "Users" { . ./list/users.ps1 -t }
        "WMI" { . ./list/wmi.ps1 -t }
        "ENV Vars" { . ./list/env-vars.ps1 }
        "Filters" { . ./list/filters.ps1 -t }
        "Hosts" { . ./list/hosts.ps1 }
        "PathVars" { . ./list/path.ps1 -t }
        "UEFIBIOSVars" { . ./list/UEFI.ps1 }
        Default { . ./list/all.ps1 }
    }
}
else {
    Write-Host "`nCya later alligator" -ForegroundColor Yellow
}