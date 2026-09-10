<#
.SYNOPSIS
    Phoenix BACKUP phase Step 2.7 (Windows twin): quarantine copy of a VERIFIED
    full-disk image to long-term storage (Castle's 10TB drive) from a CLEAN
    machine -- never from the infected laptop (runbook Step 2.7).

.DESCRIPTION
    Copies a verified image to a direct-attached drive, landing in
    QUARANTINE-INFECTED-<date>/ so the infected image is never mistaken for
    a restore source. Exact-contract twin of tools/phoenix-quarantine-copy.sh:
    the quarantine-copy.manifest schema emitted here is byte-compatible with
    the .sh twin's, so a manifest written on Linux verifies identically on
    Windows and vice versa.

    Manifest contract (quarantine-copy.manifest, key order pinned):
        format=phoenix-quarantine-copy/1
        image_name=<basename of source image dir (or manifest's image_name)>
        source_dir=<canonical source path>
        target_dir=<QUARANTINE-INFECTED-<date>/<image_name> on target>
        quarantine_date=<YYYY-MM-DD>
        evidence=manifest|proof
        source_serial=<from backup.manifest or image-proof, may be empty>
        chunk_count=<N>
        bytes_copied=<total chunk bytes>
        source_stream_sha512=<hex128, manifest evidence only>
        source_chunks_concat_sha256=<hex64, manifest evidence only>
        image_proof=<basename, proof evidence only>
        target_fs_type=<e.g. NTFS>
        tool=New-PhoenixQuarantineCopy.ps1
        created_utc=<yyyyMMddTHHmmssZ>
        operator=<who ran it>
        verify=PASS            (written ONLY after verification passes)

    Fail-closed contract (same as the .sh twin):
      - Refuses unless there is machine-readable evidence the image was
        VERIFIED: backup.manifest with format=phoenix-backup/1 AND verify=PASS,
        or -ImageProof pointing at a phoenix-image-proof/1 file with
        verified=YES (mint one with New-ImageProof.ps1 after the Rescuezilla
        post-backup check passes).
      - Refuses network targets: UNC paths and Network-type drives (the
        quarantine copy goes to a DIRECT-ATTACHED drive).
      - Refuses target == source, target inside source, source inside target.
      - Free-space preflight before a single byte is copied.
      - Resumable: chunks already on the target with matching SHA-512 are
        skipped; mismatched ones are re-copied.
      - Verification: per-chunk SHA-512 from .phoenix-backup.state when
        present, then whole-stream SHA-512 and concatenated-chunk SHA-256
        against the manifest (manifest evidence); byte-for-byte
        source-vs-target check per chunk (proof evidence).
      - The quarantine-copy manifest is written with verify=PASS ONLY after
        all checks pass.

.PARAMETER Source
    The verified image directory (contains chunk-*.img.* plus evidence).

.PARAMETER Target
    Direct-attached long-term storage root (NOT the image directory).

.PARAMETER ImageProof
    Optional path to a phoenix-image-proof/1 file (Rescuezilla GUI path).
    Required when the source has no backup.manifest.

.PARAMETER Date
    Quarantine label date, YYYY-MM-DD. Defaults to today (UTC).

.PARAMETER Operator
    Operator name recorded in the manifest. Defaults to $env:USERNAME.

.EXAMPLE
    .\New-PhoenixQuarantineCopy.ps1 -Source E:\laptop-fulldisk-2026-09-09 `
        -Target F:\ -Date 2026-09-09 -Operator founder

.EXAMPLE
    .\New-PhoenixQuarantineCopy.ps1 -Source E:\rescuezilla-img -Target F:\ `
        -ImageProof E:\image-proof-ABC123-20260909T000000Z.proof
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$ImageProof = '',
    [string]$Date = '',
    [string]$Operator = ''
)

$ErrorActionPreference = 'Stop'
$Prog = Split-Path -Leaf $PSCommandPath

$script:LogPath = $null
function Log([string]$msg) {
    $line = "[$Prog] $msg"
    Write-Host $line
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line }
}
function Die([string]$msg, [int]$code = 1) {
    $line = "[$Prog] FATAL: $msg"
    Write-Error $line
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line }
    exit $code
}

# --- defaults -------------------------------------------------------------------
if (-not $Date)     { $Date     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }
if (-not $Operator) { $Operator = $env:USERNAME; if (-not $Operator) { $Operator = $env:USER }; if (-not $Operator) { $Operator = 'unknown' } }

# --- validation (fail closed) ----------------------------------------------------
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Die "--Source '$Source' is not a directory" }
if (-not (Test-Path -LiteralPath $Target -PathType Container)) { Die "--Target '$Target' is not a directory" }
if ($Date -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') { Die "--Date must be YYYY-MM-DD (got '$Date')" }

$CSrc = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
$CTgt = (Resolve-Path -LiteralPath $Target).Path.TrimEnd('\', '/')
if ($CSrc -ieq $CTgt) { Die "--Target is the same directory as --Source -- refusing" }
if ($CTgt.StartsWith($CSrc + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Die "--Target sits INSIDE --Source -- refusing" }
if ($CSrc.StartsWith($CTgt + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Die "--Source sits INSIDE --Target -- refusing" }

# network targets: refused -- direct-attached only (runbook Step 2.7)
if ($Target -match '^(\\\\|//)') { Die "--Target looks like a UNC/network path -- refusing (direct-attached only)" }
try {
    $DriveInfo = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($CTgt))
    $FsType = $DriveInfo.DriveFormat
} catch { $FsType = 'unknown' }
if ($DriveInfo -and $DriveInfo.DriveType -eq [IO.DriveType]::Network) {
    Die "--Target is on a network drive ($($DriveInfo.Name)) -- refusing (direct-attached only)"
}

function Get-ManifestVal([string]$File, [string]$Key) {
    $hit = Select-String -LiteralPath $File -Pattern "^$([regex]::Escape($Key))=(.*)$" -SimpleMatch:$false |
           Select-Object -First 1
    if (-not $hit) { return '' }
    return $hit.Matches[0].Groups[1].Value
}

# --- evidence: verified-image proof (fail closed) --------------------------------
$Evidence = ''; $ImageName = Split-Path -Leaf $CSrc
$SourceSerial = ''; $StreamSha = ''; $ConcatSha = ''; $ManifestComp = ''
$ManSrc = Join-Path $CSrc 'backup.manifest'
if (Test-Path -LiteralPath $ManSrc -PathType Leaf) {
    if ((Get-ManifestVal $ManSrc 'format') -ne 'phoenix-backup/1') {
        Die "backup.manifest has unknown format '$(Get-ManifestVal $ManSrc 'format')' -- refusing"
    }
    if ((Get-ManifestVal $ManSrc 'verify') -ne 'PASS') {
        Die "backup.manifest verify != PASS -- the image is NOT verified, refusing the quarantine copy (run Step 2.4 first)"
    }
    $Evidence = 'manifest'
    $SourceSerial = Get-ManifestVal $ManSrc 'source_serial'
    $StreamSha    = Get-ManifestVal $ManSrc 'stream_sha512'
    $ConcatSha    = Get-ManifestVal $ManSrc 'chunks_concat_sha256'
    $ManifestComp = Get-ManifestVal $ManSrc 'compressor'
    $mn = Get-ManifestVal $ManSrc 'image_name'
    if ($mn) { $ImageName = $mn }
    if ($StreamSha -notmatch '^[0-9a-f]{128}$') { Die "backup.manifest has a bad stream_sha512 -- refusing" }
    if ($ConcatSha -notmatch '^[0-9a-f]{64}$')  { Die "backup.manifest has a bad chunks_concat_sha256 -- refusing" }
} elseif ($ImageProof) {
    if (-not (Test-Path -LiteralPath $ImageProof -PathType Leaf)) { Die "-ImageProof '$ImageProof' does not exist" }
    if ((Get-ManifestVal $ImageProof 'format') -ne 'phoenix-image-proof/1') {
        Die "proof file has unknown format -- refusing"
    }
    if ((Get-ManifestVal $ImageProof 'verified') -ne 'YES') {
        Die "proof file is verified=NO -- the image is NOT verified, refusing (run Step 2.4 first)"
    }
    $Evidence = 'proof'
    $SourceSerial = Get-ManifestVal $ImageProof 'source_serial'
} else {
    Die "no verification evidence: '$Source' has no backup.manifest with verify=PASS and no -ImageProof was given -- refusing (verified image or no quarantine)"
}

# --- chunk inventory -------------------------------------------------------------
$Chunks = @(Get-ChildItem -LiteralPath $CSrc -File -Filter 'chunk-*.img.*' |
            Sort-Object Name | Select-Object -ExpandProperty Name)
if (-not $Chunks -or $Chunks.Count -eq 0) { Die "no chunk-*.img.* files in --Source '$Source' -- refusing" }
$NChunks = $Chunks.Count
$Need = 0
foreach ($c in $Chunks) {
    $sz = (Get-Item -LiteralPath (Join-Path $CSrc $c)).Length
    if ($sz -le 0) { Die "chunk '$c' has zero/unreadable size -- refusing" }
    $Need += $sz
}

# --- destination ------------------------------------------------------------------
$QDir = Join-Path $CTgt "QUARANTINE-INFECTED-$Date"
$Dest = Join-Path $QDir $ImageName
$null = New-Item -ItemType Directory -Force -Path $Dest
$script:LogPath = Join-Path $Dest 'copy.log'
$ManifestOut = Join-Path $Dest 'quarantine-copy.manifest'

Log "quarantine copy: $Source -> $Dest"
Log "evidence=$Evidence ($NChunks chunks, ${Need}B)"

# free-space preflight on the target drive (before a single byte is copied)
$Avail = $null
try { $Avail = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Dest)).AvailableFreeSpace } catch {}
if ($null -eq $Avail) { Die "cannot determine free space on target" }
if ($Avail -lt ($Need + 1MB)) {
    Die "target has ${Avail}B free but the image needs ${Need}B -- refusing"
}

function Get-Sha512Hex([string]$Path) {
    $h = [Security.Cryptography.SHA512]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($h.ComputeHash($fs))).Replace('-', '').ToLower() }
        finally { $fs.Dispose() }
    } finally { $h.Dispose() }
}

function Copy-Chunk([string]$Name) {
    $src = Join-Path $CSrc $Name
    $dst = Join-Path $Dest $Name
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        if ((Get-Sha512Hex $src) -eq (Get-Sha512Hex $dst)) {
            Log "chunk $Name already copied and hash-verified -- skipping"
            return
        }
        Log "chunk $Name present but HASH MISMATCH -- re-copying"
    }
    Log "copying chunk $Name ..."
    $tmp = "$dst.tmp"
    try {
        Copy-Item -LiteralPath $src -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $dst -Force
    } catch { Die "copy failed for chunk $Name -- state kept, re-run to resume ($($_.Exception.Message))" 2 }
    if ((Get-Sha512Hex $src) -ne (Get-Sha512Hex $dst)) {
        Die "post-copy hash mismatch on chunk $Name -- target storage suspect, refusing" 2
    }
}

foreach ($c in $Chunks) { Copy-Chunk $c }

# copy the sidecar evidence files alongside the image (forensics paper trail)
if (Test-Path -LiteralPath $ManSrc -PathType Leaf) {
    Copy-Item -LiteralPath $ManSrc -Destination (Join-Path $Dest 'backup.manifest') -Force
}
$StateSrc = Join-Path $CSrc '.phoenix-backup.state'
$StateDst = Join-Path $Dest '.phoenix-backup.state'
if (Test-Path -LiteralPath $StateSrc -PathType Leaf) {
    Copy-Item -LiteralPath $StateSrc -Destination $StateDst -Force
}
if ($ImageProof) {
    try { Copy-Item -LiteralPath $ImageProof -Destination (Join-Path $Dest (Split-Path -Leaf $ImageProof)) -Force }
    catch { Die "could not copy the image-proof file -- refusing ($($_.Exception.Message))" 2 }
}

# --- verification ------------------------------------------------------------------
# Path A (scripted backup): per-chunk SHA-512 from the backup state file when
# present, then the whole-stream SHA-512 and concatenated-chunk SHA-256 from
# the manifest. Path B (proof evidence): byte-for-byte source-vs-target check.
if ($Evidence -eq 'manifest') {
    if (Test-Path -LiteralPath $StateDst -PathType Leaf) {
        $Want = @{}
        foreach ($line in (Get-Content -LiteralPath $StateDst)) {
            if ($line -match "^chunk`t") {
                $f = $line -split "`t"
                # fields: chunk <idx> <chunkfile> <rsha> <csha> <rbytes> <cbytes>
                if ($f.Count -ge 5) { $Want[(Split-Path -Leaf $f[2])] = $f[4] }
            }
        }
        foreach ($c in $Chunks) {
            if (-not $Want.ContainsKey($c)) { Die "state file has no expected hash for chunk $c -- refusing" 2 }
            $got = Get-Sha512Hex (Join-Path $Dest $c)
            if ($got -ne $Want[$c]) {
                Die "target chunk $c fails per-chunk SHA-512 (expected $($Want[$c]), got $got) -- image corrupt on target" 2
            }
        }
        Log "per-chunk SHA-512: $NChunks/$NChunks match"
    }
    # whole-stream verification: decompress every target chunk in order and
    # hash the stream, exactly like phoenix-backup.sh's own verify pass.
    $streamHash = [Security.Cryptography.SHA512]::Create()
    $concatHash = [Security.Cryptography.SHA256]::Create()
    $zstdExe = $null
    if ($ManifestComp -eq 'zstd') {
        $zstdExe = Get-Command zstd -ErrorAction SilentlyContinue
        if (-not $zstdExe) { Die "chunks are zstd-compressed but zstd is not installed -- cannot verify" 2 }
    } elseif ($ManifestComp -notin 'gzip', 'none') {
        Die "unknown compressor '$ManifestComp' in backup.manifest -- refusing" 2
    }
    $buf = New-Object byte[] (1MB)
    try {
        foreach ($c in $Chunks) {
            $cp = Join-Path $Dest $c
            $cs = [IO.File]::OpenRead($cp)
            try {
                if ($ManifestComp -eq 'gzip') {
                    $ds = New-Object IO.Compression.GZipStream($cs, [IO.Compression.CompressionMode]::Decompress)
                } elseif ($ManifestComp -eq 'zstd') {
                    # zstd has no .NET equivalent: stream the zstd process's
                    # stdout straight into the hash (same external-binary
                    # requirement as the .sh twin -- a missing zstd refused above).
                    $psi = New-Object Diagnostics.ProcessStartInfo
                    $psi.FileName = $zstdExe.Source
                    $psi.Arguments = "-q -d -c -- `"$cp`""
                    $psi.RedirectStandardOutput = $true
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $zp = [Diagnostics.Process]::Start($psi)
                    $ds = $zp.StandardOutput.BaseStream
                    $script:__zp = $zp
                } else {
                    $ds = $cs
                }
                try {
                    while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) {
                        $streamHash.TransformBlock($buf, 0, $n, $null, 0) | Out-Null
                    }
                } finally {
                    if ($ds -ne $cs) {
                        $ds.Dispose()
                        if ($script:__zp) {
                            $script:__zp.WaitForExit()
                            $zcode = $script:__zp.ExitCode
                            $script:__zp.Dispose(); $script:__zp = $null
                            if ($zcode -ne 0) { Die "target chunk $c failed to decompress (zstd exit $zcode) -- copy corrupt, re-run to re-copy it" 2 }
                        }
                    }
                }
            } finally { $cs.Dispose() }
            # concatenated-chunk SHA-256 over the raw compressed bytes
            $rs = [IO.File]::OpenRead($cp)
            try {
                while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
                    $concatHash.TransformBlock($buf, 0, $n, $null, 0) | Out-Null
                }
            } finally { $rs.Dispose() }
        }
        $streamHash.TransformFinalBlock($buf, 0, 0) | Out-Null
        $concatHash.TransformFinalBlock($buf, 0, 0) | Out-Null
    } finally { $streamHash.Dispose(); $concatHash.Dispose() }
    $gotStream = ([BitConverter]::ToString($streamHash.Hash)).Replace('-', '').ToLower()
    $gotConcat = ([BitConverter]::ToString($concatHash.Hash)).Replace('-', '').ToLower()
    if ($gotStream -ne $StreamSha) {
        Die "target stream SHA-512 mismatch (expected $StreamSha, got $gotStream) -- copy corrupt" 2
    }
    Log "stream SHA-512 matches manifest"
    if ($gotConcat -ne $ConcatSha) {
        Die "target chunk-set SHA-256 mismatch -- copy corrupt" 2
    }
    Log "chunk-set SHA-256 matches manifest"
} else {
    # proof evidence: the operator asserted verification via the .proof file;
    # here we prove the COPY is byte-faithful, chunk by chunk.
    foreach ($c in $Chunks) {
        if ((Get-Sha512Hex (Join-Path $CSrc $c)) -ne (Get-Sha512Hex (Join-Path $Dest $c))) {
            Die "target chunk $c differs from source -- copy corrupt" 2
        }
    }
    Log "byte-for-byte source-vs-target: $NChunks/$NChunks match"
}

# --- quarantine-copy manifest (written ONLY after verification passes) --------------
$TS = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$lines = @(
    '# phoenix quarantine-copy manifest -- written only after verification PASSES',
    'format=phoenix-quarantine-copy/1',
    "image_name=$ImageName",
    "source_dir=$CSrc",
    "target_dir=$Dest",
    "quarantine_date=$Date",
    "evidence=$Evidence",
    "source_serial=$SourceSerial",
    "chunk_count=$NChunks",
    "bytes_copied=$Need",
    "target_fs_type=$FsType",
    'tool=New-PhoenixQuarantineCopy.ps1',
    "created_utc=$TS",
    "operator=$Operator"
)
if ($Evidence -eq 'manifest') {
    $lines = $lines[0..9] + @(
        "source_stream_sha512=$StreamSha",
        "source_chunks_concat_sha256=$ConcatSha"
    ) + $lines[10..($lines.Count - 1)]
} else {
    $proofBase = Split-Path -Leaf $ImageProof
    $lines = $lines[0..9] + @("image_proof=$proofBase") + $lines[10..($lines.Count - 1)]
}
$lines += 'verify=PASS'
try {
    [IO.File]::WriteAllLines($ManifestOut, $lines, [Text.UTF8Encoding]::new($false))
} catch { Die "cannot write quarantine-copy manifest ($($_.Exception.Message))" 2 }

Log "DONE: verified quarantine copy at $Dest"
Log "The infected image is quarantined: never mount or boot it on a daily-driver machine."
exit 0
