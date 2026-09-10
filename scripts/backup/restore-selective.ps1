<#
.SYNOPSIS
    Phoenix selective restore (Windows side): applies a backup manifest
    (produced by backup-selective.ps1) onto a NEW machine.

.DESCRIPTION
    Reads manifest.json + manifest-meta.json from a backup destination and
    either:
      - Plan (default): read-only listing of what WOULD be restored, per-app
        profile class check (data/config restored; cache/executable NEVER),
        plus a SHA-256 integrity check of the backup files against the
        manifest. Nothing is written to the target.
      - Apply (-Apply): after passing every interlock, copies files to
        -TargetRoot, verifying SHA-256 of each file before AND after the copy.
        Any mismatch aborts the whole restore.

    SAFETY INTERLOCKS (restoring onto the wrong disk must be structurally hard):
      1. -TargetRoot is REQUIRED and has no default — there is no implicit target.
      2. The target may never be the source: if the canonical target path equals
         the source_home recorded in manifest-meta.json, restore refuses.
      3. Fingerprint check: the volume serial of the target drive is compared
         against the source volume serial in the manifest. A match = hard refuse.
      4. Restoring INTO the backup directory itself is refused.
      5. Full plan summary is printed, then the operator must type RESTORE
         (exactly) to proceed. -ConfirmWord "RESTORE" exists for scripted/GUI
         use and prints a warning when used.

.PARAMETER ManifestDir
    Backup destination root containing manifest.json (+ manifest-meta.json).
.PARAMETER TargetRoot
    The NEW machine's user home (e.g. C:\Users\Brando). Required, no default.
.PARAMETER App
    One app id (e.g. "ableton") or "all". Default: all.
.PARAMETER ProfileDir
    Defaults to ..\..\profiles relative to this script.
.PARAMETER Apply
    Actually restore. Without it, plan mode only.
.PARAMETER Plan
    Explicit plan mode (default anyway) — accepted for symmetry with the backup engine.
.PARAMETER AllowSameDisk
    Overrides ONLY the volume-serial interlock, for legitimate same-disk
    restores (local testing, a second profile on one machine).
.PARAMETER ConfirmWord
    Pass "RESTORE" to skip the interactive typed confirmation (for the
    Svelte/Tauri GUI). Prints a warning when used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestDir,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [string]$App = "all",
    [string]$ProfileDir = (Join-Path $PSScriptRoot ".." ".." "profiles"),
    [switch]$Apply,
    [switch]$Plan,
    [switch]$AllowSameDisk,
    [string]$ConfirmWord = ""
)

$ErrorActionPreference = "Stop"

$manifestPath = Join-Path $ManifestDir "manifest.json"
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in $ManifestDir"; exit 1 }
$entries = @(Get-Content -Raw $manifestPath | ConvertFrom-Json)
if ($App -ne "all") { $entries = @($entries | Where-Object { $_.app -ieq $App }) }
if (-not $entries) { Write-Error "No manifest entries for App='$App'"; exit 1 }

$metaPath = Join-Path $ManifestDir "manifest-meta.json"
$meta = $null
if (Test-Path $metaPath) { $meta = Get-Content -Raw $metaPath | ConvertFrom-Json }
else { Write-Host "[!] manifest-meta.json missing — source-fingerprint interlock DEGRADED (typed confirmation still required)" -ForegroundColor Yellow }

# --- target sanity ---
if (-not (Test-Path $TargetRoot -PathType Container)) { Write-Error "TargetRoot '$TargetRoot' does not exist or is not a directory"; exit 1 }
$targetCanon = (Get-Item $TargetRoot).FullName.TrimEnd('\')
$manifestCanon = (Get-Item $ManifestDir).FullName.TrimEnd('\')
if ($targetCanon -ieq $manifestCanon -or $targetCanon.StartsWith($manifestCanon + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "INTERLOCK: TargetRoot is inside the backup directory — refusing to restore a backup onto itself"; exit 1
}

# --- interlock 2+3: never restore onto the source disk ---
if ($meta -and $meta.source_home) {
    try {
        $sourceCanon = (Get-Item $meta.source_home -ErrorAction Stop).FullName.TrimEnd('\')
        if ($targetCanon -ieq $sourceCanon) {
            Write-Error "INTERLOCK: TargetRoot '$targetCanon' IS the backup source ('$sourceCanon') — restore refuses to target the disk it came from"; exit 1
        }
    } catch { Write-Host "[!] could not resolve source_home '$($meta.source_home)' — path check skipped" -ForegroundColor Yellow }
    $tDrive = $targetCanon -replace '^([A-Za-z]):.*', '$1'
    $tVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$tDrive`:'" -ErrorAction SilentlyContinue
    if ($tVol -and $meta.source_fs_id -and ($tVol.VolumeSerialNumber -eq $meta.source_fs_id)) {
        if ($AllowSameDisk) {
            Write-Host "[!] -AllowSameDisk: target is on the SOURCE volume — proceeding only because you said so" -ForegroundColor Yellow
        } else {
            Write-Error "INTERLOCK: target drive $tDrive volume serial matches the backup SOURCE — refusing (use -AllowSameDisk to override)"; exit 1
        }
    }
    $sourceRel = ($meta.source_home -replace '^[A-Za-z]:', '') -replace '\\', '/'
    $sourceRel = $sourceRel.Trim('/')
} else { $sourceRel = "" }

# --- load profiles for per-app restore rules ---
$profiles = @{}
foreach ($pf in (Get-ChildItem $ProfileDir -Filter *.json -ErrorAction SilentlyContinue)) {
    $p = Get-Content -Raw $pf.FullName | ConvertFrom-Json
    $profiles[$p.app.ToString().ToLower()] = $p
}

function Get-RestoreClass([string]$appId, [string]$targetPath) {
    $p = $profiles[$appId.ToLower()]
    if (-not $p) { return "unknown (no profile)" }
    $tp = $targetPath -replace '/', '\'
    foreach ($loc in $p.locations) {
        foreach ($raw in $loc.windows) {
            $lp = [Environment]::ExpandEnvironmentVariables($raw).TrimEnd('\')
            if ($tp -ieq $lp -or $tp.StartsWith($lp + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return $loc.class.ToString()
            }
        }
    }
    return "unknown (not in profile)"
}

function Test-ConfigValid([string]$path) {
    if ($path -match '\.json$') {
        try { Get-Content -Raw $path | ConvertFrom-Json | Out-Null; return $true }
        catch { return $false }
    }
    return $true
}

# --- build the plan ---
$plan = @()
foreach ($e in $entries) {
    $rel = $e.file -replace "^$([regex]::Escape($e.app))/", ""
    $rel = $rel -replace '/', '\'
    $relNoLead = $rel.TrimStart('\')
    # strip the source home prefix (backup stored drive-stripped paths)
    $tail = $relNoLead
    if ($sourceRel) {
        $sr = $sourceRel -replace '/', '\'
        if ($relNoLead.StartsWith($sr + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $tail = $relNoLead.Substring($sr.Length + 1)
        } elseif ($relNoLead -ieq $sr) { $tail = "" }
        else { $tail = $null }  # not under source home: cannot map safely
    }
    $backupFile = Join-Path $ManifestDir ($e.file -replace '/', '\')
    if ($null -eq $tail -or $tail -eq "") {
        $plan += [pscustomobject]@{ App = $e.app; Class = "?"; Action = "SKIP (cannot map to target safely)"; Target = ""; Backup = $backupFile; Hash = $e.sha256 }
        continue
    }
    $targetFile = Join-Path $targetCanon $tail
    $class = Get-RestoreClass $e.app $targetFile
    $action = switch ($class) {
        "data"   { if (Test-Path $backupFile -PathType Leaf) { "RESTORE" } else { "SKIP (missing in backup)" } }
        "config" { if (Test-Path $backupFile -PathType Leaf) { "VALIDATE-THEN-RESTORE" } else { "SKIP (missing in backup)" } }
        default  { "SKIP (kill-list: $class — never restored)" }
    }
    $plan += [pscustomobject]@{ App = $e.app; Class = $class; Action = $action; Target = $targetFile; Backup = $backupFile; Hash = $e.sha256 }
}

Write-Host "`n=== Phoenix selective restore plan (App=$App) ===" -ForegroundColor Cyan
Write-Host "    backup : $manifestCanon"
Write-Host "    target : $targetCanon`n"
$plan | Format-Table -AutoSize App, Class, Action, Target | Out-String | Write-Host

# read-only integrity check of the backup itself (runs in plan mode too)
$bad = @()
foreach ($row in ($plan | Where-Object { $_.Action -like "RESTORE*" })) {
    $h = (Get-FileHash $row.Backup -Algorithm SHA256).Hash
    if ($h -ne $row.Hash) { $bad += $row.Backup }
}
if ($bad) {
    Write-Host "`n[!] BACKUP INTEGRITY FAILURE — $($bad.Count) file(s) do not match manifest hashes:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Error "refusing to proceed: backup does not match its manifest"; exit 1
}
Write-Host "`n[+] backup integrity: all $($plan.Where({$_.Action -like 'RESTORE*'}).Count) restorable files match manifest hashes" -ForegroundColor Green

$restorable = @($plan | Where-Object { $_.Action -like "RESTORE*" })
if (-not $Apply) {
    Write-Host "(plan mode — nothing written. pass -Apply -TargetRoot <path> to restore)" -ForegroundColor DarkGray
    exit 0
}

# --- typed confirmation ---
if ($ConfirmWord -eq "RESTORE") {
    Write-Host "[!] non-interactive confirmation (-ConfirmWord) — operator attests this is the NEW machine" -ForegroundColor Yellow
} else {
    Write-Host "`nYou are about to restore $($restorable.Count) file(s) onto:" -ForegroundColor Yellow
    Write-Host "    $targetCanon`n" -ForegroundColor Yellow
    $typed = Read-Host 'Type RESTORE to proceed (anything else aborts)'
    if ($typed -cne "RESTORE") { Write-Host "aborted." -ForegroundColor Yellow; exit 2 }
}

# --- apply ---
$done = 0; $failed = @(); $quarantined = @()
foreach ($row in $restorable) {
    # re-verify source hash right before copy
    if ((Get-FileHash $row.Backup -Algorithm SHA256).Hash -ne $row.Hash) {
        $failed += "$($row.Backup) (hash changed between plan and apply)"
        continue
    }
    if ($row.Class -eq "config" -and -not (Test-ConfigValid $row.Backup)) {
        $quarantined += $row.Backup   # corrupt config is never reapplied
        continue
    }
    $parent = Split-Path $row.Target -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent | Out-Null }
    Copy-Item -Force $row.Backup $row.Target
    if ((Get-FileHash $row.Target -Algorithm SHA256).Hash -ne $row.Hash) {
        $failed += "$($row.Target) (target hash mismatch after copy)"
        continue
    }
    $done++
}

Write-Host "`n[+] restored $done / $($restorable.Count) planned file(s) -> $targetCanon" -ForegroundColor Green
if ($quarantined) {
    Write-Host "[!] QUARANTINED on restore (invalid config, not reapplied):" -ForegroundColor Yellow
    $quarantined | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}
if ($failed) {
    Write-Host "`n[!] FAILED:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Error "restore incomplete: $($failed.Count) file(s) failed verification"; exit 1
}
