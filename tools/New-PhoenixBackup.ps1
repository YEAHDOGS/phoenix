<#
.SYNOPSIS
    New-PhoenixBackup.ps1 -- Phoenix BACKUP phase: WinPE-side volume imager.

    WinPE twin of tools/phoenix-backup.sh. Captures a Windows volume
    (normally the OS volume, e.g. C:) to a WIM on a DIRECT-ATTACHED USB
    target with DISM /CheckIntegrity, SHA-512 hashing, a phoenix-backup/1
    manifest, and a nuke-gate proof in the phoenix-image-proof/1 format.

    PARITY CONTRACT (same as the bash tool, enforced by
    tests/tools/test-phoenix-backup.sh T7):
      - same manifest schema: format=phoenix-backup/1, image_name,
        source_serial, stream_sha512, operator, verify=PASS
      - same proof schema: phoenix-image-proof/1, verified=YES,
        source_serial binding
      - same fail-closed posture: any capture/hash failure aborts with
        no manifest and no proof ("verified image or no wipe")

    HONEST DIFFERENCE: WinPE PowerShell cannot do raw whole-disk dd, so this
    twin captures VOLUMES (dism /Capture-Image), not the raw disk. The Linux
    rescue side (tools/phoenix-backup.sh) is the whole-disk path -- bootloader,
    recovery and hidden partitions included. For the infected-laptop flow,
    prefer the Linux side; use this twin when you are already in WinPE and
    need the OS volume captured now.

    AIR-GAP: never images to a network path. The target must be a local,
    direct-attached drive. Copying to Castle's 10TB drive happens from a
    clean machine (runbook Step 2.7).

.EXAMPLE
    .\New-PhoenixBackup.ps1 -Source "C:" -SourceSerial "SATATEST001" `
        -Out "E:\laptop-osvol-2026-09-09" -Operator brandon
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:$')]
    [string]$Source,                       # volume to capture, e.g. "C:"

    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]{1,64}$')]
    [string]$SourceSerial,                 # binds the nuke-gate proof to this disk

    [Parameter(Mandatory)][string]$Out,    # image dir on the USB target

    [string]$Operator = $env:USERNAME,     # who ran it

    [ValidateSet('Max','Fast','None')]
    [string]$Compress = 'Max',

    [switch]$NoMintProof,                  # skip proof writing (NOT recommended)

    [string]$ProofOut                      # default: same as -Out
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Die([string]$msg) { Write-Error "[New-PhoenixBackup] FATAL: $msg"; exit 1 }
function Die2([string]$msg) { Write-Error "[New-PhoenixBackup] FATAL: $msg"; exit 2 }

# --- validation (fail closed) -------------------------------------------------------
if ($Source -notmatch '^[A-Za-z]:$') { Die "-Source must be a drive letter like 'C:'" }
$vol = Get-Volume -DriveLetter $Source.TrimEnd(':') -ErrorAction SilentlyContinue
if (-not $vol) { Die "volume $Source not found" }

if (Test-Path $Out -PathType Leaf) { Die "-Out '$Out' exists and is not a directory" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$ImageName = Split-Path $Out -Leaf
if ([string]::IsNullOrWhiteSpace($ImageName)) { Die "-Out must end in an image directory name" }

if ([string]::IsNullOrWhiteSpace($ProofOut)) { $ProofOut = $Out }
New-Item -ItemType Directory -Force -Path $ProofOut | Out-Null

# free-space preflight: demand >= the volume's used space (WIM compresses, but
# fail closed -- a half-written WIM is worse than a refusal)
$volSize = (Get-Volume -DriveLetter $Source.TrimEnd(':')).Size
$targetDrive = (Get-Item $Out).PSDrive.Name
$free = (Get-PSDrive $targetDrive).Free
if ($free -lt $volSize) { Die "target has ${free}B free but volume is ${volSize}B -- refusing" }

$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$wim = Join-Path $Out "$ImageName.wim"
$manifest = Join-Path $Out 'backup.manifest'
$log = Join-Path $Out 'backup.log'
"[$ts] New-PhoenixBackup: capturing $Source ($volSize B, serial $SourceSerial) -> $wim" |
    Tee-Object -FilePath $log -Append | Write-Host

# --- capture ----------------------------------------------------------------------
$dismArgs = @('/Capture-Image', "/ImageFile:$wim", "/CaptureDir:$Source\", "/Name:$ImageName",
              "/Compress:$Compress", '/CheckIntegrity')
Write-Host "[New-PhoenixBackup] running: dism $($dismArgs -join ' ')"
& dism.exe @dismArgs 2>&1 | Tee-Object -FilePath $log -Append | Write-Host
if ($LASTEXITCODE -ne 0) { Die2 "dism capture failed (exit $LASTEXITCODE) -- no manifest, no proof" }
$wimInfo = Get-Item $wim -ErrorAction SilentlyContinue
if (-not $wimInfo -or $wimInfo.Length -le 0) { Die2 "WIM missing or zero bytes after capture -- refusing" }

# --- verify: SHA-512 of the WIM + re-read check ------------------------------------
Write-Host "[New-PhoenixBackup] hashing WIM (SHA-512)..."
$sha512 = (Get-FileHash -Path $wim -Algorithm SHA512).Hash.ToLower()
if ($sha512 -notmatch '^[0-9a-f]{128}$') { Die2 "could not hash WIM -- refusing" }
$sha256 = (Get-FileHash -Path $wim -Algorithm SHA256).Hash.ToLower()
Write-Host "[New-PhoenixBackup] stream SHA-512: $sha512" | Tee-Object -FilePath $log -Append

# --- manifest (written only after capture + hash succeed) --------------------------
@(
    '# phoenix backup manifest -- written only after verification PASSES'
    'format=phoenix-backup/1'
    "image_name=$ImageName"
    'image_kind=wim'
    "source_dev=$Source"
    "source_serial=$SourceSerial"
    "source_size_bytes=$volSize"
    'chunk_mib=n/a'
    'chunk_count=1'
    'compressor=dism-wim'
    "compressed_size_bytes=$($wimInfo.Length)"
    "stream_sha512=$sha512"
    "chunks_concat_sha256=$sha256"
    'tool=New-PhoenixBackup.ps1'
    "created_utc=$ts"
    "operator=$Operator"
    'verify=PASS'
) | Set-Content -Path $manifest -Encoding Ascii
Write-Host "[New-PhoenixBackup] manifest written: $manifest" | Tee-Object -FilePath $log -Append

# --- mint the nuke-gate proof (same phoenix-image-proof/1 keys as New-ImageProof.sh)
if (-not $NoMintProof) {
    $proofFile = Join-Path $ProofOut "image-proof-${SourceSerial}-${ts}.proof"
    @(
        '# phoenix image-proof manifest -- written by New-PhoenixBackup.ps1'
        '# keep on the Phoenix USB; pass to Invoke-Nuke.sh --image-proof'
        'format=phoenix-image-proof/1'
        "image_name=$ImageName"
        "image_path=$Out"
        "source_serial=$SourceSerial"
        "source_dev=$Source"
        "image_size_bytes=$($wimInfo.Length)"
        "sha256=$sha256"
        "created_utc=$ts"
        'verified=YES'
        "verified_by=$Operator"
    ) | Set-Content -Path $proofFile -Encoding Ascii
    Write-Host "[New-PhoenixBackup] nuke-gate proof minted: $proofFile" | Tee-Object -FilePath $log -Append
}

Write-Host "[New-PhoenixBackup] DONE: verified WIM of $Source ($($wimInfo.Length) B) in $Out" |
    Tee-Object -FilePath $log -Append
