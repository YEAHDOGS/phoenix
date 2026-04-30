# --- CONFIGURATION ---
$BaselinePath = "C:\Windows\System32"
$WinSxSPath = "C:\Windows\WinSxS"
$ProgramFiles = "C:\Program Files"

# 1. DETECTION: Compare standard process list vs WMI (The Ghost Check)
$standardProcs = (Get-Process).Id
$wmiProcs = (Get-CimInstance Win32_Process).ProcessId

$hidden = $wmiProcs | Where-Object { $standardProcs -notcontains $_ }

if ($hidden) {
    Write-Host "[!] ALERT: Found potential hidden processes (PID): $hidden" -ForegroundColor Red -BackgroundColor Black
    Write-Host "Starting deep-dive forensic analysis..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    foreach ($pidNum in $hidden) {
        # 2. EXTRACT METADATA via CIM/WMI
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pidNum"
        
        if ($proc) {
            $ownerInfo = Invoke-CimMethod -InputObject $proc -MethodName GetOwner
            $user = if ($ownerInfo.User) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { "UNKNOWN (Potentially Hollowed)" }

            # 3. GET PARENT PROCESS INFO
            $parentPID = $proc.ParentProcessId
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $parentPID"

            Write-Host "[*] GHOST PROCESS IDENTITY: $($proc.Name)" -ForegroundColor Yellow
            [PSCustomObject]@{
                PID            = $pidNum
                User           = $user
                Parent         = "$($parent.Name) (PID: $parentPID)"
                ExecutablePath = if ($proc.ExecutablePath) { $proc.ExecutablePath } else { "MISSING/NULL (High Risk)" }
                CommandLine    = if ($proc.CommandLine) { $proc.CommandLine } else { "HIDDEN (High Risk)" }
            } | Format-List

            # 4. MODULE INTEGRITY CHECK (Ghost Process)
            Write-Host "[*] Checking for non-standard modules in Ghost Process..." -ForegroundColor Gray
            $modules = Get-Process -Id $pidNum -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Modules -ErrorAction SilentlyContinue
            
            if ($modules) {
                $suspiciousModules = $modules | Where-Object { 
                    $_.FileName -notmatch [regex]::Escape($BaselinePath) -and 
                    $_.FileName -notmatch [regex]::Escape($WinSxSPath) -and
                    $_.FileName -notmatch [regex]::Escape($ProgramFiles)
                }

                if ($suspiciousModules) {
                    Write-Host "[!] Found suspicious modules in memory:" -ForegroundColor Red
                    $suspiciousModules | Select-Object ModuleName, FileName | Format-Table -AutoSize
                }
                else {
                    Write-Host "[+] Modules for PID $pidNum appear standard." -ForegroundColor Green
                }
            }
            else {
                Write-Host "[!] Access Denied to module list for PID $pidNum. (Kernel Hooking suspected)" -ForegroundColor Red
            }

            # 5. MOTHER SHIP INTERROGATION (The svchost Audit)
            Write-Host "`n--- INTERROGATING MOTHER SHIP (PID $parentPID) ---" -ForegroundColor Cyan
            
            Write-Host "[>] Services sharing this svchost:" -ForegroundColor Gray
            Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -eq $parentPID } | 
            Select-Object Name, DisplayName, State, StartMode | Format-Table -AutoSize

            Write-Host "[>] Scanning for unsigned/non-standard DLLs in the Mother Ship..." -ForegroundColor Yellow
            $parentModules = Get-Process -Id $parentPID -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Modules | 
            Where-Object { (Get-AuthenticodeSignature $_.FileName).Status -ne 'Valid' -or $_.FileName -notmatch "C:\\Windows" }
            
            if ($parentModules) {
                $parentModules | Select-Object ModuleName, FileName | Format-Table -AutoSize
            }
            else {
                Write-Host "[+] No unsigned/external DLLs found in Parent PID $parentPID." -ForegroundColor Green
            }
        }
        Write-Host "------------------------------------------------------------"
    }
}
else {
    Write-Host "[+] No hidden processes detected via WMI comparison." -ForegroundColor Green
}