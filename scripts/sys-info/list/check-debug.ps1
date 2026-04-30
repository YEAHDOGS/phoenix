# Check if Test Signing or Debugging modes are enabled (Attacker favorites)
$bcd = bcdedit /enum | Out-String
$indicators = @("testsigning", "debug", "nointegritychecks")

foreach ($flag in $indicators) {
    if ($bcd -match $flag) {
        Write-Host "[!] ALERT: $flag is ENABLED in BCD settings. Kernel integrity may be compromised." -ForegroundColor Red
    }
    else {
        Write-Host "[+] $flag is disabled (Secure)." -ForegroundColor Green
    }
}