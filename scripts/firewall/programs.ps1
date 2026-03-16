# -------- ALLOW PROGRAMS --------

# Windows Time Service
New-NetFirewallRule -DisplayName "ALLOW-win-time" `
    -Direction Outbound `
    -Program "%SystemRoot%\System32\svchost.exe" `
    -Protocol UDP `
    -LocalPort 123 `
    -Action Allow

# Chrome
New-NetFirewallRule -DisplayName "ALLOW-chrome" `
    -Direction Outbound `
    -Program "%ProgramFiles%\Google\Chrome\Application\chrome.exe" `
    -Action Allow

# Steam and steamwebhelper
New-NetFirewallRule -DisplayName "ALLOW-steam" `
    -Direction Outbound `
    -Program "%ProgramFiles(x86)%\Steam\steam.exe" `
    -Action Allow
New-NetFirewallRule -DisplayName "ALLOW-steamwebhelper" `
    -Direction Outbound `
    -Program "%ProgramFiles(x86)%\Steam\bin\cef\cef.win64\steamwebhelper.exe" `
    -Action Allow

# EA App (Manually add connect MS, when installing EA App the others will be added automatically)
New-NetFirewallRule -DisplayName "ALLOW-eaapp" `
    -Direction Outbound `
    -Program "%ProgramFiles%\Electronic Arts\EA Desktop\EA Desktop\EAConnect_microsoft.exe" `
    -Action Allow


# -------- BLOCK PROGRAMS --------

# Microsoft Paint, it's a shame I need to block this but the world is on fire and Microsoft hates people
New-NetFirewallRule -DisplayName "BLOCK-mspaint" -Direction Outbound -Program "%ProgramFiles%\WindowsApps\Microsoft.Paint_11.2601.401.0_x64__8wekyb3d8bbwe\PaintApp\mspaint.exe" -Action Block

# Microsoft Notepad
# ...
# ...I mean hopefully god sends the rapture soon
New-NetFirewallRule -DisplayName "BLOCK-notepad" -Direction Outbound -Program "%ProgramFiles%\WindowsApps\Microsoft.WindowsNotepad_11.2512.26.0_x64__8wekyb3d8bbwe\Notepad\Notepad.exe" -Action Block