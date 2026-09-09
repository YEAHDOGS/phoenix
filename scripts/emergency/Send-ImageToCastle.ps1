<#
.SYNOPSIS
    Phoenix emergency Phase 2.6: copy the verified disk image to Castle's 10TB
    drive, then prove the copy is bit-identical.

.DESCRIPTION
    Runbook step 2.6 requires moving the quarantined image OFF the air-gapped
    machine using a clean machine. This script is the clean-machine side:
      1. Fingerprints the image directory (SHA-256 tree fingerprint).
      2. Copies it to the Castle quarantine target (robocopy, no purge).
      3. Re-fingerprints the copy and REFUSES to report success on mismatch.
      4. Writes image-proof.txt (fingerprint + file count + timestamp) next to
         the copy -- the evidence Phase 3's nuke gate checks for.

    Twin: scripts/emergency/Send-ImageToCastle.sh (Linux/clean machine).
    Checksum twins: scripts/checksum/check.ps1 + check.sh (SHA-256 manifests).

.PARAMETER ImageDir
    The image directory on the locally attached USB target (Rescuezilla output).

.PARAMETER Target
    Castle quarantine root. Defaults to $env:PHOENIX_CASTLE_TARGET. Example:
    \\CASTLE\quarantine  (set the real share name before first use -- the
    runbook's Appendix C asks Brandon for the exact path.)

.PARAMETER Label
    Folder name created under Target. Default: QUARANTINE-INFECTED-<yyyy-MM-dd>.

.PARAMETER WhatIf
    Dry run: fingerprint only, no copy, no writes.

.EXAMPLE
    $env:PHOENIX_CASTLE_TARGET = "\\CASTLE\quarantine"
    .\Send-ImageToCastle.ps1 -ImageDir E:\laptop-fulldisk-2026-09-09
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$ImageDir,
    [string]$Target = $env:PHOENIX_CASTLE_TARGET,
    [string]$Label = ("QUARANTINE-INFECTED-" + (Get-Date -Format "yyyy-MM-dd"))
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Error "No Castle target. Set -Target or `$env:PHOENIX_CASTLE_TARGET (e.g. \\CASTLE\quarantine)."
    exit 2
}
if (-not (Test-Path $ImageDir -PathType Container)) {
    Write-Error "ImageDir not found: $ImageDir"
    exit 2
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host "  PHOENIX PHASE 2.6 -- IMAGE TO CASTLE QUARANTINE" -ForegroundColor Yellow
Write-Host "  THIS MUST RUN ON THE CLEAN MACHINE." -ForegroundColor Yellow
Write-Host "  Never run this on the infected laptop." -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host ""

$answer = Read-Host "Type CLEAN to confirm you are on the clean machine (anything else aborts)"
if ($answer -ne "CLEAN") {
    Write-Host "Aborted. Run this from the clean machine only." -ForegroundColor Red
    exit 3
}

function Get-TreeFingerprint([string]$Root) {
    $files = Get-ChildItem -Path $Root -Recurse -File | Sort-Object FullName
    if ($files.Count -eq 0) { throw "No files under $Root -- refusing to fingerprint an empty tree." }
    $lines = foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.TrimEnd('\').Length + 1)
        $stream = [System.IO.File]::OpenRead($f.FullName)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = [System.Convert]::ToHexString($sha.ComputeHash($stream))
        $stream.Close()
        "$rel`:$hash"
    }
    $joined = [string]::Join("`n", $lines)
    $sha2 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $tree = [System.Convert]::ToHexString($sha2.ComputeHash($bytes))
    return @{ Fingerprint = $tree; FileCount = $files.Count }
}

$dest = Join-Path $Target $Label

Write-Host "Source : $ImageDir"
Write-Host "Target : $dest"
Write-Host ""
Write-Host "[1/3] Fingerprinting source image..." -ForegroundColor Cyan
$src = Get-TreeFingerprint $ImageDir
Write-Host "      $($src.FileCount) file(s), tree fingerprint: $($src.Fingerprint)"

if ($PSCmdlet.ShouldProcess($dest, "Copy image to Castle quarantine")) {
    Write-Host "[2/3] Copying to Castle (robocopy, no purge)..." -ForegroundColor Cyan
    if (Test-Path $dest) {
        Write-Error "Destination already exists: $dest -- refusing to merge into an existing quarantine folder."
        exit 4
    }
    New-Item -ItemType Directory -Path $dest | Out-Null
    robocopy $ImageDir $dest /E /R:3 /W:5 /NFL /NDL /NP
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed with exit code $LASTEXITCODE."
        exit 5
    }

    Write-Host "[3/3] Re-fingerprinting the copy..." -ForegroundColor Cyan
    $dst = Get-TreeFingerprint $dest
    Write-Host "      $($dst.FileCount) file(s), tree fingerprint: $($dst.Fingerprint)"

    if ($dst.Fingerprint -ne $src.Fingerprint -or $dst.FileCount -ne $src.FileCount) {
        Write-Error "COPY VERIFICATION FAILED -- fingerprints differ. The Castle copy is NOT trustworthy. Investigate before proceeding to Phase 3."
        exit 6
    }

    $proof = @(
        "Phoenix image proof (Phase 2.6)"
        "label=$Label"
        "source_fingerprint=$($src.Fingerprint)"
        "copy_fingerprint=$($dst.Fingerprint)"
        "file_count=$($src.FileCount)"
        "verified_utc=$([DateTime]::UtcNow.ToString('o'))"
        "algorithm=SHA-256 tree fingerprint (relpath:sha256 per file, sorted, hashed)"
    ) -join "`n"
    Set-Content -Path (Join-Path $dest "image-proof.txt") -Value $proof -Encoding UTF8

    Write-Host ""
    Write-Host "COPY VERIFIED -- $($src.FileCount) file(s), fingerprint match." -ForegroundColor Green
    Write-Host "Proof written to: $(Join-Path $dest 'image-proof.txt')"
    Write-Host "Quarantine label: $Label -- never mount this on a daily-driver machine."
}
