<#
.SYNOPSIS
    New-PhoenixDataBackup.ps1 -- Phoenix BACKUP phase, Step 2.6: data-only backup.

    WinPE twin of tools/phoenix-data-backup.sh. Copies user data (NOT the whole
    disk) out of an infected Windows volume -- typically C: under WinPE -- to a
    SECOND, SEPARATE direct-attached USB target: Documents, Desktop, Downloads,
    Pictures, Videos, Music, .ssh, plus operator-nominated extras. The full-disk
    image (tools/phoenix-backup.sh or tools/New-PhoenixBackup.ps1) is the
    quarantine archive; THIS backup is what Phase 4 restores from, so it is
    treated as DIRTY: executables are skipped by default (recorded in
    skipped-executables.txt), every file gets a SHA-256 hash, and the output
    carries a scan-before-restore marker.

    PARITY CONTRACT (same as the bash tool, enforced by
    tests/tools/test-phoenix-data-backup.sh T7):
      - same manifest schema: format=phoenix-data-backup/1, backup_name,
        file_count, bytes_total, executables_skipped, hash_algorithm=sha256,
        contamination=DIRTY, operator, verify=PASS
      - same dirty-data contract: executables skipped unless -IncludeExe,
        SHA-256 per file in files.sha256, DIRTY-NOT-FORENSIC-SAFE.txt marker
      - same fail-closed posture: refuses network targets (UNC path or
        non-local drive), refuses --out inside the source volume, refuses a
        source that does not look like a Windows volume (no Users\ dir)

    AIR-GAP: never backs up to a network path. The target must be a local,
    direct-attached drive. Copying to Castle's 10TB drive happens from a
    clean machine (runbook Step 2.7).

.EXAMPLE
    .\New-PhoenixDataBackup.ps1 -Source "C:" -Out "E:\laptop-data-2026-09-09" `
        -Operator brandon
.EXAMPLE
    .\New-PhoenixDataBackup.ps1 -SourceDir "C:" -Out "E:\laptop-data-2026-09-09" `
        -Profiles "brandon" -Extra @("Ableton Projects","license-keys.txt")
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Drive')]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$Source,                        # source drive, e.g. "C:"

    [Parameter(Mandatory, ParameterSetName = 'Dir')]
    [string]$SourceDir,                     # already-mounted volume root

    [Parameter(Mandatory)][string]$Out,     # backup dir on the USB target

    [string[]]$Profiles,                    # default: all non-system profiles

    [string[]]$Extra,                       # paths relative to the volume root

    [string]$Operator = $env:USERNAME,      # who ran it

    [switch]$IncludeExe                     # copy executables too (NOT recommended)
)

$ErrorActionPreference = 'Stop'
$Prog = 'New-PhoenixDataBackup'

function Die([string]$msg) { Write-Error "[$Prog] FATAL: $msg" -ErrorAction Stop }

$ProfileFolders = @('Documents','Desktop','Downloads','Pictures','Videos','Music','.ssh')
$SystemProfiles = @('Public','Default','Default User','All Users')
$ExeExts = @('.exe','.msi','.dll','.sys','.scr','.com','.cpl','.bat','.cmd','.ps1','.vbs','.vbe','.jse','.wsf','.wsh','.hta','.pif','.lnk')

# --- resolve the source volume root ---------------------------------------------------
$SourceRoot = if ($PSCmdlet.ParameterSetName -eq 'Drive') { "$Source\" } else { $SourceDir }
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    Die "source '$SourceRoot' is not a directory"
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'Users') -PathType Container)) {
    Die "'$SourceRoot' has no Users\ dir -- not a Windows volume root (refusing)"
}

# --- fail closed: --out must be local and outside the source volume -------------------
if ($Out -match '^(\\\\|//)') { Die "--out looks like a network path '$Out' -- refusing (air-gap)" }
$OutFull = [IO.Path]::GetFullPath($Out)
$SrcFull = [IO.Path]::GetFullPath($SourceRoot)
if ($OutFull -eq $SrcFull -or $OutFull.StartsWith($SrcFull + [IO.Path]::DirectorySeparatorChar)) {
    Die "--out is inside the source volume -- refusing"
}
try {
    $Drive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $OutFull.StartsWith($_.Root, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object { $_.Root.Length } -Descending | Select-Object -First 1
    if ($null -ne $Drive -and $Drive.DisplayRoot) {
        Die "--out is on a mapped network drive ($($Drive.DisplayRoot)) -- refusing (air-gap)"
    }
} catch { Die "cannot determine drive locality for --out -- refusing" }

# --- resolve the profile list ---------------------------------------------------------
$Want = @()
if ($Profiles -and $Profiles.Count -gt 0) {
    $Want = $Profiles
} else {
    $Want = Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'Users') -Directory -ErrorAction Stop |
        Where-Object { $SystemProfiles -notcontains $_.Name } |
        Select-Object -ExpandProperty Name
}
foreach ($p in $Want) {
    if ($p -notmatch '^[A-Za-z0-9_.\ -]{1,64}$') { Die "profile name '$p' has unsafe characters -- refusing" }
}
if ($Want.Count -eq 0) { Die "no user profiles found -- refusing" }

# --- build the copy plan -----------------------------------------------------------------
$Roots = @()
foreach ($p in $Want) {
    foreach ($f in $ProfileFolders) {
        $d = Join-Path (Join-Path (Join-Path $SourceRoot 'Users') $p) $f
        if (Test-Path -LiteralPath $d -PathType Container) { $Roots += $d }
        else { Write-Host "[$Prog] note: $p\$f absent, skipping" }
    }
}
foreach ($x in @($Extra)) {
    if ([string]::IsNullOrWhiteSpace($x)) { continue }
    if ([IO.Path]::IsPathRooted($x)) { Die "--extra paths must be relative to the volume root (got '$x')" }
    if ($x -match '(^|[\\/])\.\.([\\/]|$)') { Die "--extra path '$x' escapes the volume root -- refusing" }
    $d = Join-Path $SourceRoot $x
    if (Test-Path -LiteralPath $d) { $Roots += $d }
    else { Write-Host "[$Prog] note: extra '$x' absent, skipping" }
}
if ($Roots.Count -eq 0) { Die "nothing to copy -- no profile folders or extras found" }

# --- copy + hash ------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Log     = Join-Path $Out 'data-backup.log'
$HashOut = Join-Path $Out 'files.sha256'
$SkipOut = Join-Path $Out 'skipped-executables.txt'
"[$Prog] data-only backup: $SourceRoot -> $Out" | Tee-Object -FilePath $Log

$fileCount = 0; $byteTotal = [long]0; $skipCount = 0
$hashLines = New-Object System.Collections.Generic.List[string]
$skipLines = New-Object System.Collections.Generic.List[string]

foreach ($r in $Roots) {
    $relBase = [IO.Path]::GetRelativePath($SourceRoot, $r)
    "[$Prog] copying $relBase ..." | Tee-Object -FilePath $Log -Append
    # Record the executables we are about to skip (enumerated from SOURCE --
    # robocopy's /XF never copies them, so the destination cannot recount them).
    if (-not $IncludeExe) {
        Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $ExeExts -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object {
                $skipLines.Add([IO.Path]::GetRelativePath($SourceRoot, $_.FullName))
                $script:skipCount++
            }
    }
    $robArgs = @($r, (Join-Path $Out $relBase), '/E', '/COPY:DAT', '/R:2', '/W:2',
                 '/NJH', '/NJS', '/NP', '/NDL', '/NFL')
    if (-not $IncludeExe) {
        $robArgs += @('/XF') + ($ExeExts | ForEach-Object { "*$_" })
    }
    # Robocopy does the bulk copy; we then hash the result so the manifest's
    # file_count/bytes_total reflect exactly what is on disk.
    & robocopy @robArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Die "robocopy failed for '$r' (exit $rc)" }

    Get-ChildItem -LiteralPath (Join-Path $Out $relBase) -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = [IO.Path]::GetRelativePath($Out, $_.FullName)
            $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $hashLines.Add("$h  $rel")
            $script:fileCount++; $script:byteTotal += $_.Length
        }
}

$hashLines | Set-Content -LiteralPath $HashOut -Encoding Ascii
$skipLines | Set-Content -LiteralPath $SkipOut -Encoding Ascii

@'
DIRTY DATA -- TREAT AS SUSPECT
==============================
This folder is a data-only backup taken from a machine SUSPECTED OF INFECTION
(runbook Step 2.6). It is NOT a restore source as-is.

  - Scan every file with an up-to-date AV BEFORE restoring anything.
  - Executables/installers were skipped at backup time (see
    skipped-executables.txt). Reinstall applications from their sources --
    never from this folder.
  - Never boot or mount the full-disk quarantine image on a daily-driver
    machine; forensics access is isolated-only.

files.sha256 lists a SHA-256 for every file copied, so you can detect any
post-backup tampering of this folder.
'@ | Set-Content -LiteralPath (Join-Path $Out 'DIRTY-NOT-FORENSIC-SAFE.txt') -Encoding Ascii

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$backupName = Split-Path $Out -Leaf
$manifest = @(
    '# phoenix data-backup manifest -- written only after copy+hash PASS',
    'format=phoenix-data-backup/1',
    "backup_name=$backupName",
    "source_root=$SourceRoot",
    "profiles=$($Want -join ',')",
    "file_count=$fileCount",
    "bytes_total=$byteTotal",
    "executables_skipped=$skipCount",
    "include_exe=$([int][bool]$IncludeExe)",
    'hash_algorithm=sha256',
    'hash_file=files.sha256',
    'contamination=DIRTY',
    'tool=New-PhoenixDataBackup.ps1',
    "created_utc=$ts",
    "operator=$Operator",
    'verify=PASS'
) -join "`n"
$manifest | Set-Content -LiteralPath (Join-Path $Out 'data-backup.manifest') -Encoding Ascii

"[$Prog] DONE: $fileCount file(s), $byteTotal bytes, $skipCount executable(s) skipped -> $Out" |
    Tee-Object -FilePath $Log -Append
