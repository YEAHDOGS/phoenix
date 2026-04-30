Write-Host "--- AUDITING SERVICE PATH VULNERABILITIES ---" -ForegroundColor Yellow
Get-CimInstance Win32_Service | Where-Object { $_.PathName -notmatch '^"|^\w:\\Windows' } | 
Select-Object Name, PathName, StartMode | 
Format-Table -AutoSize