#Requires -RunAsAdministrator



# This will use the System logs to show data about the last few startups [12], shutdowns [13], and restarts [27].

$BootEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    Id      = 12, 13, 27
} -MaxEvents 15 -ErrorAction SilentlyContinue

if (-not $BootEvents) {
    Write-Warning "No boot lifecycle events found in the System log."
    Exit
}

$BootEvents | ForEach-Object {
    $Message = $_.Message
    $BootType = "Unknown"
    
    # Parse the boot type if it's Event 27
    if ($_.Id -eq 27 -and $Message -match "0x([0-9a-fA-F]+)") {
        $Hex = $Matches[1]
        if ($Hex -eq "0") { $BootType = "Cold Boot (Clean)" }
        elseif ($Hex -eq "1") { $BootType = "Hybrid Boot (Fast Startup)" }
    }

    [PSCustomObject]@{
        Timestamp   = $_.TimeCreated
        EventID     = $_.Id
        Description = if ($_.Id -eq 12) { "Kernel Initialization / LSASS Start" } 
        elseif ($_.Id -eq 13) { "Clean System Shutdown" } 
        else { "Boot Type Detected: $BootType" }
        Message     = $_.Message
    }
} | Format-Table -AutoSize


# This will show if the Security log was cleared recently, which is often done during a shutdown or restart.  This can be an indicator of a "clean" shutdown, but it can also be used by attackers to cover their tracks.
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id      = 1102
} -ErrorAction SilentlyContinue |
Select-Object TimeCreated, Id, Message | Format-Table -Wrap


# DPS Service needs to be running for further analysis of startup performance. 
Get-Service DPS

# Bad if it says Stopped
# Status   Name               DisplayName
# ------   ----               -----------
# Stopped  DPS                Diagnostic Policy Service



# Optimize-StartupPaths.ps1
Write-Host "=== Auditing Non-Microsoft Automatic Services ===" -ForegroundColor Cyan

# Grabs third-party services that start early instead of waiting for post-boot idle
Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto' and Started = true" | 
Where-Object { $_.PathName -notmatch "Windows|System32" } | 
Select-Object Name, DisplayName, PathName | 
Format-Table -AutoSize

Write-Host "=== Auditing Logon-Triggered Scheduled Tasks ===" -ForegroundColor Cyan

# Pulls tasks that fire immediately when you log into the desktop
Get-ScheduledTask | Where-Object { $_.Triggers.ValueQueries -match "Logon" } | 
Select-Object TaskName, TaskPath, State | 
Format-Table -AutoSize




# Get-WinEvent -ListLog "Microsoft-Windows-Diagnostics-Performance/Operational" | Select-Object MaximumSizeInBytes, LogMode, IsLogFull, FilePath

# MaximumSizeInBytes  LogMode IsLogFull FilePath
# ------------------  ------- --------- --------
#            1052672 Circular     False


# With DPS running we should be able to run
# Query the most recent Boot Performance summary
# $BootEvents = Get-WinEvent -FilterHashtable @{
#     LogName = "Microsoft-Windows-Diagnostics-Performance/Operational"
#     Id      = 100
# } -MaxEvents 5 -ErrorAction SilentlyContinue

# foreach ($Event in $BootEvents) {
#     $Data = [xml]$Event.ToXml()
#     # Pulling specific properties from the object without raw XML statements
#     $BootTime = ($Data.Event.EventData.Data | Where-Object Name -eq "BootTime").'#text'
#     $MainPath = ($Data.Event.EventData.Data | Where-Object Name -eq "MainPathBootTime").'#text'
    
#     Write-Host "--- Boot Record: $($Event.TimeCreated) ---" -ForegroundColor Yellow
#     Write-Host "Total Boot Time: $([math]::Round($BootTime / 1000, 2)) seconds"
#     Write-Host "Main Kernel Path: $([math]::Round($MainPath / 1000, 2)) seconds"
#     Write-Host ""
# }

# Note: The "Startup Impact" data is not easily accessible via PowerShell or the Event Logs.  It is calculated by Windows based on the startup time of each application and its impact on the overall boot time.  This data is typically displayed in the Task Manager under the "Startup" tab, but it is not exposed through standard APIs or logs.  To get this data, you would need to use a tool like Process Monitor to capture the startup process and analyze the timings of each application, which is beyond the scope of a simple PowerShell script. To get a rough idea of startup impact, you can look at the "StartupApproved" registry keys under HKCU and HKLM, which show which applications are enabled for startup and their approval status, but this won't give you the actual impact on boot time.
# Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" | 
# Select-Object Name, Property, @{n="Value";e={(Get-ItemProperty $_.PSPath).$($_.Name)}}





# Get-WinEvent: To access the 'Microsoft-Windows-Diagnostics-Performance/Operational' log start PowerShell with elevated user rights.  Error: Attempted to perform an unauthorized operation.
# Get-WinEvent: There is not an event log on the localhost computer that matches "Microsoft-Windows-Diagnostics-Performance/Operational".




# Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Diagnostics-Performance/Operational" -ErrorAction SilentlyContinue | Select-Object Enabled, Isolation, Type

# Enabled Isolation Type
# ------- --------- ----
#       1         1    1








# Set the max size to 50MB to ensure we don't lose data
# Limit-EventLog -LogName "Microsoft-Windows-Diagnostics-Performance/Operational" -MaximumSize 50MB





# Disable and re-enable the channel to reset the ETW session
# wevtutil sl "Microsoft-Windows-Diagnostics-Performance/Operational" /e:false
# wevtutil sl "Microsoft-Windows-Diagnostics-Performance/Operational" /e:true



# Identify "Startup Impact" via Registry (The Manual Audit)
# Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" | 
# Select-Object Name, Property, @{n="Value";e={(Get-ItemProperty $_.PSPath).$($_.Name)}}





# This sets up a boot trace to be captured on the next restart
# wpr -boottrace -addprofile GeneralProfile -filecount 1 -overwrite
# Then we can run this command to stop the trace and save the file to the desktop
# wpr -boottrace -stopboot %userprofile%\Desktop\BootTrace.etl

