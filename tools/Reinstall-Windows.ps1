<#
.SYNOPSIS
    Phoenix REINSTALL phase: arm an unattended Windows install onto a
    provably nuked disk (WinPE / staging side twin).
.DESCRIPTION
    PowerShell twin of tools/Reinstall-Windows.sh. Same gates, same proof
    artifacts, against an inventory produced by Get-DiskInventory.ps1:

      Reinstall-Windows -Config <json> -Unattend <file> -Iso <file> -DiskId <n> [-StateDir <dir>] [-InventoryJson <json>]

    Gates, in order:
      1. blank target: readable serial, no mounted partitions, PartitionStyle
         RAW (no partition table), and the first 1 MiB of the raw device is
         all zeros -- the Nuke flow zeroes the leading sectors, so a
         genuinely nuked disk is the ONLY disk that passes
      2. artifacts: staged autounattend.xml + Windows ISO exist, readable,
         non-empty
      3. config match: phoenix-config.json has boot_entries.reinstall enabled,
         reinstall.platform == 'windows', and the answer-file basename
         matches unattend.answer_file
      4. chain of custody: state dir holds backup-image-proof.json
         (schema phoenix-image-proof/1, verified, serial match) AND
         nuke-completed.json (schema phoenix-nuke-completion/1, serial match,
         completed_at present)
      5. typed confirmation: exact "SERIAL MODEL" on a real console --
         piped/redirected input is refused (Confirm-NukeTarget.ps1)

    Like the .sh twin, this script ARMS the install and prints the exact
    next command -- it NEVER launches Windows Setup itself. The gates arm,
    the operator fires.

    STAGING-ONLY: verifies the flow on a working machine / in WinPE. The
    real Phase 4 run happens from the boot environment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Unattend,
    [Parameter(Mandatory = $true)][string]$Iso,
    [Parameter(Mandatory = $true)][int]$DiskId,
    [string]$StateDir = ".\phoenix-state",
    [string]$InventoryJson = ""
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here "Confirm-NukeTarget.ps1")

# SHA-256 of 1 MiB of zero bytes -- the all-zeros constant a nuked disk's
# first megabyte hashes to (see tools/lib/reinstall-gates.sh).
$BlankHash = "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"

function Fail-Gate([string]$Why) { Write-Error "[reinstall] REFUSED: $Why" }

if (-not (Test-Path $Config))    { Fail-Gate "config not found: $Config" }
if (-not (Test-Path $Unattend))   { Fail-Gate "answer file not found: $Unattend" }
if (-not (Test-Path $Iso))        { Fail-Gate "ISO not found: $Iso" }
if ((Get-Item $Unattend).Length -eq 0) { Fail-Gate "answer file is empty: $Unattend" }
if ((Get-Item $Iso).Length -eq 0)      { Fail-Gate "ISO is empty: $Iso" }
Write-Host "[reinstall] artifacts present: $(Split-Path -Leaf $Unattend), $(Split-Path -Leaf $Iso)."

try { $cfg = Get-Content $Config -Raw | ConvertFrom-Json } catch { Fail-Gate "config is not valid JSON: $_" }
if (-not $cfg.boot_entries.reinstall) { Fail-Gate "config boot_entries.reinstall is not enabled." }
$platform = if ($cfg.reinstall -and $cfg.reinstall.platform) { $cfg.reinstall.platform } else { "windows" }
if ($platform -ne "windows") { Fail-Gate "config reinstall.platform is '$platform' (linux blade is future work)." }
$answerFileCfg = if ($cfg.unattend -and $cfg.unattend.answer_file) { $cfg.unattend.answer_file } else { "/autounattend.xml" }
$wantUnattend = [IO.Path]::GetFileName($answerFileCfg)
if ($wantUnattend.ToLower() -ne ([IO.Path]::GetFileName($Unattend)).ToLower()) {
    Fail-Gate "staged answer file '$(Split-Path -Leaf $Unattend)' does not match config unattend.answer_file '$wantUnattend'."
}
Write-Host "[reinstall] config consistent: reinstall enabled, platform windows."

if ($InventoryJson) {
    $inv = Get-Content $InventoryJson -Raw | ConvertFrom-Json
    $disk = $inv.disks | Where-Object { $_.id -eq $DiskId }
    if (-not $disk) { Fail-Gate "no disk with id $DiskId in inventory." }
    $serial = $disk.serial
} else {
    $disk = Get-Disk | Where-Object { $_.Number -eq $DiskId }
    if (-not $disk) { Fail-Gate "no disk number $DiskId." }
    $serial = $disk.SerialNumber.Trim()
}

if (-not $serial) { Fail-Gate "target has no readable serial; it cannot be a reinstall target." }

# Blank-target gate, WinPE edition: RAW partition style + nothing mounted +
# first 1 MiB of the raw device hashes to the all-zeros constant.
$target = Get-Disk | Where-Object { $_.SerialNumber.Trim() -eq $serial }
if ($target.PartitionStyle -ne "RAW") {
    Fail-Gate "target still has a $($target.PartitionStyle) partition table -- it was not nuked."
}
if (Get-Partition -DiskNumber $target.Number -ErrorAction SilentlyContinue) {
    Fail-Gate "target still exposes partitions -- a blank disk has none."
}
$stream = [IO.File]::OpenRead("\\.\PhysicalDrive$($target.Number)")
try {
    $buf = New-Object byte[] 1MB
    $read = $stream.Read($buf, 0, $buf.Length)
    if ($read -ne $buf.Length) { Fail-Gate "could not read the first 1 MiB of the target device." }
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new($buf)) -Algorithm SHA256).Hash.ToLower()
} finally { $stream.Close() }
if ($hash -ne $BlankHash) {
    Fail-Gate "target first-1MiB hash is not all-zeros -- the disk still carries partition/filesystem metadata."
}
Write-Host "[reinstall] target [$DiskId] is provably blank (serial $serial, zeroed leading sectors)."

# Chain of custody: backup proof + nuke record for this exact serial.
$proofPath = Join-Path $StateDir "backup-image-proof.json"
if (-not (Test-Path $proofPath)) { Fail-Gate "no backup-image-proof.json in $StateDir -- the disk was never imaged." }
$proof = Get-Content $proofPath -Raw | ConvertFrom-Json
if ($proof.schema -ne "phoenix-image-proof/1") { Fail-Gate "backup proof schema is '$($proof.schema)'." }
if ($proof.verified -ne $true) { Fail-Gate "backup proof is not verified." }
if ("$($proof.serial)" -ne $serial) { Fail-Gate "backup proof is for serial '$($proof.serial)', target is '$serial'." }
Write-Host "[reinstall] backup chain: verified image proof for serial $serial."

$nukePath = Join-Path $StateDir "nuke-completed.json"
if (-not (Test-Path $nukePath)) { Fail-Gate "no nuke-completed.json in $StateDir -- the disk was never wiped." }
$nuke = Get-Content $nukePath -Raw | ConvertFrom-Json
if ($nuke.schema -ne "phoenix-nuke-completion/1") { Fail-Gate "nuke record schema is '$($nuke.schema)'." }
if ("$($nuke.serial)" -ne $serial) { Fail-Gate "nuke record is for serial '$($nuke.serial)', target is '$serial'." }
if (-not $nuke.completed_at) { Fail-Gate "nuke record has no completed_at timestamp." }
Write-Host "[reinstall] nuke chain: wipe completed $($nuke.completed_at) for serial $serial."

# Typed confirmation on a real console (refuses piped input internally).
Test-IsInteractiveConsole
if ($InventoryJson) {
    Confirm-TypedPair -InventoryJson $InventoryJson -Id $DiskId -StateDir $StateDir
} else {
    Confirm-TypedPair -DiskNumber $target.Number -StateDir $StateDir
}

Write-GateLog -StateDir $StateDir -Message "ARMED reinstall id=$DiskId serial=$serial"

@"

[Reinstall-Windows] ALL GATES PASSED -- install is ARMED, not launched.
Target: serial $serial

Next -- the operator fires Setup manually after a final look at the card:
  Ventoy menu  : boot [4] REINSTALL -- Windows 11 (unattended)
  ISO          : $Iso
  Answer file  : $Unattend

This script intentionally stops here. Typed confirmation is on record in
$StateDir.
"@
