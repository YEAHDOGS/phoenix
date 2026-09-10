<#
.SYNOPSIS
    Phoenix BACKUP -- Windows twin of tools/Invoke-Backup.sh (validation side only).

.DESCRIPTION
    The scripted image write exists ONLY in the Linux rescue boot environment
    (Ventoy menu entry [2] BACKUP), which has no PowerShell. This twin therefore
    implements everything Windows CAN do before the reboot:

      * --config validation (via python3 tools/Read-UsbConfig.py --json):
        boot_entries.backup must be true; backup_target.kind must be
        direct-usb (castle-smb is refused on the scripted path).
      * Disk enumeration by SERIAL (Get-Disk) -- never by drive letter.
      * Air-gap check (Get-NetAdapter): refuses when any interface is Up,
        unless -AllowNetwork is passed AND the operator types ALLOW NETWORK
        at the console (not piped).
      * -DryRun plan: prints the full backup plan and writes nothing.

    Any attempt to actually image from Windows is REFUSED: a full-disk image
    must never be taken from the live OS that is being imaged (runbook
    Step 2.2: "Do not boot Windows").

.PARAMETER Config
    REQUIRED. Path to the stick's phoenix-config.json. Never auto-discovered.

.PARAMETER Source
    Disk serial (preferred), disk number, or device path from the enumeration
    table printed by -DryRun.

.PARAMETER Target
    Serial of the destination USB disk.

.PARAMETER TargetMount
    Mounted path on the target disk where the image file would be written.

.PARAMETER DryRun
    Walk the whole flow (config, serial resolution, air-gap gate, free-space
    check) and write nothing.

.PARAMETER AllowNetwork
    Permit the flow with a network interface up. Still requires typing
    ALLOW NETWORK at the console.

.PARAMETER Tool
    'dd' (default, scripted Linux path) or 'rescuezilla' (prints the manual
    checklist instead of planning the image).

.EXAMPLE
    .\Invoke-Backup.ps1 -Config D:\phoenix-config.json -Source WD-WMC4N0L12345 `
        -Target USBDRIVE99 -TargetMount E:\ -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [string]$Source,
    [string]$Target,
    [string]$TargetMount,
    [switch]$DryRun,
    [switch]$AllowNetwork,
    [ValidateSet('dd', 'rescuezilla')][string]$Tool = 'dd'
)

$ErrorActionPreference = 'Stop'
$ToolsDir = Split-Path -Parent $PSCommandPath

function Fail([string]$msg) {
    Write-Error "[Invoke-Backup] FATAL: $msg"
    exit 1
}

function Normalize-Serial([string]$s) { $s.Trim().ToUpperInvariant() }

# --- config policy (the single reader: tools/Read-UsbConfig.py --json) ---
if (-not (Test-Path $Config)) {
    Fail "--Config '$Config' is not a readable file."
}
$reader = Join-Path $ToolsDir 'Read-UsbConfig.py'
if (-not (Test-Path $reader)) { Fail "tools/Read-UsbConfig.py not found next to Invoke-Backup.ps1." }
try { $null = Get-Command python3 -ErrorAction Stop }
catch { Fail "--Config requires python3 to read phoenix-config.json." }

$policyJson = & python3 $reader --json $Config 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "--Config '$Config' is not a valid phoenix-config.json:`n$policyJson"
}
$policy = $policyJson | ConvertFrom-Json
if ($policy.backup_enabled -ne $true) {
    Fail "this stick's phoenix-config.json has boot_entries.backup=false. The stick's boot menu would not offer Backup either."
}
if ($policy.backup_kind -ne 'direct-usb') {
    Fail "backup_target.kind='$($policy.backup_kind)' -- the scripted boot path images only to a DIRECT-ATTACHED USB target. A network push from the infected machine would violate the air-gap gate (runbook Step 2.1). Copy the image to Castle from a CLEAN machine (runbook Step 2.7)."
}

if ($Tool -eq 'rescuezilla') {
    Write-Output @"
Phoenix BACKUP -- manual Rescuezilla path (runbook Step 2.3)
  1. Air-gap the machine: Ethernet unplugged, Wi-Fi off.
  2. Boot [2] BACKUP -- Rescuezilla from the Phoenix USB. Do NOT boot Windows.
  3. Backup -> ENTIRE source disk -> external USB drive. Enable compression
     AND the post-backup integrity check.
  4. VERIFY: post-backup check green, files present, sizes sane.
  5. ./tools/New-ImageProof.sh --verified ... --out /media/phoenix-usb/phoenix-log/
  6. Data-only backup to a separate location (Step 2.6).
  7. Rename QUARANTINE-INFECTED-<date>; copy to Castle from a CLEAN machine (Step 2.7).
"@
    exit 0
}

# --- air-gap gate ---
$upAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.Name -ne 'Loopback' }
if ($upAdapters) {
    $names = ($upAdapters | ForEach-Object { $_.Name }) -join ', '
    if (-not $AllowNetwork) {
        Fail "network interface(s) UP: $names. The Backup phase must be AIR-GAPPED (runbook Step 2.1). Unplug Ethernet and disable Wi-Fi, then re-run -- or pass -AllowNetwork and type ALLOW NETWORK at the console."
    }
    $isTty = -not [Console]::IsInputRedirected
    if (-not $isTty) { Fail "-AllowNetwork needs a real console (stdin is piped)." }
    $answer = Read-Host "Network is UP. Type 'ALLOW NETWORK' to continue"
    if ($answer -ne 'ALLOW NETWORK') { Fail "network allowance not confirmed at the console." }
    Write-Warning "--AllowNetwork typed at console -- imaging with network UP (runbook deviation)."
}

# --- serial-resolved enumeration (Get-Disk; letters never identify a disk) ---
try { $disks = Get-Disk -ErrorAction Stop } catch { Fail "Get-Disk failed: $_" }
Write-Output "======================================================================"
Write-Output " PHOENIX BACKUP (Windows twin) -- disk enumeration"
Write-Output "======================================================================"
Write-Output ("{0,-4} {1,-12} {2,-30} {3,-24} {4}" -f '#', 'NUMBER', 'MODEL', 'SERIAL', 'SIZE')
$i = 0
foreach ($d in $disks) {
    $i++
    $gb = [math]::Round($d.Size / 1GB, 1)
    Write-Output ("{0,-4} {1,-12} {2,-30} {3,-24} {4} GB" -f $i, $d.Number, $d.FriendlyName, $d.SerialNumber, $gb)
}
Write-Output "======================================================================"

function Resolve-Disk([string]$id) {
    if (-not $id) { Fail "a disk identifier is required." }
    # Row number from the table above
    if ($id -match '^\d+$') {
        $n = [int]$id
        if ($n -ge 1 -and $n -le $disks.Count) { return $disks[$n - 1] }
        Fail "no disk matches row '$id'."
    }
    # Serial (exact, one match) -- duplicated serials are identity failure.
    $bySerial = @($disks | Where-Object { (Normalize-Serial $_.SerialNumber) -eq (Normalize-Serial $id) })
    if ($bySerial.Count -gt 1) { Fail "identifier '$id' is ambiguous -- $($bySerial.Count) disks report that serial." }
    if ($bySerial.Count -eq 1) { return $bySerial[0] }
    # Disk number or device path alias
    $byNum = @($disks | Where-Object { "$($_.Number)" -eq $id -or $_.Path -eq $id })
    if ($byNum.Count -eq 1) { return $byNum[0] }
    Fail "no disk matches identifier '$id'."
}

$src = Resolve-Disk $Source
$tgt = Resolve-Disk $Target
if ((Normalize-Serial $src.SerialNumber) -eq (Normalize-Serial $tgt.SerialNumber)) {
    Fail "source and target resolve to the same serial. A disk cannot image onto itself."
}
if ($tgt.BusType -ne 'USB') {
    Fail "target disk #$($tgt.Number) is not USB (BusType=$($tgt.BusType)). The scripted path images only to a direct-attached USB drive."
}
if (-not (Test-Path $TargetMount)) { Fail "-TargetMount '$TargetMount' does not exist." }

# --- free-space gate (half the source size, compressed images assumed) ---
$srcGB = $src.Size
$driveLetter = (Split-Path -Qualifier $TargetMount)
$vol = Get-Volume -DriveLetter $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
if ($vol -and $vol.SizeRemaining -lt ($srcGB / 2)) {
    Fail "only $([math]::Round($vol.SizeRemaining/1GB,1)) GB free on '$TargetMount' -- less than half the source size. Attach a larger target drive."
}

if ($DryRun) {
    Write-Output @"
======================================================================
 PHOENIX BACKUP (Windows twin) -- DRY RUN (nothing written)
======================================================================
 Config   : $Config (backup policy: ENABLED, kind=direct-usb)
 Air-gap  : OK
 Source   : #$($src.Number) $($src.FriendlyName) serial=$($src.SerialNumber)
 Target   : #$($tgt.Number) $($tgt.FriendlyName) serial=$($tgt.SerialNumber) -> $TargetMount
 Plan     : boot [2] BACKUP on the Phoenix USB (Linux rescue env) and run
            tools/Invoke-Backup.sh with these same identifiers -- the scripted
            dd path lives ONLY in the boot environment.
 Proof    : image-proof manifest binds serial $($src.SerialNumber)
======================================================================
"@
    exit 0
}

# --- the image write itself is REFUSED on Windows, always ---
Fail @"
the scripted image write runs ONLY in the Linux rescue boot environment
(Ventoy menu [2] BACKUP -- Rescuezilla/dd), which has no PowerShell.
A full-disk image must never be taken from the live Windows session
being imaged (runbook Step 2.2: 'Do not boot Windows').
Boot the Phoenix USB and run tools/Invoke-Backup.sh there.
"@
