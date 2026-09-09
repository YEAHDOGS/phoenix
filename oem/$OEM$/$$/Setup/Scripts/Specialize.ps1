<#
.SYNOPSIS
    Phoenix $OEM$ hook: runs in the specialize pass as SYSTEM.

.DESCRIPTION
    Invoked by autounattend.xml (specialize pass, Order 2) as
    C:\Windows\Setup\Scripts\Specialize.ps1. Runs as SYSTEM before any user
    profile exists.

    It:
      1. Creates C:\Phoenix\{Logs,Scripts} on the new install.
      2. Locates the Phoenix USB by its marker file (phoenix\manifest.json)
         and copies the audited toolbox (phoenix\scripts\) onto the disk, so
         post-install tooling runs from disk even after the USB is removed.
      3. Writes a run marker (specialize.done) used as a build sanity check.

    This script performs NO network calls and NEVER fails setup: every step
    is guarded and failures are logged, not thrown. A partial setup that
    boots is always better than a failed setup that doesn't.

    Air-gap contract: the target machine may not touch the network. This
    script reads only from local drives.

    PHOENIX-OEM
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$phoenixRoot = "C:\Phoenix"
$logDir      = Join-Path $phoenixRoot "Logs"
$scriptDir   = Join-Path $phoenixRoot "Scripts"
$logFile     = Join-Path $logDir "Specialize.log"
$markerFile  = Join-Path $logDir "specialize.done"

function Write-PhoenixLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'o') [$Level] $Message"
    try {
        Add-Content -Path $logFile -Value $line -ErrorAction Stop
    } catch {
        # Logging must never take down setup; the Event Log is the backstop.
        try { Write-EventLog -LogName Application -Source "Phoenix" -EventId 1001 -EntryType Warning -Message $line -ErrorAction Stop } catch {}
    }
    Write-Verbose $line
}

# ---------------------------------------------------------------------------
# 1. Directory skeleton
# ---------------------------------------------------------------------------
foreach ($d in @($phoenixRoot, $logDir, $scriptDir)) {
    try {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    } catch {
        Write-PhoenixLog "Could not create $d : $($_.Exception.Message)" "ERROR"
    }
}

# Register an Event Log source for the backstop path above (best effort).
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("Phoenix")) {
        New-EventLog -LogName Application -Source "Phoenix" -ErrorAction Stop
    }
} catch { }

Write-PhoenixLog "Phoenix Specialize started (SYSTEM, specialize pass)."

# ---------------------------------------------------------------------------
# 2. Find the Phoenix USB by its marker file, copy the toolbox to disk
# ---------------------------------------------------------------------------
$usbRoot = $null
try {
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
              Where-Object { $_.Root -ne 'C:\' -and $null -ne $_.Root }
    foreach ($drv in $drives) {
        $candidate = Join-Path $drv.Root "phoenix\manifest.json"
        if (Test-Path -LiteralPath $candidate) { $usbRoot = $drv.Root; break }
    }
} catch {
    Write-PhoenixLog "Drive enumeration failed: $($_.Exception.Message)" "ERROR"
}

if ($null -eq $usbRoot) {
    Write-PhoenixLog "No drive with phoenix\manifest.json found -- toolbox NOT copied to disk. This is expected on non-Phoenix media." "WARN"
} else {
    $src = Join-Path $usbRoot "phoenix\scripts"
    if (Test-Path -LiteralPath $src) {
        try {
            Copy-Item -Path (Join-Path $src "*") -Destination $scriptDir -Recurse -Force -ErrorAction Stop
            $count = (Get-ChildItem -Path $scriptDir -Recurse -File | Measure-Object).Count
            Write-PhoenixLog "Toolbox copied from $src : $count files."
        } catch {
            Write-PhoenixLog "Toolbox copy failed: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-PhoenixLog "USB found at $usbRoot but phoenix\scripts missing -- skipped." "WARN"
    }
}

# ---------------------------------------------------------------------------
# 3. Run marker
# ---------------------------------------------------------------------------
try {
    [pscustomobject]@{
        phase     = "specialize"
        finished  = (Get-Date).ToString("o")
        usbRoot   = $usbRoot
        buildNote = "written by oem/`$OEM$/`$`$/Setup/Scripts/Specialize.ps1"
    } | ConvertTo-Json | Set-Content -Path $markerFile -Encoding UTF8 -ErrorAction Stop
    Write-PhoenixLog "Marker written: $markerFile"
} catch {
    Write-PhoenixLog "Marker write failed: $($_.Exception.Message)" "ERROR"
}

Write-PhoenixLog "Phoenix Specialize finished."
exit 0
