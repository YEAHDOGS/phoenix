<#
.SYNOPSIS
    Phoenix NUKE core -- nuclear disk sanitization for the Phoenix boot menu
    (Analyze / Backup / Nuke / Reinstall). Windows side of the pair; the
    Linux-rescue twin is tools/phoenix-nuke.sh. Both implement the SAME
    interlock contract -- keep them in sync.

.DESCRIPTION
    SAFETY MODEL (exact rule parity with tools/phoenix-nuke.sh):
      1. Dry-run is the DEFAULT: no flags (or -DryRun/-WhatIf) ONLY enumerates
         disks and exits 0. Destruction requires -Nuke <id>.
      2. Explicit enumeration: numbered table (device, model, serial, size,
         bus, media, flags) is printed first.
      3. Never auto-select: no default target, ever. <id> must be a row
         number, a \\.\PhysicalDriveN path, or the exact serial. Wildcards
         (* ? [ ]) are NEVER resolved -- fail closed. An identifier matching
         more than one disk (e.g. duplicated serials) is an ambiguity
         refusal, never first-match-wins.
      4. Boot/USB self-protection: the boot disk, the disk hosting the system
         volume, and USB-attached disks are refused structurally UNLESS
         -OverrideBootProtection is given. The override is logged as a
         WARNING and still requires the double-typed confirmation.
      5. Double-typed confirmation: the operator must type the target disk's
         exact serial (or exact device path) TWICE, on a real console.
         Redirected/piped stdin is refused structurally
         ([Console]::IsInputRedirected) -- `echo $serial | ...` can never arm
         a wipe. Y/N is not accepted. A mismatch on EITHER prompt aborts.
      6. Audit record: every run writes timestamp, disk id, mode, and the
         operator-confirmation evidence to a log file.
      7. Final abort window: 5-second countdown after arming (Ctrl-C aborts;
         -NoCountdown only for VM tests).

    The destructive primitive is a full-device zero-fill (diskpart "clean
    all"). WARNING: on flash media (SSD/NVMe/USB flash) a host-side overwrite
    is NIST 800-88 Clear at best -- overprovisioned flash is invisible to
    host writes. For firmware Purge on SSD/NVMe use the Linux-side
    tools/Invoke-Nuke.sh (ATA Secure Erase / NVMe crypto erase).

    VM-ONLY TESTING. NEVER test the armed path on bare metal.

.EXAMPLE
    .\Invoke-PhoenixNuke.ps1
    Enumerate disks and exit (dry-run, the default).

.EXAMPLE
    .\Invoke-PhoenixNuke.ps1 -Nuke 1
    Arm destruction of row 1 (interactive, double-typed confirmation).

.EXAMPLE
    .\Invoke-PhoenixNuke.ps1 -Nuke "WD-WCC4N1234567" -LogDir C:\phoenix-logs
    Arm by exact serial with an explicit log directory.

.NOTES
    Requires elevation (block-device access). Exit codes:
      0 = enumerate/dry-run OK
      1 = error / refusal (fail closed)
      2 = operator aborted at confirmation
#>
[CmdletBinding()]
param(
    # Disk identifier to arm: row number from the table, \\.\PhysicalDriveN
    # path, or the exact disk serial. No default -- absence means dry-run.
    [string]$Nuke = "",

    # Enumerate only and exit (the default behavior; explicit spelling).
    [Alias("WhatIf")]
    [switch]$DryRun,

    # Override log directory (default: .\phoenix-logs).
    [string]$LogDir = "",

    # Explicit override of the boot/USB self-protection heuristic. Still
    # requires the double-typed confirmation; the override is logged.
    [switch]$OverrideBootProtection,

    # Skip the final 5-second abort window (VM tests only).
    [switch]$NoCountdown,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VERSION = "0.1.0"
$PROG = "Invoke-PhoenixNuke"

#===============================================================================
# helpers
#===============================================================================
function Get-UtcStamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

$script:AuditFile = ""

function Write-Audit {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string]$DiskDevice = "",
        [string]$Serial = "",
        [string]$Model = "",
        [string]$SizeBytes = "",
        [string]$Detail = ""
    )
    $line = "[$(Get-UtcStamp)] mode=$Mode"
    if ($DiskDevice) { $line += " dev=$DiskDevice" }
    if ($Serial)     { $line += " serial=$Serial" }
    if ($Model)      { $line += " model=`"$Model`"" }
    if ($SizeBytes)  { $line += " size_bytes=$SizeBytes" }
    $line += " override_boot_protection=$($OverrideBootProtection.IsPresent)"
    if ($Detail)     { $line += " $Detail" }
    Write-Host $line
    if ($script:AuditFile) { Add-Content -Path $script:AuditFile -Value $line }
}

function Fail {
    param([string]$Message)
    Write-Host "[$PROG] FATAL: $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    @"
Phoenix NUKE core v$VERSION -- nuclear disk sanitization (Windows side)

Usage:
  .\Invoke-PhoenixNuke.ps1
      Enumerate disks and exit (dry-run, the default)
  .\Invoke-PhoenixNuke.ps1 -DryRun
      Same as above (explicit); -WhatIf is an alias
  .\Invoke-PhoenixNuke.ps1 -Nuke <id>
      Arm destruction of disk <id> (interactive, double-typed confirmation)
  .\Invoke-PhoenixNuke.ps1 -Nuke <id> -LogDir <dir>
      Override the audit-log directory
  .\Invoke-PhoenixNuke.ps1 -Nuke <id> -OverrideBootProtection
      Allow a boot/USB disk as the target (logged WARNING; confirmation still
      required twice). Without this flag boot/USB disks are refused.

<id>: row number from the enumeration table, a \\.\PhysicalDriveN path, or
      the disk's exact serial number. Wildcards are never resolved; ambiguous
      identifiers fail closed.

RULES: no flags = enumerate only. No default target. The boot disk / USB
disks are refused unless -OverrideBootProtection. Arming requires typing the
target disk's serial (or device path) TWICE on a real console -- redirected
stdin can never arm a wipe. Full audit log is written to the log directory.
VM-ONLY TESTING. NEVER test destructive paths on bare metal.
"@
}

function Get-MediaClass {
    param([string]$BusType, [bool]$IsSpinning)
    switch ($BusType) {
        "NVMe" { return "NVMe SSD" }
        "SATA" { if ($IsSpinning) { return "HDD" } else { return "SATA SSD" } }
        "USB"  { if ($IsSpinning) { return "USB HDD" } else { return "USB flash/SSD" } }
        "RAID" { return "RAID member" }
        default { return "Unknown ($BusType)" }
    }
}

function Format-Size {
    param([UInt64]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N1} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    return "{0:N0} MB" -f ($Bytes / 1MB)
}

#===============================================================================
# enumeration
#===============================================================================
function Get-PhoenixDiskTable {
    $systemDriveLetter = $env:SystemDrive.Substring(0, 1)
    $systemDiskNumber = $null
    try {
        $systemDiskNumber = (Get-Partition -DriveLetter $systemDriveLetter -ErrorAction Stop).DiskNumber
    } catch { }

    $rows = @()
    $rowNum = 0
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $rowNum++
        $serial = if ($d.SerialNumber) { $d.SerialNumber.Trim() } else { "unknown" }
        $device = "\\.\PhysicalDrive$($d.Number)"
        $flags = @()
        $protectedReason = ""

        $isBootish = $d.IsBoot -or $d.IsSystem -or ($null -ne $systemDiskNumber -and $d.Number -eq $systemDiskNumber)
        if ($isBootish) {
            $flags += "BOOT-USB"
            $protectedReason = "boot-device"
        } elseif ($d.BusType -eq "USB") {
            $flags += "USB"
            $protectedReason = "usb-device"
        }

        $rows += [pscustomobject]@{
            Row             = $rowNum
            Number          = $d.Number
            Device          = $device
            Model           = $d.FriendlyName
            Serial          = $serial
            SizeBytes       = $d.Size
            Bus             = $d.BusType
            Media           = (Get-MediaClass $d.BusType $false)
            Flags           = ($flags -join " ")
            ProtectedReason = $protectedReason
        }
    }
    return $rows
}

function Show-DiskTable {
    param([array]$Table)
    Write-Host "======================================================================"
    Write-Host " PHOENIX NUKE CORE -- disk enumeration ($(Get-UtcStamp))"
    Write-Host "======================================================================"
    $fmt = "{0,-3} {1,-22} {2,-30} {3,-22} {4,-9} {5,-6} {6,-14} {7}"
    Write-Host ($fmt -f "#", "DEVICE", "MODEL", "SERIAL", "SIZE", "BUS", "MEDIA", "FLAGS")
    Write-Host "----------------------------------------------------------------------"
    foreach ($r in $Table) {
        $model = if ($r.Model.Length -gt 30) { $r.Model.Substring(0, 30) } else { $r.Model }
        $serial = if ($r.Serial.Length -gt 22) { $r.Serial.Substring(0, 22) } else { $r.Serial }
        Write-Host ($fmt -f $r.Row, $r.Device, $model, $serial,
            (Format-Size $r.SizeBytes), $r.Bus, $r.Media, $r.Flags)
    }
    Write-Host "----------------------------------------------------------------------"
    Write-Host " $($Table.Count) disk(s) detected. No -Nuke given: dry-run, nothing destroyed."
    Write-Host "======================================================================"
}

#===============================================================================
# identifier resolution -- exact matches only, fail closed on ambiguity
#===============================================================================
function Resolve-PhoenixDiskId {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][array]$Table)

    if ($Id -match '[*?\[\]]') {
        throw "REFUSED: identifier '$Id' contains wildcard characters -- wildcards are never resolved."
    }

    # Row number.
    if ($Id -match '^\d+$') {
        $n = [int]$Id
        if ($n -ge 1 -and $n -le $Table.Count) { return $Table[$n - 1] }
        throw "REFUSED: row '$Id' is out of range (1..$($Table.Count))."
    }

    # Serial: must match EXACTLY ONE disk. A serial reported by more than one
    # disk is identity failure -- never first-match-wins.
    $bySerial = @($Table | Where-Object { $_.Serial -ceq $Id })
    if ($bySerial.Count -gt 1) {
        throw "REFUSED: identifier '$Id' is ambiguous -- $($bySerial.Count) disks report serial '$Id'. Use a row number or device path; the serial alone cannot identify one disk."
    }
    if ($bySerial.Count -eq 1) { return $bySerial[0] }

    # Device path: exact, case-sensitive match.
    $byDev = @($Table | Where-Object { $_.Device -ceq $Id })
    if ($byDev.Count -eq 1) { return $byDev[0] }

    throw "REFUSED: no disk matches identifier '$Id'."
}

#===============================================================================
# double-typed confirmation -- real console only, never piped
#===============================================================================
function Read-DoubleConfirmation {
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Device
    )
    if ([Console]::IsInputRedirected) {
        Write-Audit -Mode "REFUSED" -DiskDevice $Device -Serial $Serial `
            -Detail "reason=`"stdin-redirected`""
        Fail "REFUSED: confirmation stdin is redirected -- piped or scripted input cannot arm a wipe. Type the serial at the console."
    }

    $t1 = Read-Host "Type the disk serial '$Serial' to ARM (attempt 1 of 2)"
    $t2 = Read-Host "Type the disk serial '$Serial' AGAIN to confirm destruction (attempt 2 of 2)"
    $t1 = $t1.Trim(); $t2 = $t2.Trim()

    $ok1 = ($t1 -ceq $Serial) -or ($t1 -ceq $Device)
    $ok2 = ($t2 -ceq $Serial) -or ($t2 -ceq $Device)
    if ($ok1 -and $ok2) {
        Write-Audit -Mode "CONFIRMED" -DiskDevice $Device -Serial $Serial `
            -Detail "typed1=`"$t1`" typed2=`"$t2`""
        return $true
    }
    Write-Audit -Mode "ABORTED" -DiskDevice $Device -Serial $Serial `
        -Detail "typed1=`"$t1`" typed2=`"$t2`""
    return $false
}

#===============================================================================
# destruction -- full-device zero-fill (diskpart "clean all")
#===============================================================================
function Invoke-ZeroFill {
    param([Parameter(Mandatory)][pscustomobject]$Disk)

    if ($Disk.Media -like "*SSD*" -or $Disk.Media -like "*NVMe*" -or $Disk.Media -like "*flash*") {
        Write-Audit -Mode "WARNING" -DiskDevice $Disk.Device -Serial $Disk.Serial `
            -Detail "reason=`"flash-media-zero-fill-is-Clear-at-best`""
        Write-Host "WARNING: $($Disk.Media) -- host-side zero-fill is NIST 800-88 Clear at best on flash media." -ForegroundColor Yellow
        Write-Host "WARNING: for firmware Purge on SSD/NVMe use the Linux-side tools/Invoke-Nuke.sh." -ForegroundColor Yellow
    }

    $script = "select disk $($Disk.Number)`r`nclean all`r`n"
    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value $script -Encoding Ascii
    try {
        Write-Audit -Mode "EXECUTING" -DiskDevice $Disk.Device -Serial $Disk.Serial `
            -Detail "method=`"diskpart-clean-all`""
        $t0 = Get-Date
        $out = & diskpart /s $tmp 2>&1
        $t1 = Get-Date
        Add-Content -Path $script:AuditFile -Value ($out -join "`n")
        Write-Audit -Mode "COMPLETE" -DiskDevice $Disk.Device -Serial $Disk.Serial `
            -Detail "elapsed_s=$([int]($t1 - $t0).TotalSeconds)"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

#===============================================================================
# main
#===============================================================================
if ($Help) { Show-Usage; exit 0 }

# Elevation check: block-device access requires admin.
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail "Must run elevated (block-device access required)." }

# Audit log location.
$logDirPath = if ($LogDir) { $LogDir } else { Join-Path (Get-Location) "phoenix-logs" }
try { New-Item -ItemType Directory -Path $logDirPath -Force | Out-Null }
catch { Fail "Cannot create log dir '$logDirPath': $($_.Exception.Message)" }
$script:AuditFile = Join-Path $logDirPath ("phoenix-nuke-audit-{0:yyyyMMddTHHmmssZ}.log" -f (Get-Date).ToUniversalTime())
New-Item -ItemType File -Path $script:AuditFile -Force | Out-Null

$table = Get-PhoenixDiskTable
Show-DiskTable $table

if (-not $Nuke -or $DryRun) {
    # Dry-run default: enumerate and exit. Nothing is armed, nothing logged
    # beyond the enumeration audit record.
    $devList = ($table | ForEach-Object { "$($_.Device):$($_.Serial)" }) -join ","
    Write-Audit -Mode "ENUMERATE_DRYRUN" -Detail "disks=$($table.Count) list=`"$devList`""
    exit 0
}

# --- resolve the target: exact match or fail closed ---
try {
    $target = Resolve-PhoenixDiskId -Id $Nuke -Table $table
} catch {
    Write-Audit -Mode "REFUSED" -Detail "reason=`"unresolved-id`" id=`"$Nuke`" message=`"$($_.Exception.Message)`""
    Fail $_.Exception.Message
}

# --- boot/USB self-protection (heuristic; explicit override only) ---
if ($target.ProtectedReason -and -not $OverrideBootProtection) {
    Write-Audit -Mode "REFUSED" -DiskDevice $target.Device -Serial $target.Serial `
        -Model $target.Model -SizeBytes $target.SizeBytes `
        -Detail "reason=`"$($target.ProtectedReason)`""
    Fail "REFUSED: $($target.Device) ($($target.Serial)) is $($target.ProtectedReason -replace '-',' ') and is self-protected. Re-run with -OverrideBootProtection to proceed anyway."
}
if ($target.ProtectedReason -and $OverrideBootProtection) {
    Write-Audit -Mode "WARNING" -DiskDevice $target.Device -Serial $target.Serial `
        -Detail "reason=`"boot-protection-overridden`" was=`"$($target.ProtectedReason)`""
    Write-Host "WARNING: boot/USB self-protection OVERRIDDEN for $($target.Device)." -ForegroundColor Yellow
}

# --- structural refusals: identity first (fail fast on ambiguity) ---
# A serial reported by more than one disk is identity failure -- typed
# confirmation cannot prove WHICH disk was meant, so arming is refused no
# matter how the disk was selected (row, device path, or serial).
if ($target.Serial -and $target.Serial -ne "unknown") {
    $dupCount = @($table | Where-Object { $_.Serial -ceq $target.Serial }).Count
    if ($dupCount -gt 1) {
        Write-Audit -Mode "REFUSED" -DiskDevice $target.Device -Serial $target.Serial `
            -Detail "reason=`"dup-serial`""
        Fail "REFUSED: serial '$($target.Serial)' is reported by multiple disks -- identity ambiguous. Aborting."
    }
}

# --- structural refusals: no serial, no identity, no arming ---
if (-not $target.Serial -or $target.Serial -eq "unknown") {
    Write-Audit -Mode "REFUSED" -DiskDevice $target.Device `
        -Detail "reason=`"no-serial`""
    Fail "REFUSED: $($target.Device) reports no serial number -- cannot satisfy typed confirmation. Aborting."
}

Write-Host ""
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host "!!  YOU ARE ABOUT TO IRREVERSIBLY DESTROY ALL DATA ON THIS DISK     !!" -ForegroundColor Red
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host "  Device : $($target.Device)"
Write-Host "  Model  : $($target.Model)"
Write-Host "  Serial : $($target.Serial)"
Write-Host "  Size   : $(Format-Size $target.SizeBytes)"
Write-Host "  Media  : $($target.Media)  (bus: $($target.Bus))"
Write-Host "  Method : diskpart 'clean all' (full-device zero-fill)"
Write-Host ""
Write-Host "  This is NOT recoverable. There is no undo."
Write-Host ""

# --- double-typed confirmation, real console only ---
if (-not (Read-DoubleConfirmation -Serial $target.Serial -Device $target.Device)) {
    Write-Host "Aborted. Confirmation did not match on both prompts. Nothing was destroyed." -ForegroundColor Yellow
    exit 2
}
Write-Host "CONFIRMED twice -- destruction ARMED." -ForegroundColor Red

# --- final abort window ---
if (-not $NoCountdown) {
    Write-Host ""
    Write-Host "Armed. Starting destruction in 5 seconds -- press Ctrl-C to abort."
    for ($s = 5; $s -ge 1; $s--) { Write-Host -NoNewline "$s... "; Start-Sleep -Seconds 1 }
    Write-Host ""
}

# --- last-second re-verification: the device must still be the same disk ---
$recheck = Get-Disk -Number $target.Number -ErrorAction SilentlyContinue
$reSerial = if ($recheck -and $recheck.SerialNumber) { $recheck.SerialNumber.Trim() } else { "" }
if ($reSerial -cne $target.Serial) {
    Write-Audit -Mode "ABORTED" -DiskDevice $target.Device -Serial $target.Serial `
        -Detail "reason=`"identity-changed`" now=`"$reSerial`""
    Fail "Device identity changed mid-run ('$reSerial' != '$($target.Serial)'). Aborting -- hardware state is not trustworthy."
}

Invoke-ZeroFill -Disk $target
Write-Host ""
Write-Host "NUKE COMPLETE: $($target.Device) destroyed (full-device zero-fill)." -ForegroundColor Red
Write-Host "Audit: $script:AuditFile"
