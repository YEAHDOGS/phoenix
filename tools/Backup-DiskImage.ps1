<#
.SYNOPSIS
    Phoenix BACKUP phase: full-disk image of the source drive (WinPE / staging side twin).
.DESCRIPTION
    PowerShell twin of tools/Backup-DiskImage.sh. Same gates, same proof
    artifacts, against an inventory produced by Get-DiskInventory.ps1:

      Backup-DiskImage -Dest <dir> -DiskId <n> [-StateDir <dir>] [-InventoryJson <json>]

    Gates, in order:
      1. source disk: enumerated, readable serial, no mounted partitions
      2. destination: exists, >= full source size free, NOT on the source disk
         (writing the image onto the disk being imaged is refused, hard)
      3. typed confirmation: exact "SERIAL MODEL" (or "IMAGE SERIAL MODEL") on
         a real console -- piped/redirected input is refused
      4. image via raw \\.\PhysicalDriveN read, SHA-256 hashed during the
         write, verified after, then <label>.img + .img.sha256 +
         <label>-manifest.json + backup-image-proof.json are recorded

    The proof file is the artifact the nuke phase's image-proof gate consumes
    ("verified image or no wipe").

    STAGING-ONLY: this verifies the flow on a working machine. Imaging a live
    Windows system disk cannot produce a clean image -- the real run happens
    from the boot environment, where nothing is mounted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dest,
    [Parameter(Mandatory = $true)][int]$DiskId,
    [string]$StateDir = "",
    [string]$InventoryJson = ""
)

$ErrorActionPreference = "Stop"
$BackupGatesVersion = "0.1.0"

if ($StateDir -eq "") { $StateDir = Join-Path $Dest "phoenix-state" }
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }

function Write-BackupLog {
    param([string]$Dir, [string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path (Join-Path $Dir "backup-gates.log") -Value "[$ts] $Message"
}

function Test-IsInteractiveConsole {
    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}

function Get-TargetField {
    param($Inventory, [int]$Id, [string]$Field)
    $d = $Inventory.disks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $d) { throw "[backup-gates] REFUSED: no disk with id $Id." }
    return $d.$Field
}

function Assert-BackupSource {
    param($Inventory, [int]$Id)
    $serial = Get-TargetField $Inventory $Id "serial"
    if ([string]::IsNullOrWhiteSpace($serial)) {
        throw "[backup-gates] REFUSED: disk [$Id] has no readable serial -- it can never be an image source."
    }
    $mounted = Get-TargetField $Inventory $Id "mounted"
    if ($mounted) {
        throw "[backup-gates] REFUSED: disk [$Id] has mounted partitions -- unmount everything before imaging."
    }
    return @{
        Serial    = $serial
        Model     = (Get-TargetField $Inventory $Id "model")
        Dev       = (Get-TargetField $Inventory $Id "dev")
        SizeBytes = [UInt64](Get-TargetField $Inventory $Id "size_bytes")
        SizeHuman = (Get-TargetField $Inventory $Id "size_human")
    }
}

function Assert-BackupDestination {
    param([string]$Dir, [UInt64]$SizeBytes, [string]$SourceDev)
    if (-not (Test-Path $Dir -PathType Container)) {
        throw "[backup-gates] REFUSED: destination is not a directory: $Dir"
    }
    # source disk number from "\\.\PhysicalDriveN"
    if ($SourceDev -notmatch 'PhysicalDrive(\d+)') {
        throw "[backup-gates] REFUSED: cannot parse source disk number from dev: $SourceDev"
    }
    $srcNum = [int]$Matches[1]
    # destination volume -> its disk number; refuse if it IS the source disk
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path $Dir).Path)
    $driveLetter = $root.TrimEnd('\', ':')
    try {
        $part = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        if ($part.DiskNumber -eq $srcNum) {
            throw "[backup-gates] REFUSED: destination lives on the source disk (Disk $($part.DiskNumber)) -- the image would overwrite what it is imaging."
        }
    } catch {
        if ($_.Exception.Message -like "[backup-gates]*") { throw }
        throw "[backup-gates] REFUSED: could not map destination to a physical disk: $($_.Exception.Message)"
    }
    $drive = Get-PSDrive ($driveLetter) -ErrorAction Stop
    $free = [UInt64]$drive.Free
    if ($free -lt $SizeBytes) {
        throw "[backup-gates] REFUSED: destination has ${free}B free but the source needs ${SizeBytes}B (full-size headroom required)."
    }
    Write-Host "[backup-gates] destination OK: $Dir (${free}B free, need ${SizeBytes}B)"
}

function Confirm-ImageTarget {
    param([string]$Serial, [string]$Model, [string]$SizeHuman, [int]$Id, [string]$Dir)
    if (-not (Test-IsInteractiveConsole)) {
        throw "[backup-gates] REFUSED: console input is redirected. Confirmation must be typed interactively."
    }
    Write-Host "======================================================================"
    Write-Host " IMAGE TARGET CARD -- an image of the wrong disk wastes hours"
    Write-Host "----------------------------------------------------------------------"
    Write-Host "  [$Id] $Model"
    Write-Host "      Serial : $Serial"
    Write-Host "      Size   : $SizeHuman"
    Write-Host "----------------------------------------------------------------------"
    Write-Host " To ARM the imaging, type the serial and model EXACTLY as shown above:"
    Write-Host "    $Serial $Model"
    Write-Host " (or: IMAGE $Serial $Model)"
    Write-Host " Anything else aborts. This cannot be scripted."
    Write-Host "======================================================================"
    $answer = ([Console]::ReadLine() | ForEach-Object { $_.Trim() })
    if (($answer -ceq "$Serial $Model") -or ($answer -ceq "IMAGE $Serial $Model")) {
        Write-BackupLog $Dir "CONFIRMED image target id=$Id serial=$Serial model=`"$Model`""
        Write-Host "[backup-gates] target confirmed and logged."
        return
    }
    Write-BackupLog $Dir "REJECTED image confirmation attempt for id=$Id (input did not match)"
    throw "[backup-gates] ABORTED: typed confirmation did not match. Nothing was imaged."
}

function New-DiskImage {
    param([string]$SourceDev, [string]$Dir, [string]$Label, $Source, [string]$StateDir)
    $img = Join-Path $Dir "$Label.img"
    if (Test-Path $img) {
        throw "[backup-gates] REFUSED: $img already exists -- will not overwrite an existing image."
    }
    $started = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-BackupLog $StateDir "START image dev=$SourceDev -> $img serial=$($Source.Serial)"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] (4MB)
    $read = $null; $written = 0
    try {
        $read = New-Object System.IO.FileStream($SourceDev, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $write = New-Object System.IO.FileStream($img, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            while (($n = $read.Read($buf, 0, $buf.Length)) -gt 0) {
                $write.Write($buf, 0, $n)
                $sha.TransformBlock($buf, 0, $n, $null, 0) | Out-Null
                $written += $n
            }
            $sha.TransformFinalBlock($buf, 0, 0) | Out-Null
        } finally { $write.Close() }
    } finally { if ($read) { $read.Close() } }
    $hash = ([BitConverter]::ToString($sha.Hash)).Replace("-", "").ToLowerInvariant()
    $finished = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # independent verify pass: re-hash the written file
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    $v = [System.IO.File]::OpenRead($img)
    try { $vHash = ([BitConverter]::ToString($sha2.ComputeHash($v))).Replace("-", "").ToLowerInvariant() }
    finally { $v.Close() }
    if ($vHash -cne $hash) { throw "[backup-gates] FAILED: post-write hash verification failed." }

    "$hash  $([System.IO.Path]::GetFileName($img))" | Out-File -FilePath "$img.sha256" -Encoding ascii -NoNewline

    $manifest = [ordered]@{
        schema      = "phoenix-backup-manifest/1"
        label       = $Label
        image       = [System.IO.Path]::GetFileName($img)
        sha256      = $hash
        image_bytes = $written
        source      = [ordered]@{
            serial     = $Source.Serial
            model      = $Source.Model
            dev        = $Source.Dev
            size_bytes = $Source.SizeBytes
            size_human = $Source.SizeHuman
        }
        tool        = "Backup-DiskImage.ps1/$BackupGatesVersion"
        started_at  = $started
        finished_at = $finished
        verified    = $true
    }
    $manifestPath = Join-Path $StateDir "$Label-manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding utf8

    $proof = [ordered]@{
        schema      = "phoenix-image-proof/1"
        serial      = $Source.Serial
        model       = $Source.Model
        image       = $img
        sha256      = $hash
        verified    = $true
        verified_at = $finished
        manifest    = $manifestPath
    }
    $proof | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $StateDir "backup-image-proof.json") -Encoding utf8

    Write-BackupLog $StateDir "DONE image $img sha256=$hash"
    Write-Host "[backup-gates] image verified: $img sha256:$($hash.Substring(0, 16))..."
    return @{ Path = $img; Sha256 = $hash }
}

function Test-ImageProof {
    param([string]$Dir, [string]$Serial)
    $proofPath = Join-Path $Dir "backup-image-proof.json"
    if (-not (Test-Path $proofPath)) {
        throw "[backup-gates] REFUSED: no backup-image-proof.json in $Dir -- image the disk before any wipe."
    }
    $proof = Get-Content $proofPath -Raw | ConvertFrom-Json
    if ($proof.schema -ne "phoenix-image-proof/1") { throw "[backup-gates] REFUSED: unknown proof schema." }
    if ($proof.verified -ne $true) { throw "[backup-gates] REFUSED: proof is not marked verified." }
    if ($proof.serial -cne $Serial) { throw "[backup-gates] REFUSED: proof is for serial $($proof.serial), not $Serial." }
    if (-not (Test-Path $proof.image)) { throw "[backup-gates] REFUSED: proof image missing: $($proof.image)." }
    if (-not (Test-Path ($proof.image + ".sha256"))) { throw "[backup-gates] REFUSED: sha256 sidecar missing." }
    $recorded = ((Get-Content ($proof.image + ".sha256") -Raw).Split())[0]
    if ($recorded -cne $proof.sha256) { throw "[backup-gates] REFUSED: sha256 sidecar does not match proof." }
    Write-Host "[backup-gates] image proof OK: $Serial verified image $([System.IO.Path]::GetFileName($proof.image))"
}

# --- main ----------------------------------------------------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($InventoryJson -ne "") {
    $inv = Get-Content $InventoryJson -Raw | ConvertFrom-Json
} else {
    $inv = & "$here\Get-DiskInventory.ps1" | ConvertFrom-Json
}

Write-Host "[Backup-DiskImage] disk inventory:"
foreach ($d in $inv.disks) {
    $flag = if ($d.mounted) { " [MOUNTED - refused]" } else { "" }
    $serial = if ($d.serial) { $d.serial } else { "(no serial - refused)" }
    Write-Host "  [$($d.id)] $($d.model)  SN $serial  $($d.size_human)$flag"
}

$src = Assert-BackupSource $inv $DiskId
Assert-BackupDestination $Dest $src.SizeBytes $src.Dev
Confirm-ImageTarget $src.Serial $src.Model $src.SizeHuman $DiskId $StateDir

$label = "phoenix-image-" + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd") + "-" + $src.Serial
$result = New-DiskImage $src.Dev $Dest $label $src $StateDir
Test-ImageProof $StateDir $src.Serial

Write-Host "[Backup-DiskImage] BACKUP COMPLETE: $($result.Path)"
Write-Host "[Backup-DiskImage] sha256: $($result.Sha256)"
Write-Host "[Backup-DiskImage] proof: $(Join-Path $StateDir 'backup-image-proof.json')  (the nuke phase must consume this before any wipe)"
