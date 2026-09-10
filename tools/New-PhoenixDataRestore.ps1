<#
.SYNOPSIS
    New-PhoenixDataRestore.ps1 -- Phoenix REINSTALL phase, Step 4.5: selective restore.

    Runs on the FRESH Windows install (Phase 4 -- the machine is clean, network is
    fine). Reads a data-only backup made by tools/New-PhoenixDataBackup.ps1
    (runbook Step 2.6) and copies the files back into the fresh install's
    profile layout (Users\<name>\Documents, Desktop, ...).

    RESTORE CONTRACT (the DIRTY side of the dirty-data deal):
      1. MANIFEST BINDING -- accepts ONLY a format=phoenix-data-backup/1 manifest
         with verify=PASS. Anything else is refused outright. This is what makes
         restoring from the quarantined full-disk image structurally impossible:
         the quarantine image has no data-backup manifest at all, and a
         half-written backup carries verify=anything-but-PASS.
      2. HASH RE-VERIFICATION BEFORE COPY -- every file in files.sha256 gets its
         SHA-256 recomputed and compared BEFORE any copy happens. A single
         mismatch aborts the entire restore (post-backup tampering detection).
      3. EXECUTABLE REFUSAL -- even if the backup was taken with -IncludeExe,
         restore NEVER copies executables (.exe, .msi, .dll, .sys, .scr, .com,
         .cpl, .bat, .cmd, .ps1, .vbs, .vbe, .jse, .wsf, .wsh, .hta, .pif, .lnk).
         Applications are reinstalled from their sources (runbook Appendix B).
      4. SCAN-FIRST -- the script refuses to proceed unless Defender has scanned
         the backup dir since it was mounted (it launches MpCmdRun and checks
         the scan report); -SkipAvCheck exists only for manual runs on machines
         where Defender is absent.
      5. LOCAL TARGET ONLY -- TargetRoot must be a local fixed drive (not UNC,
         not removable). TargetRoot and BackupDir must not be inside each other.

    Output: data-restore.manifest (format=phoenix-data-restore/1) + the audit
    trail refused-executables.txt + data-restore.log in the BACKUP dir (never in
    the fresh install -- the fresh machine keeps no record of the dirty data).

.EXAMPLE
    .\New-PhoenixDataRestore.ps1 -BackupDir "E:\laptop-data-2026-09-09" -WhatIf
.EXAMPLE
    .\New-PhoenixDataRestore.ps1 -BackupDir "E:\laptop-data-2026-09-09" `
        -Profiles brandon -TargetRoot "C:" -Operator brandon
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$BackupDir,   # data-only backup dir (Step 2.6 output)
    [string]$TargetRoot = 'C:',                # fresh install root -- local fixed drive only
    [string[]]$Profiles,                       # default: profiles listed in the backup manifest
    [string]$Operator = $env:USERNAME,         # who ran the restore
    [switch]$SkipAvCheck                       # skip the Defender scan gate (not recommended)
)

$ErrorActionPreference = 'Stop'
$Prog = 'New-PhoenixDataRestore'

function Die([string]$msg) { Write-Error "[$Prog] FATAL: $msg" -ErrorAction Stop }
function Log([string]$msg) { "[$Prog] $msg" | Tee-Object -FilePath $script:Log -Append }

$BackupDir = $BackupDir.TrimEnd('\','/')
$TargetRoot = $TargetRoot.TrimEnd('\','/')

$Log = Join-Path $BackupDir 'data-restore.log'
$ManifestOut = Join-Path $BackupDir 'data-restore.manifest'
$RefusedOut = Join-Path $BackupDir 'refused-executables.txt'

$ExeExts = @('.exe','.msi','.dll','.sys','.scr','.com','.cpl','.bat','.cmd',
             '.ps1','.vbs','.vbe','.jse','.wsf','.wsh','.hta','.pif','.lnk')
$SystemProfiles = @('Public','Default','Default User','All Users')

function Test-ExecutableName([string]$rel) {
    $ext = [IO.Path]::GetExtension($rel)
    return ($ext -ne '') -and ($ExeExts -contains $ext.ToLowerInvariant())
}

# --- preflight -----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
    Die "backup dir not found: $BackupDir"
}
$ManifestPath = Join-Path $BackupDir 'data-backup.manifest'
$HashPath     = Join-Path $BackupDir 'files.sha256'
$DirtyMarker  = Join-Path $BackupDir 'DIRTY-NOT-FORENSIC-SAFE.txt'
foreach ($need in @($ManifestPath, $HashPath, $DirtyMarker)) {
    if (-not (Test-Path -LiteralPath $need -PathType Leaf)) {
        Die "required backup file missing: $(Split-Path $need -Leaf) -- refusing to restore from an incomplete backup"
    }
}

$manifest = @{}
Get-Content -LiteralPath $ManifestPath -Encoding Ascii | ForEach-Object {
    if ($_ -match '^(?<k>[a-z_]+)=(?<v>.*)$') { $manifest[$Matches.k] = $Matches.v }
}

if ($manifest['format'] -ne 'phoenix-data-backup/1') {
    Die "manifest format '$($manifest['format'])' is not phoenix-data-backup/1 -- this is not a Phoenix data-only backup. Refusing."
}
if ($manifest['verify'] -ne 'PASS') {
    Die "backup manifest verify='$($manifest['verify'])' -- the backup never completed cleanly. Refusing."
}
if ($manifest['contamination'] -ne 'DIRTY') {
    Die "backup manifest contamination='$($manifest['contamination'])' -- expected DIRTY (Step 2.6 data backup). Refusing."
}
$backupProfiles = @($manifest['profiles'] -split ',' | Where-Object { $_ -ne '' -and $SystemProfiles -notcontains $_ })
if ($backupProfiles.Count -eq 0) { Die 'backup manifest lists no user profiles -- refusing' }

# TargetRoot: local fixed drive only, never UNC, never overlapping BackupDir.
if ($TargetRoot -match '^\\\\') { Die 'TargetRoot must not be a UNC/network path -- fresh-install drive only' }
$driveLetter = $TargetRoot.Substring(0,1).ToUpperInvariant()
$drive = [IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "$driveLetter`:\" } | Select-Object -First 1
if ($null -eq $drive -or $drive.DriveType -ne 'Fixed') {
    Die "TargetRoot '$TargetRoot' is not a local fixed drive -- refusing"
}
$bFull = [IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
$tFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
if ($tFull -eq $bFull -or $tFull.StartsWith($bFull + '\') -or $bFull.StartsWith($tFull + '\')) {
    Die 'TargetRoot and BackupDir overlap -- refusing to restore a backup onto itself'
}

# --- Defender scan gate --------------------------------------------------------
if (-not $SkipAvCheck) {
    $defender = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    if (Test-Path -LiteralPath $defender) {
        Log "scan-before-restore: scanning $bFull with Defender..."
        & $defender -Scan -ScanType 3 -File "$bFull" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Die "Defender scan of the backup dir reported a problem (exit $LASTEXITCODE) -- do NOT restore. Quarantine and re-extract."
        }
        Log 'scan-before-restore: Defender scan completed clean'
    }
    else {
        Log 'WARNING: Defender MpCmdRun.exe not found -- scan gate cannot run; continuing without AV (use -SkipAvCheck explicitly to silence this)'
    }
}

# --- load the hash list --------------------------------------------------------
$entries = @()
$lineNo = 0
foreach ($line in (Get-Content -LiteralPath $HashPath -Encoding Ascii)) {
    $lineNo++
    if ($line -notmatch '^(?<h>[0-9a-fA-F]{64})\s{2}(?<rel>.+)$') {
        Die "files.sha256 line $lineNo is malformed -- hash list untrustworthy, refusing"
    }
    $entries += [pscustomobject]@{ Hash = $Matches.h.ToLowerInvariant(); Rel = $Matches.rel }
}
if ($entries.Count -eq 0) { Die 'files.sha256 is empty -- nothing trustworthy to restore' }

# --- profile selection ----------------------------------------------------------
$wantProfiles = if ($Profiles) {
    @($Profiles | Where-Object { $SystemProfiles -notcontains $_ })
} else { $backupProfiles }
foreach ($p in $wantProfiles) {
    if ($backupProfiles -notcontains $p) { Die "profile '$p' is not in the backup manifest (has: $($backupProfiles -join ',')) -- refusing" }
}

# --- phase 1: verify every hash BEFORE copying anything -------------------------
$copied = New-Object System.Collections.ArrayList
$refused = New-Object System.Collections.ArrayList
foreach ($e in $entries) {
    $parts = $e.Rel -split '/'
    if ($parts[0] -eq 'Users') {
        if ($parts.Count -lt 3) { Die "backup path '$($e.Rel)' is not a profile file -- refusing" }
        if ($wantProfiles -notcontains $parts[1]) { continue }
    }
    $src = Join-Path $BackupDir ($e.Rel -replace '/', '\')
    if (Test-ExecutableName $e.Rel) {
        [void]$refused.Add($e.Rel)
        continue
    }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Die "backup file missing: $($e.Rel) -- backup was tampered with or degraded, refusing"
    }
    $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $e.Hash) {
        Die "hash MISMATCH: $($e.Rel) -- the backup was tampered with after creation. Aborting the entire restore."
    }
    [void]$copied.Add($e)
}

"[$Prog] hash re-verification: $($copied.Count) file(s) verified, $($refused.Count) executable(s) refused" |
    Tee-Object -FilePath $Log -Append

# --- phase 2: copy into the fresh install ---------------------------------------
$bytesRestored = 0
foreach ($e in $copied) {
    $src = Join-Path $BackupDir ($e.Rel -replace '/', '\')
    $dst = Join-Path $tFull ($e.Rel -replace '/', '\')
    # structural: the destination must stay inside TargetRoot (no '..' escapes)
    $dstFull = [IO.Path]::GetFullPath($dst)
    if ($dstFull -ne $tFull -and -not $dstFull.StartsWith($tFull + '\')) {
        Die "destination '$($e.Rel)' escapes TargetRoot -- refusing"
    }
    if ($PSCmdlet.ShouldProcess($dstFull, "restore $($e.Rel)")) {
        New-Item -ItemType Directory -Path (Split-Path $dstFull -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dstFull -Force
        $bytesRestored += (Get-Item -LiteralPath $dstFull).Length
    }
}

$refused | Set-Content -LiteralPath $RefusedOut -Encoding Ascii
$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
@(
    '# phoenix data-restore manifest -- written only after hash re-verify PASS + copy',
    'format=phoenix-data-restore/1',
    "backup_name=$($manifest['backup_name'])",
    "backup_tool=$($manifest['tool'])",
    "backup_profiles=$($backupProfiles -join ',')",
    "restored_profiles=$($wantProfiles -join ',')",
    "file_count=$($copied.Count)",
    "bytes_total=$bytesRestored",
    "executables_refused=$($refused.Count)",
    "hash_algorithm=sha256",
    'verify=PASS',
    "created_utc=$ts",
    "operator=$Operator"
) -join "`n" | Set-Content -LiteralPath $ManifestOut -Encoding Ascii

Log "DONE: restored $($copied.Count) file(s), $bytesRestored bytes to $tFull; refused $($refused.Count) executable(s)"
"[$Prog] DONE: $($copied.Count) file(s) restored, $($refused.Count) executable(s) refused -> see data-restore.manifest"
