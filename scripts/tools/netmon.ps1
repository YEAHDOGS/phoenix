$esc = [char]27
$moveToTop = "$esc[H"
$hideCursor = "$esc[?25l"
$showCursor = "$esc[?25h"

# Stores our history: @{ "IP" = "FirstSeenTime" }
$script:LocalHistory = @{}

Clear-Host
Write-Host $hideCursor 

$script:clearCounter = 0  # Define it at the very top of the file

try {
    while($true) {
        Write-Host -NoNewline $moveToTop
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Write-Host "--- LIVE NETWORK MONITOR ---" -ForegroundColor Cyan
        Write-Host ("Last Update: $timestamp" + (" " * 20)) -ForegroundColor Yellow
        Write-Host ("-" * 60 + (" " * 20))

        # 1. Get and filter connections (Unique entries only to prevent spam)
        $allConnections = Get-NetTCPConnection -State Established | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess -Unique

        # --- EXTERNAL SECTION ---
        Write-Host "[!] EXTERNAL CONNECTIONS (WORLD)" -ForegroundColor Red
        $external = $allConnections | Where-Object { $_.RemoteAddress -notlike "192.168.*" -and $_.RemoteAddress -ne "127.0.0.1" -and $_.RemoteAddress -ne "::1" -and $_.RemoteAddress -ne "0.0.0.0" }
        
        if ($external) {
            $extData = $external | Select-Object RemoteAddress, RemotePort, OwningProcess,
                @{Name="Process";Expression={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} | 
                Format-Table -AutoSize | Out-String
            # Print each line of the table with padding to wipe old text
            $extData.Split("`n") | ForEach-Object { Write-Host ($_.TrimEnd() + (" " * 30)) }
        } else { Write-Host ("No active external connections." + (" " * 30)) }

        Write-Host ("`n" + (" " * 80)) # Gap

        # --- LOCAL SECTION ---
        Write-Host "[+] LOCAL NETWORK DEVICES (LAN)" -ForegroundColor Green
        
        $currentLocal = $allConnections | Where-Object { $_.RemoteAddress -like "192.168.*" -or $_.RemoteAddress -like "127.0.0.1" -or $_.RemoteAddress -like "::1" -or $_.RemoteAddress -like "0.0.0.0" }
        $activeIPs = $currentLocal.RemoteAddress | Select-Object -Unique

        foreach ($ip in $activeIPs) {
            if (-not $script:LocalHistory.ContainsKey($ip)) {
                $script:LocalHistory[$ip] = Get-Date -Format "HH:mm:ss"
            }
        }

        $localDisplay = foreach ($ipKey in $script:LocalHistory.Keys) {
            $isActive = $activeIPs -contains $ipKey
            $status = if ($isActive) { "[v] ACTIVE" } else { "[X] GONE  " }
            
            $procName = "N/A"
            if ($isActive) {
                $match = $currentLocal | Where-Object { $_.RemoteAddress -eq $ipKey } | Select-Object -First 1
                $procName = (Get-Process -Id $match.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            }

            [PSCustomObject]@{
                Status      = $status
                RemoteIP    = $ipKey
                FirstSeen   = $script:LocalHistory[$ipKey]
                LastProcess = $procName
            }
        }

        if ($localDisplay) {
            $locData = $localDisplay | Sort-Object Status -Descending | Format-Table -AutoSize | Out-String
            $locData.Split("`n") | ForEach-Object { Write-Host ($_.TrimEnd() + (" " * 30)) }
        } else { Write-Host ("No local devices detected." + (" " * 30)) }
        
        # Clean up any residual lines at the bottom
        for ($i = 0; $i -lt 5; $i++) { Write-Host (" " * 100) }
        
        Start-Sleep -Milliseconds 300

        # Clear screen every dozen or so times, will produce flicker... argh
        $script:clearCounter++
        if ($script:clearCounter -gt 10) {
            Clear-Host
            Write-Host "$esc[?25l"
            $script:clearCounter = 0
        }
    }
}
finally {
    Write-Host $showCursor
}