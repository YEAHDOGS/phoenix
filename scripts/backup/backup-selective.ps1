<#
.SYNOPSIS
    Phoenix selective backup (Windows side): copies only data + validated
    config per app profiles. Cache and executables are NEVER touched.

.DESCRIPTION
    Reads phoenix-profile/v1 JSON profiles from the sibling ../profiles dir,
    expands %VAR% env paths, and either:
      - Plan (default): read-only listing of what WOULD be backed up,
        what would be JSON-validated, and what is explicitly SKIPPED.
      - Execute: copies data + valid config to $Dest\<app>\, and writes
        manifest.json with SHA-256 hashes of every copied file.

    Invalid JSON config files are quarantined (logged, not copied).
    Binary credential blobs (cookies, login DBs) are classified cache by the
    profiles and never restored.

.PARAMETER App
    One app id (e.g. "chrome") or "all". Default: all.
.PARAMETER Dest
    Backup destination root (e.g. the Castle 10TB target). Required for -Execute.
.PARAMETER ProfileDir
    Defaults to ..\profiles relative to this script.
.PARAMETER Execute
    Actually copy. Without it, plan mode only.
#>
[CmdletBinding()]
param(
    [string]$App = "all",
    [string]$ProfileDir = (Join-Path $PSScriptRoot ".." ".." "profiles"),
    [string]$Dest = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

function Expand-ProfilePath([string]$p) {
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Test-ConfigValid([string]$path) {
    if ($path -match '\.json$') {
        try { Get-Content -Raw $path | ConvertFrom-Json | Out-Null; return $true }
        catch { return $false }
    }
    return $true  # non-JSON config: no structural check available, trust profile notes
}

$profiles = Get-ChildItem $ProfileDir -Filter *.json | Where-Object {
    ($App -eq "all") -or ($_.BaseName -eq $App)
}
if (-not $profiles) { Write-Error "No profiles found in $ProfileDir (App='$App')"; exit 1 }

$manifest = @()
$quarantined = @()
$plan = @()

foreach ($pf in $profiles) {
    $profile = Get-Content -Raw $pf.FullName | ConvertFrom-Json
    foreach ($loc in $profile.locations) {
        foreach ($raw in $loc.windows) {
            $path = Expand-ProfilePath $raw
            $exists = Test-Path $path
            $entry = [pscustomobject]@{
                App   = $profile.app
                Class = $loc.class
                Path  = $path
                Found = $exists
                Action = switch ($loc.class) {
                    "data"       { if ($exists) { "BACKUP" } else { "missing (skip)" } }
                    "config"     { if ($exists) { "VALIDATE-THEN-BACKUP" } else { "missing (skip)" } }
                    "cache"      { "SKIP (cache)" }
                    "executable" { "SKIP (executable — reinstall clean)" }
                    default      { "SKIP (unknown class)" }
                }
            }
            $plan += $entry

            if ($Execute -and $exists -and ($loc.class -eq "data" -or $loc.class -eq "config")) {
                if (-not $Dest) { Write-Error "-Execute requires -Dest"; exit 1 }
                $ok = $true
                if ($loc.class -eq "config") {
                    # Validate every .json file under the location before copying
                    $bad = Get-ChildItem $path -Recurse -File -Include *.json -ErrorAction SilentlyContinue |
                           Where-Object { -not (Test-ConfigValid $_.FullName) }
                    if ($bad) {
                        $ok = $false
                        foreach ($b in $bad) { $quarantined += $b.FullName }
                    }
                }
                if ($ok) {
                    $rel = $path -replace '^[A-Za-z]:', '' -replace '\\', '/'
                    $target = Join-Path $Dest ($profile.app + $rel)
                    $parent = Split-Path $target -Parent
                    if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent | Out-Null }
                    Copy-Item -Recurse -Force $path $target
                    Get-ChildItem $target -Recurse -File | ForEach-Object {
                        $manifest += [pscustomobject]@{
                            app  = $profile.app
                            file = $_.FullName.Substring($Dest.Length + 1)
                            sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
                        }
                    }
                }
            }
        }
    }
}

Write-Host "`n=== Phoenix selective backup plan (App=$App) ===`n" -ForegroundColor Cyan
$plan | Format-Table -AutoSize App, Class, Action, Path | Out-String | Write-Host

if ($Execute) {
    if (-not $Dest) { Write-Error "-Execute requires -Dest"; exit 1 }
    $manifestPath = Join-Path $Dest "manifest.json"
    $manifest | ConvertTo-Json -Depth 4 | Set-Content $manifestPath
    Write-Host "`n[+] Copied $($manifest.Count) files -> $Dest" -ForegroundColor Green
    Write-Host "[+] manifest.json written ($manifestPath)" -ForegroundColor Green
    if ($quarantined) {
        Write-Host "`n[!] QUARANTINED (invalid config, not copied):" -ForegroundColor Yellow
        $quarantined | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
} else {
    Write-Host "`n(plan mode — nothing copied. pass -Execute -Dest <path> to back up)" -ForegroundColor DarkGray
}
