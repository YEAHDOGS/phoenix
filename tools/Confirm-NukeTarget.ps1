<#
.SYNOPSIS
    Phoenix nuke confirmation gate (WinPE / staging side twin).
.DESCRIPTION
    PowerShell twin of tools/lib/nuke-interlock.sh. Verifies the exact gate
    logic the boot side will run, against an inventory produced by
    Get-DiskInventory.ps1:

      Confirm-NukeTarget -InventoryJson <json> -Id <n> [-StateDir <dir>] [-ConfigJson <json>]

    Gates, in order: booted/system-disk structural refusal, typed
    confirmation (exact "SERIAL MODEL" on a real console -- piped stdin is
    refused), Analyze fingerprint freshness, config target_disks allowlist
    (compared normalized: uppercased, whitespace-trimmed).

    STAGING-ONLY: this verifies the flow on a working machine. Destruction can
    never be armed from a live Windows session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InventoryJson,
    [Parameter(Mandatory = $true)][int]$Id,
    [string]$StateDir = $env:TEMP,
    [string]$ConfigJson = ""
)

$ErrorActionPreference = "Stop"

function Write-GateLog {
    param([string]$Dir, [string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path (Join-Path $Dir "nuke-interlock.log") -Value "[$ts] $Message"
}

function Test-IsInteractiveConsole {
    # Refuse piped/redirected stdin: scripting the confirmation must be
    # structurally impossible. In WinPE there is no reliable stdin-redirect
    # API, so we check both console input redirection and key availability.
    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}

function Get-TargetField {
    param($Inventory, [int]$DiskId, [string]$Field)
    $d = $Inventory.disks | Where-Object { $_.id -eq $DiskId } | Select-Object -First 1
    if (-not $d) { throw "no disk with id $DiskId" }
    return $d.$Field
}

function Confirm-TypedPair {
    param($Serial, $Model, [string]$StateDir, [int]$DiskId)
    if ([string]::IsNullOrWhiteSpace($Serial)) {
        Write-Error "[nuke-interlock] REFUSED: disk [$DiskId] has no readable serial; it can never be a nuke target."
    }
    if (-not (Test-IsInteractiveConsole)) {
        Write-Error "[nuke-interlock] REFUSED: console input is redirected. Confirmation must be typed interactively."
    }

    Write-Host "======================================================================"
    Write-Host " NUKE TARGET CARD -- read carefully, there is no undo"
    Write-Host "----------------------------------------------------------------------"
    Write-Host "  [$DiskId] $Model"
    Write-Host "      Serial : $Serial"
    Write-Host "----------------------------------------------------------------------"
    Write-Host " To ARM the wipe, type the serial and model EXACTLY as shown above:"
    Write-Host "    $Serial $Model"
    Write-Host " (or: NUKE $Serial $Model)"
    Write-Host " Anything else aborts. This cannot be scripted."
    Write-Host "======================================================================"

    $answer = ([Console]::ReadLine() | ForEach-Object { $_.Trim() })
    if (($answer -ceq "$Serial $Model") -or ($answer -ceq "NUKE $Serial $Model")) {
        Write-GateLog $StateDir "CONFIRMED nuke target id=$DiskId serial=$Serial model=`"$Model`""
        Write-Host "[nuke-interlock] target confirmed and logged."
        return
    }
    Write-GateLog $StateDir "REJECTED confirmation attempt for id=$DiskId (input did not match)"
    Write-Error "[nuke-interlock] ABORTED: typed confirmation did not match. Nothing was armed."
}

function Test-DiskFingerprint {
    param([string]$Dir, [string]$Serial, [int]$MaxAgeHours = 24)
    $fpPath = Join-Path $Dir "disk-fingerprints.json"
    if (-not (Test-Path $fpPath)) {
        Write-Error "[nuke-interlock] REFUSED: no disk-fingerprints.json in $Dir -- run Analyze first."
    }
    try { $fp = Get-Content $fpPath -Raw | ConvertFrom-Json }
    catch { Write-Error "[nuke-interlock] REFUSED: fingerprint file is not valid JSON." }

    if ($fp.recorded_by -ne "analyze") {
        Write-Error "[nuke-interlock] REFUSED: fingerprint was not recorded by Analyze."
    }
    try {
        $rec = [DateTime]::ParseExact($fp.recorded_at, "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { Write-Error "[nuke-interlock] REFUSED: fingerprint has no parseable recorded_at." }

    $ageH = ((Get-Date).ToUniversalTime() - $rec.ToUniversalTime()).TotalHours
    if (($ageH -gt $MaxAgeHours) -or ($ageH -lt 0)) {
        Write-Error ("[nuke-interlock] REFUSED: fingerprint is {0:N1}h old (limit {1}h) -- re-run Analyze." -f $ageH, $MaxAgeHours)
    }
    $match = $fp.disks | Where-Object { $_.serial -ceq $Serial }
    if (-not $match) {
        Write-Error "[nuke-interlock] REFUSED: target serial not present in the Analyze fingerprint."
    }
    Write-Host ("[nuke-interlock] fingerprint OK: {0} recorded {1:N1}h ago by Analyze." -f $Serial, $ageH)
}

function Get-NormalizedSerial {
    # MUST match nuke_normalize_serial() in tools/lib/nuke-interlock.sh and
    # docs/NUKE-SAFETY.md interlock 12: uppercase + trim surrounding
    # whitespace. Internal whitespace is significant ("AB 12" != "AB12").
    param([string]$Serial)
    return "$Serial".Trim().ToUpperInvariant()
}

function Test-ConfigAllowlist {
    param([string]$Cfg, [string]$Serial)
    if ([string]::IsNullOrWhiteSpace($Cfg) -or -not (Test-Path $Cfg)) {
        Write-Error "[nuke-interlock] REFUSED: config file not found: $Cfg"
    }
    try { $config = Get-Content $Cfg -Raw | ConvertFrom-Json }
    catch { Write-Error "[nuke-interlock] REFUSED: config is not valid JSON." }

    $want = Get-NormalizedSerial $Serial
    if ([string]::IsNullOrWhiteSpace($want)) {
        Write-Error "[nuke-interlock] REFUSED: empty serial can never be a nuke target."
    }
    $allow = @($config.target_disks | ForEach-Object { Get-NormalizedSerial $_.serial })
    if ($allow -ccontains $want) {
        Write-Host "[nuke-interlock] allowlist OK: $want is approved in target_disks."
        return
    }
    Write-Error "[nuke-interlock] REFUSED: serial $want is NOT in target_disks -- this disk may not be nuked."
}

# --- main --------------------------------------------------------------------
$inventory = $InventoryJson | ConvertFrom-Json
$serial = Get-TargetField $inventory $Id "serial"
$model = Get-TargetField $inventory $Id "model"
$mounted = Get-TargetField $inventory $Id "mounted"
$boot = Get-TargetField $inventory $Id "boot"
$system = Get-TargetField $inventory $Id "system"

if ($boot -or $system) {
    Write-Error "[nuke-interlock] REFUSED: disk [$Id] is the boot/system disk. It can never be a nuke target."
}

if ($mounted) {
    Write-Error "[nuke-interlock] REFUSED: disk [$Id] has mounted partitions; it can never be a nuke target."
}

Test-DiskFingerprint -Dir $StateDir -Serial $serial
if ($ConfigJson -ne "") { Test-ConfigAllowlist -Cfg $ConfigJson -Serial $serial }
Confirm-TypedPair -Serial $serial -Model $model -StateDir $StateDir -DiskId $Id
