<#
.SYNOPSIS
    Phoenix BACKUP phase: write an image-proof manifest (PowerShell twin).

.DESCRIPTION
    Exact contract twin of tools/New-ImageProof.sh for the Windows/WinPE
    side. After a full-disk image is created AND its post-backup integrity
    check passes, this tool records the proof that the Nuke phase demands:
    tools/Invoke-Nuke.sh --image-proof <file> refuses to arm without a VALID
    manifest (format phoenix-image-proof/1, verified=YES, 64-hex sha256,
    positive size, source_serial bound to the nuke target).

    The proof is a plain key=value text file -- identical keys, order, and
    filename pattern to the .sh twin so the Linux nuke gate accepts it.
    Keep it on the Phoenix USB (next to the nuke logs) so the Nuke phase
    can read it.

    -Verified asserts YOU watched the backup tool's integrity check pass.
    Without it the manifest records verified=NO and the nuke gate rejects it.

.EXAMPLE
    .\tools\New-ImageProof.ps1 -ImageName laptop-fulldisk-2026-09-09 `
        -ImagePath 'D:\laptop-fulldisk-2026-09-09' `
        -SourceSerial SATATEST001 -SourceDev '\\.\PHYSICALDRIVE0' `
        -Sha256 '<64-hex of the image checksum file>' `
        -Verified -VerifiedBy brandon -OutDir 'E:\phoenix-logs'

    Exit codes: 0 = proof written | 1 = usage/validation error
#>
[CmdletBinding()]
param(
    [string]$ImageName,
    [string]$ImagePath,
    [string]$SourceSerial,
    [string]$SourceDev = '',
    [string]$Sha256,
    [long]$ImageSizeBytes = 0,
    [string]$VerifiedBy,
    [string]$OutDir = '.',
    [switch]$Verified
)

$ErrorActionPreference = 'Stop'

function Die([string]$Message) {
    Write-Error "[New-ImageProof] FATAL: $Message"
    exit 1
}

# --- validation (fail closed, same order and wording as the .sh twin) ---
if ([string]::IsNullOrWhiteSpace($ImageName))    { Die "-ImageName is required" }
if ([string]::IsNullOrWhiteSpace($ImagePath))    { Die "-ImagePath is required" }
if ([string]::IsNullOrWhiteSpace($SourceSerial)) { Die "-SourceSerial is required" }
if ([string]::IsNullOrWhiteSpace($Sha256))       { Die "-Sha256 is required" }
if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$')       { Die "-Sha256 must be 64 hex chars" }
if (-not (Test-Path -LiteralPath $ImagePath))    { Die "-ImagePath '$ImagePath' does not exist" }
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    Die "-OutDir '$OutDir' is not a directory"
}

if ($ImageSizeBytes -le 0) {
    $item = Get-Item -LiteralPath $ImagePath -Force
    if ($item.PSIsContainer) {
        $ImageSizeBytes = (Get-ChildItem -LiteralPath $ImagePath -Recurse -File -Force |
            Measure-Object -Property Length -Sum).Sum
    } else {
        $ImageSizeBytes = $item.Length
    }
}
if ($ImageSizeBytes -le 0) {
    Die "could not determine a positive image size from '$ImagePath'"
}

if ([string]::IsNullOrWhiteSpace($VerifiedBy)) {
    $VerifiedBy = if ($env:USERNAME) { $env:USERNAME } else { 'unknown' }
}

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$proofFile = Join-Path $OutDir "image-proof-${SourceSerial}-${ts}.proof"

# --- write (one Set-Content, no partial output -- file is complete or absent) ---
$verifiedLine = if ($Verified) { 'verified=YES' } else { 'verified=NO' }
@(
    '# phoenix image-proof manifest -- written by New-ImageProof.ps1'
    '# keep on the Phoenix USB; pass to Invoke-Nuke.sh --image-proof'
    'format=phoenix-image-proof/1'
    "image_name=$ImageName"
    "image_path=$ImagePath"
    "source_serial=$SourceSerial"
    "source_dev=$SourceDev"
    "image_size_bytes=$ImageSizeBytes"
    "sha256=$Sha256"
    "created_utc=$ts"
    $verifiedLine
    "verified_by=$VerifiedBy"
) | Set-Content -Path $proofFile -Encoding Ascii

Write-Host "[New-ImageProof] Proof written: $proofFile"
if (-not $Verified) {
    Write-Host "[New-ImageProof] NOTE: verified=NO -- the nuke image-proof gate will REJECT this proof."
    Write-Host "[New-ImageProof] Re-run with -Verified only after the backup tool's integrity check passes."
}
