<#
.SYNOPSIS
    Stages the Phoenix analysis toolkit onto build media.

.DESCRIPTION
    Reads tools/analysis-toolkit.manifest.json, downloads each "Download" item
    (or picks up "Manual" drops from <StageRoot>\inbox), optionally extracts it,
    and verifies integrity:

      - Verify=Sha256        -> SHA-256 must match the manifest hash.
      - Verify=Authenticode  -> Get-AuthenticodeSignature must be Valid and the
                               signer subject must contain the manifest value.
      - Verify=TransportOnly -> HTTPS only; emits a loud warning (last resort).

    ANY verification failure deletes the artifact and ABORTS LOUDLY (throw,
    non-zero exit). Missing Manual drops are warnings, not failures.

    RUN ON A CLEAN BUILD MACHINE. Never run on the infected laptop.
    Staged binaries are build-time artifacts and must never be committed
    (staging/ is git-ignored). Follows the SHA-256 pattern of
    scripts/checksum/check.ps1.

.EXAMPLE
    .\tools\Stage-AnalysisTools.ps1
    .\tools\Stage-AnalysisTools.ps1 -StageRoot 'D:\phoenix-staging' -Force
#>
[CmdletBinding()]
param(
    [string]$StageRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'staging\analysis-tools'),
    [string]$Manifest  = (Join-Path $PSScriptRoot 'analysis-toolkit.manifest.json'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Stage([string]$Message, [string]$Level = 'Info') {
    $color = switch ($Level) {
        'OK'   { 'Green'  }
        'Warn' { 'Yellow' }
        'Fail' { 'Red'    }
        default { 'Cyan'  }
    }
    $prefix = switch ($Level) {
        'OK'   { '[OK]   ' }
        'Warn' { '[WARN] ' }
        'Fail' { '[FAIL] ' }
        default { '[....] ' }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Get-Sha256Hex([string]$Path) {
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-Authenticode([string]$Path, [string]$ExpectedSubject) {
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "AUTHENTICODE INVALID for '$Path' (status: $($sig.Status)). File deleted, aborting."
    }
    $subject = $sig.SignerCertificate.Subject
    if ($subject -notmatch [regex]::Escape($ExpectedSubject)) {
        throw "AUTHENTICODE SIGNER MISMATCH for '$Path'. Expected subject containing '$ExpectedSubject', got '$subject'. File deleted, aborting."
    }
    Write-Stage "Authenticode valid, signer: $ExpectedSubject" 'OK'
}

function Assert-Sha256([string]$Path, [string]$ExpectedHex, [string]$ToolName) {
    $actual = Get-Sha256Hex $Path
    $expected = $ExpectedHex.ToUpperInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw @"
CHECKSUM MISMATCH for '$ToolName' — FILE DELETED, STAGING ABORTED.
  Expected: $expected
  Actual:   $actual
  The download may be corrupt, tampered with, or a newer version than the
  manifest records. Update the manifest hash from the vendor's official page
  and re-run. Do NOT bypass this check.
"@
    }
    Write-Stage "SHA-256 verified: $actual" 'OK'
}

function Invoke-VerifiedDownload([string]$Url, [string]$OutFile, [string]$ToolName) {
    $attempts = 0
    $maxAttempts = 3
    while ($true) {
        $attempts++
        try {
            Write-Stage "Downloading ($attempts/$maxAttempts): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            if ($attempts -ge $maxAttempts) { throw "DOWNLOAD FAILED for '$ToolName' after $maxAttempts attempts: $($_.Exception.Message)" }
            Write-Stage "Download attempt $attempts failed, retrying in 5s..." 'Warn'
            Start-Sleep -Seconds 5
        }
    }
}

# ---------------- main ----------------

if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest" }
$manifestObj = Get-Content $Manifest -Raw | ConvertFrom-Json
$inbox = Join-Path $StageRoot 'inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null

$report = @()
$failures = 0

foreach ($tool in $manifestObj.tools) {
    Write-Stage "=== $($tool.Name) ($($tool.Version)) ==="
    $destDir = Join-Path $StageRoot $tool.Subdir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $entry = [ordered]@{
        Name = $tool.Name; Version = $tool.Version; Status = 'pending'
        Path = $null; Sha256 = $null; VerifiedBy = $tool.Verify
    }

    try {
        $targetPath = $null

        if ($tool.Mode -eq 'Download') {
            $targetPath = Join-Path $destDir $tool.FileName
            if ((Test-Path $targetPath) -and -not $Force) {
                Write-Stage "Already staged, verifying existing file: $targetPath" 'Warn'
            } else {
                Invoke-VerifiedDownload -Url $tool.Url -OutFile $targetPath -ToolName $tool.Name
            }
        }
        elseif ($tool.Mode -eq 'Manual') {
            $drop = Get-ChildItem -Path $inbox -Filter $tool.FileName -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $drop) {
                Write-Stage "Manual drop not found in inbox/. Fetch from: $($tool.Url) and place matching '$($tool.FileName)' into $inbox, then re-run." 'Warn'
                $entry.Status = 'missing-manual-drop'
                $report += [pscustomobject]$entry
                continue
            }
            $targetPath = Join-Path $destDir $drop.Name
            Copy-Item -LiteralPath $drop.FullName -Destination $targetPath -Force
            Write-Stage "Picked up manual drop: $($drop.Name)"
        }
        else { throw "Unknown Mode '$($tool.Mode)' for '$($tool.Name)'." }

        $verifyTarget = $targetPath
        if ($tool.Extract) {
            Write-Stage "Extracting archive..."
            Expand-Archive -LiteralPath $targetPath -DestinationPath $destDir -Force
            if ($tool.SignatureCheckFile) {
                $verifyTarget = Join-Path $destDir $tool.SignatureCheckFile
                if (-not (Test-Path $verifyTarget)) { throw "SignatureCheckFile '$($tool.SignatureCheckFile)' not found after extraction." }
            }
        }

        switch ($tool.Verify) {
            'Sha256' {
                Assert-Sha256 -Path $verifyTarget -ExpectedHex $tool.Sha256 -ToolName $tool.Name
            }
            'Authenticode' {
                Test-Authenticode -Path $verifyTarget -ExpectedSubject $tool.AuthenticodeSubject
            }
            'TransportOnly' {
                Write-Stage "NO PUBLISHER HASH OR SIGNATURE AVAILABLE for '$($tool.Name)'. Integrity rests on HTTPS transport from the official source only. Re-verify provenance manually before field use." 'Warn'
            }
            default { throw "Unknown Verify mode '$($tool.Verify)' for '$($tool.Name)'." }
        }

        $entry.Status = 'staged'
        $entry.Path = $targetPath
        try { $entry.Sha256 = Get-Sha256Hex $targetPath } catch { $entry.Sha256 = $null }
        Write-Stage "$($tool.Name) staged at $targetPath" 'OK'
    }
    catch {
        $failures++
        $entry.Status = 'FAILED'
        Write-Stage $_.Exception.Message 'Fail'
        # Fail loudly: stop the whole staging run, do not continue to next tool.
        throw
    }
    finally {
        $report += [pscustomobject]$entry
    }
}

$reportPath = Join-Path $StageRoot 'stage-report.json'
[pscustomobject]@{
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    StageRoot    = $StageRoot
    Manifest     = $Manifest
    Tools        = $report
} | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8

Write-Stage "Stage report written: $reportPath" 'OK'
if ($failures -gt 0) { throw "Staging completed with $failures failure(s). See above." }
Write-Stage "All toolkit items staged and verified." 'OK'
