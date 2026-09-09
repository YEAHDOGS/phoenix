<#
.SYNOPSIS
    Phoenix in-environment menu (WinPE side) -- Analyze / Backup / Nuke /
    Reinstall dispatcher. The Linux-rescue twin is tools/phoenix-menu.sh.
    Both implement the SAME contract -- keep them in sync.

.DESCRIPTION
    Once booted into the Phoenix WinPE toolkit entry, the Ventoy boot menu
    is behind you. THIS menu is the founder's Analyze / Backup / Nuke /
    Reinstall flow inside the running environment: it reads
    phoenix-config.json headlessly from the USB root, shows the machine
    context, and dispatches to the right tool.

    SAFETY MODEL:
      - This menu is NEVER destructive by itself. It prints guidance and
        dispatches to the phase tools; destruction lives ONLY in the nuke
        tools (Invoke-PhoenixNuke.ps1 / Invoke-Nuke.sh), which carry their
        own interlocks (typed confirmation on a real console, boot/USB
        self-protection, audit logging).
      - Choice 3 (Nuke) invokes tools/Invoke-PhoenixNuke.ps1 with the
        arguments given after `--`. Piping input TO THE MENU is fine -- the
        nuke tool refuses redirected stdin structurally at confirmation.
      - The install-time password in phoenix-config.json is NEVER printed,
        never echoed, never logged. The parser reads only schemaVersion,
        machine.computerName, and os.family. (The USB is a key -- anyone
        holding it can read the password.)

.PARAMETER Config
    Explicit phoenix-config.json path. Default: scan mounted fixed/removable
    drives for phoenix-config.json at the volume root.

.PARAMETER Choice
    Run one choice non-interactively (1, 2, 3, 4, or Q), then exit.

.EXAMPLE
    .\Invoke-PhoenixMenu.ps1
    Interactive menu loop (Q to quit).

.EXAMPLE
    .\Invoke-PhoenixMenu.ps1 -Choice 3 -- -Nuke 2
    Dispatch Nuke: hand off to tools\Invoke-PhoenixNuke.ps1 -Nuke 2.

.NOTES
    Exit codes: 0 = ok | 1 = error (bad flag, missing tool, unknown choice).
    Test hook: $env:PHOENIX_MENU_TEST = "1" makes choice 3 print the
    dispatch line instead of invoking the nuke tool.
#>
[CmdletBinding()]
param(
    # Explicit phoenix-config.json path (default: scan mounted volumes).
    [string]$Config = "",

    # Run one choice non-interactively: 1, 2, 3, 4, or Q.
    [string]$Choice = "",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VERSION = "0.1.0"
$PROG = "Invoke-PhoenixMenu"
$TestMode = ($env:PHOENIX_MENU_TEST -eq "1")
$NukeTool = Join-Path $PSScriptRoot "Invoke-PhoenixNuke.ps1"

# Parsed config -- non-sensitive fields ONLY. Never read .credentials.
$script:CfgSchema = "?"
$script:CfgName = "?"
$script:CfgOs = "?"
$script:ConfigFound = $false
$script:ConfigUsed = ""

function Fail([string]$Message) {
    Write-Host "[$PROG] FATAL: $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    @"
Phoenix menu v$VERSION -- Analyze / Backup / Nuke / Reinstall dispatcher (WinPE side)

Usage:
  .\Invoke-PhoenixMenu.ps1                 Interactive menu loop (Q to quit)
  .\Invoke-PhoenixMenu.ps1 -Config <path>  Explicit phoenix-config.json location
  .\Invoke-PhoenixMenu.ps1 -Choice <1|2|3|4|Q>
                                          Run one choice non-interactively, then exit
  .\Invoke-PhoenixMenu.ps1 -Choice 3 -- -Nuke 2
                                          Dispatch Nuke: Invoke-PhoenixNuke.ps1 -Nuke 2

The menu itself destroys nothing. Nuke is handed to Invoke-PhoenixNuke.ps1,
which enforces its own interlocks (double-typed confirmation on a real
console, boot/USB self-protection, audit log).
"@
}

# Find-PhoenixConfig: locate phoenix-config.json at the root of a mounted
# volume. Explicit -Config wins; otherwise scan fixed/removable drives.
function Find-PhoenixConfig {
    if ($Config) {
        if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) { Fail "-Config '$Config' not found." }
        return $Config
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $cand = Join-Path ($d.Root) "phoenix-config.json"
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    $cwdCand = Join-Path (Get-Location) "phoenix-config.json"
    if (Test-Path -LiteralPath $cwdCand -PathType Leaf) { return $cwdCand }
    return $null
}

# Load-PhoenixConfig: parse NON-SENSITIVE fields only. The credentials block
# is never read and can never leak into output -- redaction by design.
function Load-PhoenixConfig {
    $path = Find-PhoenixConfig
    if (-not $path) { return }
    try {
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        Write-Host "[$PROG] WARNING: '$path' is not valid JSON -- unconfigured mode." -ForegroundColor Yellow
        return
    }
    $script:ConfigFound = $true
    $script:ConfigUsed = $path
    if ($null -ne $cfg.schemaVersion) { $script:CfgSchema = "$($cfg.schemaVersion)" }
    if ($null -ne $cfg.machine -and $null -ne $cfg.machine.computerName -and $cfg.machine.computerName) {
        $script:CfgName = "$($cfg.machine.computerName)"
    }
    if ($null -ne $cfg.os -and $null -ne $cfg.os.family -and $cfg.os.family) {
        $script:CfgOs = "$($cfg.os.family)"
    }
}

function Show-Banner {
    Write-Host "======================================================================"
    Write-Host " PHOENIX -- Analyze / Backup / Nuke / Reinstall"
    Write-Host "======================================================================"
    if ($script:ConfigFound) {
        Write-Host " config: $($script:ConfigUsed) (schema $($script:CfgSchema))"
        Write-Host " machine: $($script:CfgName)   os.family: $($script:CfgOs)"
    } else {
        Write-Host " config: NOT FOUND on any mounted volume -- unconfigured mode."
        Write-Host " Reinstall answers unavailable until a Phoenix USB with"
        Write-Host " phoenix-config.json is mounted."
    }
    Write-Host "----------------------------------------------------------------------"
}

function Show-Menu {
    @"
  [1] ANALYZE    inspect the machine without booting its OS
  [2] BACKUP     full-disk image + data backup (before anything destructive)
  [3] NUKE       irreversible disk sanitization (typed-confirmation interlocks)
  [4] REINSTALL  unattended OS reinstall from phoenix-config.json
  [Q] QUIT
"@
}

function Choice-Analyze {
    @"

--- [1] ANALYZE ---------------------------------------------------------------
You are in Phoenix WinPE: the suspect machine's OS is NOT running, so its
disk is inert and safe to inspect.

  - Explorer++ (portable, in the WinPE WIM): browse the target disk first.
  - PowerShell: Get-Disk / Get-Partition, and hash anything you care about:
      Get-FileHash <file> -Algorithm SHA256
  - Rule: nothing on this menu writes to the target disk except the
    BACKUP and NUKE paths -- and NUKE asks for the disk serial twice.
"@
}

function Choice-Backup {
    @"

--- [2] BACKUP ----------------------------------------------------------------
Verified backup or no wipe -- that is the runbook invariant, and the Nuke
gate enforces it in code.

  1. Full-disk image: run Rescuezilla (the [2] BACKUP Ventoy entry) against
     the target disk; WATCH its post-backup integrity check pass.
  2. Mint the image proof: tools\New-ImageProof.ps1 -ImageName <n> `
       -ImagePath <dir> -SourceSerial <serial> -Sha256 <64-hex> -Verified
     The proof manifest is what tools\Invoke-Nuke.sh --image-proof demands
     before it will arm a wipe (verified=YES, matching source_serial).
  3. Data-only backup (optional, in addition to the image):
     tools\New-PhoenixDataBackup.ps1 (WinPE)  |  tools\phoenix-data-backup.sh (Linux)
     emits a phoenix-data-backup/1 manifest; executables are skipped unless
     explicitly opted in (dirty-data contract).

Image target: a SECOND USB / Castle storage -- never the Phoenix boot stick,
never the disk you are about to wipe.
"@
}

function Choice-Nuke {
    # All remaining args (after --) go straight to the nuke tool.
    if (-not (Test-Path -LiteralPath $NukeTool -PathType Leaf)) {
        Write-Host "[$PROG] FATAL: nuke tool not found: $NukeTool" -ForegroundColor Red
        return 1
    }
    @"

--- [3] NUKE ------------------------------------------------------------------
IRREVERSIBLE. The nuke tool will now take over: it enumerates disks, and
arming requires typing the target disk's exact serial TWICE on a real
console (piped input is refused), plus a 5-second abort window. Read the
operator checklist in docs\NUKE-SAFETY.md BEFORE you arm anything.

Handing off to tools\Invoke-PhoenixNuke.ps1 ...
"@
    if ($TestMode) {
        Write-Host "[$PROG] TESTMODE: would invoke: $NukeTool $($script:NukeArgs -join ' ')"
        return 0
    }
    & $NukeTool @script:NukeArgs
    return $LASTEXITCODE
}

function Choice-Reinstall {
    $text = @"

--- [4] REINSTALL -------------------------------------------------------------
Unattended reinstall is driven by the generated answer file, which Ventoy's
auto_install plugin feeds to the Windows ISO at boot (see
docs\BOOT-ARCHITECTURE.md §3).

  - phoenix-config.json -> autounattend.xml is produced by the config GUI
    (Svelte + Tauri) or tools\Build-PhoenixUsb.ps1 on a WORKING machine.
"@
    if ($script:ConfigFound) {
        $text += @"
  This stick's config targets: $($script:CfgName) ($($script:CfgOs) family).
  First logon: rotate the install-time password (runbook Step: the
  USB is a key -- anyone holding it could read it).
"@
    } else {
        $text += @"
  No config on this machine -- reinstall answers unavailable.
  Mount the Phoenix USB (the exFAT partition) and re-run this menu.
"@
    }
    $text
}

# Returns 0 = continue, 1 = error, 2 = quit requested.
function Invoke-Choice([string]$c) {
    switch ($c) {
        "1" { Choice-Analyze; return 0 }
        "2" { Choice-Backup; return 0 }
        "3" { return (Choice-Nuke) }
        "4" { Choice-Reinstall; return 0 }
        { $_ -eq "q" -or $_ -eq "Q" } { return 2 }
        default {
            Write-Host "[$PROG] unknown choice '$c' -- use 1, 2, 3, 4, or Q." -ForegroundColor Yellow
            return 1
        }
    }
}

#===============================================================================
# main
#===============================================================================
if ($Help) { Show-Usage; exit 0 }

# Split trailing args: everything after a bare `--` goes to the nuke tool.
$script:NukeArgs = @()
$seenDashDash = $false
foreach ($a in $args) {
    if ($seenDashDash) { $script:NukeArgs += $a; continue }
    if ($a -eq "--") { $seenDashDash = $true; continue }
    Fail "Unknown argument: $a (see -Help)"
}

Load-PhoenixConfig
Show-Banner

if ($Choice) {
    Show-Menu
    $rc = Invoke-Choice $Choice.Trim()
    if ($rc -eq 2) { exit 0 }
    exit $rc
}

while ($true) {
    Show-Menu
    $line = Read-Host "phoenix"
    $line = ($line -replace '\s', '')
    if (-not $line) { continue }
    $rc = Invoke-Choice $line
    if ($rc -eq 2) { exit 0 }
    Write-Host ""
}
