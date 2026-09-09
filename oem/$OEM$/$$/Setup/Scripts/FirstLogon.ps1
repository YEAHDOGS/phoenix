<#
.SYNOPSIS
    Phoenix $OEM$ hook: first-logon app install (admin context, OOBE safe).

.DESCRIPTION
    Invoked by autounattend.xml (oobeSystem pass, FirstLogonCommands) as
    C:\Windows\Setup\Scripts\FirstLogon.ps1. Runs once as the new local
    administrator.

    Installs the app-picker package list with a strict offline-first policy:

      1. If the Phoenix USB carries cache\apps\*.nupkg, Chocolatey installs
         from that local cache -- zero network.
      2. If no cache is found and -AllowOnline is passed, Chocolatey installs
         from the community feed (the machine is clean at this point; the
         answer-file author opts in explicitly).
      3. Otherwise apps are skipped with a warning.

    OOBE CONTRACT: this script NEVER fails the out-of-box experience. All
    errors are caught, logged to C:\Phoenix\Logs\FirstLogon.log, and the
    script always exits 0. A machine that boots without Steam is better than
    a machine stuck in OOBE.

    Air-gap default: with no -AllowOnline, no socket is ever opened. The
    stager (tools/Build-PhoenixUsb.*) populates cache\apps on the clean
    machine; see tools/New-AppInstallScript.ps1 for the generated installer
    this hook invokes when present.

.PARAMETER AllowOnline
    Permit online Chocolatey installs when no offline cache is present.
    Without it, missing cache means apps are skipped -- logged, not failed.

.PARAMETER UsbRoot
    Override for tests: path to a fake Phoenix USB root containing
    phoenix\manifest.json. Normally auto-detected.

    PHOENIX-OEM
#>
[CmdletBinding()]
param(
    [switch]$AllowOnline,
    [string]$UsbRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$logFile    = "C:\Phoenix\Logs\FirstLogon.log"
$markerFile = "C:\Phoenix\Logs\firstlogon.done"

function Write-PhoenixLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'o') [$Level] $Message"
    try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
    Write-Verbose $line
}

function Find-PhoenixUsb {
    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($UsbRoot)) { $roots += $UsbRoot }
    try {
        $roots += Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
                  Where-Object { $_.Root -ne 'C:\' -and $null -ne $_.Root } |
                  ForEach-Object { $_.Root }
    } catch { }
    foreach ($r in ($roots | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $r "phoenix\manifest.json")) { return $r }
    }
    return $null
}

function Invoke-AppInstall {
    param([string]$CacheDir, [string]$SourceLabel)

    # The generated installer (tools/New-AppInstallScript.ps1) if staged...
    $generated = Join-Path (Join-Path $script:usbRoot "phoenix\scripts") "app-install.ps1"
    if (Test-Path -LiteralPath $generated) {
        Write-PhoenixLog "Running generated installer: $generated ($SourceLabel)"
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generated 2>&1 |
                ForEach-Object { Write-PhoenixLog "  app-install: $_" }
            Write-PhoenixLog "Generated installer finished (exit path guarded; OOBE continues regardless)."
        } catch {
            Write-PhoenixLog "Generated installer threw: $($_.Exception.Message)" "ERROR"
        }
        return
    }

    # ...otherwise direct choco from the cache.
    $pkgs = Get-ChildItem -Path $CacheDir -Filter "*.nupkg" -File -ErrorAction SilentlyContinue
    if ($null -eq $pkgs -or $pkgs.Count -eq 0) {
        Write-PhoenixLog "No .nupkg files in $CacheDir and no generated installer -- nothing to install." "WARN"
        return
    }
    foreach ($pkg in $pkgs) {
        $id = ($pkg.BaseName -split '\.')[0]
        Write-PhoenixLog "choco install $id --source $CacheDir"
        try {
            & choco install $id -y --no-progress --source $CacheDir 2>&1 |
                ForEach-Object { Write-PhoenixLog "  choco: $_" }
        } catch {
            Write-PhoenixLog "choco install $id failed: $($_.Exception.Message)" "ERROR"
        }
    }
}

# ---------------------------------------------------------------------------
try {
    Write-PhoenixLog "Phoenix FirstLogon started (AllowOnline=$($AllowOnline.IsPresent))."

    $script:usbRoot = Find-PhoenixUsb
    if ($null -eq $script:usbRoot) {
        Write-PhoenixLog "No Phoenix USB found -- app install skipped, OOBE continues." "WARN"
    } else {
        $cacheDir = Join-Path $script:usbRoot "cache\apps"
        $hasCache = (Test-Path -LiteralPath $cacheDir) -and
                    ((Get-ChildItem -Path $cacheDir -Filter "*.nupkg" -File -ErrorAction SilentlyContinue |
                      Measure-Object).Count -gt 0)

        if ($hasCache) {
            Write-PhoenixLog "Offline app cache found at $cacheDir -- installing without network."
            Invoke-AppInstall -CacheDir $cacheDir -SourceLabel "offline-cache"
        } elseif ($AllowOnline) {
            Write-PhoenixLog "No offline cache; -AllowOnline given -- running online app install." "WARN"
            Invoke-AppInstall -CacheDir $null -SourceLabel "online (explicit opt-in)"
        } else {
            Write-PhoenixLog "No offline cache and -AllowOnline not passed -- apps skipped (air-gap default). Re-run the stager with an app cache, or call this script with -AllowOnline." "WARN"
        }
    }

    [pscustomobject]@{
        phase      = "firstlogon"
        finished   = (Get-Date).ToString("o")
        usbRoot    = $script:usbRoot
        allowOnline = [bool]$AllowOnline
    } | ConvertTo-Json | Set-Content -Path $markerFile -Encoding UTF8 -ErrorAction Stop
    Write-PhoenixLog "Marker written: $markerFile"
} catch {
    Write-PhoenixLog "Unhandled error in FirstLogon: $($_.Exception.Message)" "ERROR"
}

Write-PhoenixLog "Phoenix FirstLogon finished (exit 0 -- OOBE never fails)."
exit 0
