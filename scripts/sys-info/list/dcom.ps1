Write-Host "--- DEEP-DIVE DCOM FORENSIC AUDIT ---" -ForegroundColor Cyan

# 1. Check Global OLE Settings
Write-Host "[>] Checking Global Machine Settings (Registry)..." -ForegroundColor Gray
$OlePath = "HKLM:\SOFTWARE\Microsoft\Ole"
Get-ItemProperty -Path $OlePath | Select-Object EnableDCOM, EnableRemoteConnect, LegacyAuthenticationLevel | Format-List

# 2. Identify AppIDs with "Ghost" Executables
# This looks for DCOM objects that launch specific EXEs instead of using svchost
Write-Host "[>] Auditing AppID Executables (Potential Hijacks)..." -ForegroundColor Yellow
$AppIDPath = "HKLM:\SOFTWARE\Classes\AppID"
Get-ChildItem -Path $AppIDPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath
    if ($props.LocalService -or $props.LaunchPermission) {
        [PSCustomObject]@{
            AppID       = $_.PSChildName
            Service     = $props.LocalService
            Description = $props.'(default)'
            RunAs       = $props.RunAs
        }
    }
} | Where-Object { $_.Service } | Format-Table -AutoSize

# 3. Audit Machine-Wide Launch Restrictions
# These binary blobs (DefaultLaunchPermission) can be modified by malware to allow 'Everyone' to launch code
Write-Host "[>] Checking Machine Launch/Access Restrictions..." -ForegroundColor Gray
$Permissions = Get-ItemProperty -Path $OlePath -ErrorAction SilentlyContinue
$CheckPaths = @("DefaultLaunchPermission", "MachineLaunchRestriction", "MachineAccessRestriction")

foreach ($Path in $CheckPaths) {
    if ($Permissions.$Path) {
        Write-Host "[!] ALERT: Non-standard $Path detected in OLE root!" -ForegroundColor Red
    }
}

# 4. Check for DCOM 'RunAs' Users
# Attackers often set 'RunAs' to 'Interactive User' to gain the permissions of the person logged in
Write-Host "[>] Scanning for DCOM 'RunAs' configurations..." -ForegroundColor Cyan
Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Classes\AppID" -ErrorAction SilentlyContinue | ForEach-Object {
    $val = Get-ItemProperty $_.PSPath -Name "RunAs" -ErrorAction SilentlyContinue
    if ($val.RunAs -eq "Interactive User") {
        Write-Host "[!] Found 'Interactive User' RunAs on AppID: $($_.PSChildName)" -ForegroundColor Yellow
    }
}