<#
.SYNOPSIS
    Phoenix emergency Phase 2.2: interlocked disk imaging (Windows / WinPE side).

.DESCRIPTION
    Bash twin: scripts/emergency/image_disk.sh (Linux / Rescuezilla side).
    Same contract:
      1. Pre-flight safety checklist: explicit disk enumeration (Get-Disk),
         structural refusals, typed SERIAL+MODEL confirmation on a real
         console ([Console]::IsInputRedirected is refused -- no pipes).
      2. Bit-for-bit image of the source to <DestDir>\<Label>.img with
         progress, hashing SHA-256 on the fly via .NET crypto streams.
      3. SHA-256 manifest <Label>.manifest.csv in the Path,Hash CSV contract
         of scripts/checksum/check.ps1 (verifiable by check.ps1/compare.ps1).
      4. -Verify switch: re-reads the written image and compares its hash
         against the manifest before reporting success.

    Raw disks are opened as \\.\PhysicalDrive<N> (admin rights required).
    Regular files are accepted as sources too (smoke-test "disks").

.PARAMETER Source
    Physical disk number (e.g. 0, 1 -- as shown by Get-Disk), a
    \\.\PhysicalDrive<N> path, or a regular file path (test mode).

.PARAMETER DestDir
    Directory that receives <Label>.img and <Label>.manifest.csv.

.PARAMETER Label
    Image file name stem. Example: laptop-fulldisk-2026-09-10.

.PARAMETER Verify
    Re-read the written image and compare SHA-256 before reporting success.

.PARAMETER FixtureConfirm
    TEST HOOK ONLY: value compared against the expected confirmation string
    in place of the interactive TTY check. Never set in production.

.EXAMPLE
    .\Invoke-Image.ps1 -Source 1 -DestDir E:\ -Label laptop-fulldisk-2026-09-10 -Verify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$DestDir,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$Verify,
    [string]$FixtureConfirm
)

$ErrorActionPreference = "Stop"

# Exit-code contract mirrors image_disk.sh:
#   0 imaged+verified | 1 imaging/verification failure | 2 bad args |
#   3 confirmation refused | 4 destination exists |
#   5 safety interlock tripped.

$destImg      = Join-Path $DestDir "$Label.img"
$destManifest = Join-Path $DestDir "$Label.manifest.csv"

if (Test-Path $destImg -PathType Leaf) {
    Write-Error "REFUSED: destination already exists: $destImg -- refusing to overwrite."
    exit 4
}
if (Test-Path $destManifest -PathType Leaf) {
    Write-Error "REFUSED: manifest already exists: $destManifest -- refusing to overwrite."
    exit 4
}

# --- Resolve + enumerate the source -------------------------------------------
$srcPath = $null
$srcModel = ""
$srcSerial = ""

if ($Source -match '^\d+$') {
    # Disk number -> \\.\PhysicalDrive<N>, identity from Get-Disk (never memory).
    $disk = Get-Disk -Number ([int]$Source) -ErrorAction Stop
    $srcPath   = "\\.\PhysicalDrive$($disk.Number)"
    $srcModel  = ($disk.FriendlyName ?? "UNKNOWN-MODEL").Trim()
    $srcSerial = ($disk.SerialNumber ?? "UNKNOWN-SERIAL").Trim()

    if ($disk.IsBoot) {
        Write-Error "REFUSED: disk $($disk.Number) is the boot disk -- it is this machine's drive, not the imaging target."
        exit 5
    }
    if ($disk.IsSystem) {
        Write-Error "REFUSED: disk $($disk.Number) is a system disk -- refusing."
        exit 5
    }
}
elseif ($Source -match 'PhysicalDrive') {
    Write-Error "Pass a disk NUMBER (as shown by Get-Disk), not a PhysicalDrive path."
    exit 2
}
elseif (Test-Path $Source -PathType Leaf) {
    # File-backed source (smoke-test "disks"). Identity contract stays identical.
    $srcPath   = (Resolve-Path $Source).Path
    $srcModel  = "FILE-BACKED-DISK"
    $srcSerial = Split-Path $Source -Leaf
    if ($srcPath -eq $destImg) {
        Write-Error "REFUSED: source and destination are the same path."
        exit 5
    }
}
else {
    Write-Error "Source not found: $Source"
    exit 2
}

$confirmExpected = "$srcSerial $srcModel"

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host "  PHOENIX PHASE 2.2 -- DISK IMAGING" -ForegroundColor Yellow
Write-Host "  Read every line. This is the step the nuke gate depends on." -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Enumerated disks on THIS machine (the imaging host):"
Get-Disk | Format-Table Number, FriendlyName, SerialNumber,
    @{ n = "Size"; e = { "{0:N1} GiB" -f ($_.Size / 1GB) } },
    BusType -AutoSize | Out-String | Write-Host
Write-Host "  (FriendlyName and SerialNumber are what the confirmation gate reads.)"
Write-Host ""
Write-Host "SOURCE : $srcPath"
Write-Host "TARGET : $destImg  (+ $Label.manifest.csv)"
Write-Host "IDENTITY FOR CONFIRMATION:"
Write-Host "  $confirmExpected"
Write-Host ""

# --- Typed confirmation: real console only ------------------------------------
if ($FixtureConfirm) {
    # Test hook only (never set in production).
    if ($FixtureConfirm -ne $confirmExpected) {
        Write-Error "Fixture confirmation mismatch -- aborted."
        exit 3
    }
    Write-Host "[fixture] confirmation accepted."
}
elseif ([Console]::IsInputRedirected) {
    Write-Error "stdin is redirected -- typed confirmation refused. Run interactively on the imaging host."
    exit 3
}
else {
    $answer = Read-Host "Type the identity EXACTLY as shown above to arm the imaging (anything else aborts)"
    if ($answer -ne $confirmExpected) {
        Write-Host "Aborted. No image written." -ForegroundColor Red
        exit 3
    }
}

# --- Imaging: streamed copy with on-the-fly SHA-256 + progress ---------------
if (-not (Test-Path $DestDir -PathType Container)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

$inStream = $null
try {
    $inStream = [System.IO.File]::Open($srcPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    $totalBytes = $inStream.Length
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $crypto = New-Object System.Security.Cryptography.CryptoStream(
        ([System.IO.Stream]$inStream), $sha, [System.Security.Cryptography.CryptoStreamMode]::Read)
    $outStream = [System.IO.File]::Create($destImg)

    $buffer = New-Object byte[] (4MB)
    $copied = [long]0
    $lastPct = -1
    Write-Host "[1/3] Imaging $srcPath -> $destImg ..." -ForegroundColor Cyan
    try {
        while (($read = $crypto.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $copied += $read
            if ($totalBytes -gt 0) {
                $pct = [int](($copied * 100) / $totalBytes)
                if ($pct -ne $lastPct -and ($pct % 5 -eq 0 -or $pct -eq 100)) {
                    $lastPct = $pct
                    Write-Progress -Activity "Imaging disk" -Status "$pct% ($([long]($copied/1MB)) MiB)" -PercentComplete $pct
                }
            }
        }
    }
    finally {
        $outStream.Close()
        $crypto.Close()
        $inStream.Close()
    }
    Write-Progress -Activity "Imaging disk" -Completed

    $hashHex = [System.Convert]::ToHexString($sha.Hash).ToLowerInvariant()

    Write-Host "[2/3] Writing SHA-256 manifest $destManifest ..." -ForegroundColor Cyan
    $csv = @(
        "Path,Hash"
        ("`"$destImg`",$hashHex")
    ) -join "`r`n"
    Set-Content -Path $destManifest -Value $csv -Encoding UTF8
    Write-Host "      sha256($Label.img) = $hashHex"

    if ($Verify) {
        Write-Host "[3/3] Verifying: re-reading image and re-hashing ..." -ForegroundColor Cyan
        $vStream = [System.IO.File]::OpenRead($destImg)
        $vSha = [System.Security.Cryptography.SHA256]::Create()
        $reHash = [System.Convert]::ToHexString($vSha.ComputeHash($vStream)).ToLowerInvariant()
        $vStream.Close()
        if ($reHash -ne $hashHex) {
            Write-Error "VERIFICATION FAILED -- re-read hash differs from manifest. The image is NOT trustworthy. Do not proceed to the nuke phase."
            exit 1
        }
        Write-Host "      re-read hash matches manifest. Image verified." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "IMAGING COMPLETE." -ForegroundColor Green
    Write-Host "  image   : $destImg"
    Write-Host "  manifest: $destManifest"
    Write-Host "  sha256  : $hashHex"
    Write-Host "Next: copy to Castle with scripts\emergency\Send-ImageToCastle.ps1 (Phase 2.6)."
}
catch {
    Write-Error "Imaging failed: $($_.Exception.Message)"
    exit 1
}
