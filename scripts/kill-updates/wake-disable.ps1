# 1. DISABLE DRIVER SEARCHING & OEM INJECTION
# Prevents Windows from looking at Microsoft/HP servers for new .inf files.
$DriverKeys = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings"
)
foreach ($key in $DriverKeys) { if (!(Test-Path $key)) { New-Item -Path $key -Force } }

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "SearchOrderConfig" -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings" -Name "InstallInternalDriversOnly" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" -Name "SearchOrderConfig" -Value 0 -Type DWord

# 2. KILL MODERN STANDBY NETWORK CONNECTIVITY
# This ensures that when the lid is closed, the Wi-Fi card (\Device\NDMP1) is physically powered down.
$PowerGuid = "1e84c20b-08d9-436f-827d-531b402771d0"
$SettingGuid = "75ed186e-0434-4753-a178-040000000000"
reg add "HKLM\System\CurrentControlSet\Control\Power\PowerSettings\$PowerGuid\$SettingGuid" /v Attributes /t REG_DWORD /d 2 /f
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE $SettingGuid 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE $SettingGuid 0
powercfg /setactive SCHEME_CURRENT

# 3. DISABLE WAKE TIMERS (GLOBAL OVERRIDE)
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 0

# 4. AGGRESSIVE TASK DISABLING (ORCHESTRATOR & MAINTENANCE)
$Tasks = @(
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Wake To Work",
    "\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Idle Start",
    "\Microsoft\Windows\UpdateOrchestrator\Reboot_AC",
    "\Microsoft\Windows\WindowsUpdate\Scheduled Start",
    "\Microsoft\Windows\TaskScheduler\Regular Maintenance"
)

foreach ($taskPath in $Tasks) {
    Write-Host "Disabling Task: $taskPath" -ForegroundColor Cyan
    # Disabling the task and stripping 'WakeToRun' privilege
    Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue | Disable-ScheduledTask
    # Attempting to strip the 'Wake to Run' setting specifically
    $t = Get-ScheduledTask -TaskName ($taskPath -split '\\')[-1] -ErrorAction SilentlyContinue
    if ($t) {
        $t.Settings.WakeToRun = $false
        Set-ScheduledTask -InputObject $t
    }
}

# 5. BLOCK UPDATE ORCHESTRATOR VIA FIREWALL
# The "Nuclear" option: prevent the update client from reaching the internet.
New-NetFirewallRule -DisplayName "BLOCK_USO_CLIENT_OUT" -Direction Outbound -Program "%systemroot%\system32\usoclient.exe" -Action Block
New-NetFirewallRule -DisplayName "BLOCK_WUA_MGR_OUT" -Direction Outbound -Program "%systemroot%\system32\wuauclt.exe" -Action Block

Write-Host "Hardening Applied. Restart required to lock kernel handles." -ForegroundColor Green