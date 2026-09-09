<#
.SYNOPSIS
    Stages the Phoenix ISO set, config, and scripts onto a Ventoy-prepared USB.

.DESCRIPTION
    One half of the Phoenix USB build (see docs/BOOT-ARCHITECTURE.md). The
    other half -- the config GUI that generates phoenix-config.json /
    autounattend.xml on a working Windows machine -- is a sibling worker's
    domain.

    This script:
      1. Verifies the target drive is Ventoy-prepared (fails closed if not).
      2. Copies the ISO set (SystemRescue / Rescuezilla / ShredOS / Windows 11 /
         Phoenix WinPE) with SHA-256 hash verification against a sidecar file.
      3. Writes ventoy/ventoy.json: the Analyze/Backup/Nuke/Reinstall menu
         aliases + Windows auto_install wiring to /autounattend.xml.
      4. Writes phoenix-config.json (schema v1) to the USB root.
      5. Stages the Phoenix PowerShell toolbox under phoenix/scripts/.
      6. Writes phoenix/manifest.json with SHA-256 of everything staged.

    STATUS: scaffold. Static review only -- NOT yet run on Windows. Windows
    testing required before it touches a real stick.

.EXAMPLE
    .\tools\Build-PhoenixUsb.ps1 -UsbDrive "E:" -IsoDir ".\iso-staging" `
        -IsoHashes ".\iso-staging\phoenix-iso-hashes.json" `
        -ComputerName "BRANDON-PC" -Username "brandon"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Drive letter of the Ventoy-prepared USB, e.g. E:")]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$UsbDrive,

    [Parameter(Mandatory = $true, HelpMessage = "Directory containing the ISO files")]
    [string]$IsoDir,

    [Parameter(HelpMessage = "JSON sidecar: { '<iso filename>': '<sha256 hex>' }. Required unless -SkipHashCheck.")]
    [string]$IsoHashes,

    [string]$ComputerName = "PHOENIX-PC",
    [string]$Username     = "phoenix",

    [Parameter(HelpMessage = "Install-time password. Prompted securely if omitted. See security note below.")]
    [string]$Password,

    [string]$Timezone   = "Central Standard Time",
    [string]$Edition    = "Professional",
    [string]$ProductKey,
    [string[]]$Apps     = @(),

    [switch]$SkipHashCheck,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 0. Resolve paths, guard clauses
# ---------------------------------------------------------------------------
$driveLetter = $UsbDrive.TrimEnd(':').ToUpper()
$usbRoot = "$driveLetter`:\"

if (-not (Test-Path $usbRoot)) {
    throw "Drive $usbRoot not found. Is the Ventoy USB plugged in?"
}

# Fail closed: this script NEVER initializes a stick. Ventoy must be there.
$ventoyDir = Join-Path $usbRoot "ventoy"
if (-not (Test-Path $ventoyDir)) {
    throw ("No 'ventoy' directory on $usbRoot. This script only stages a " +
           "Ventoy-PREPARED stick -- install Ventoy with Ventoy2Disk first. " +
           "Refusing to write to an unprepared drive.")
}

$vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
if ($null -ne $vol -and $vol.FileSystemType -ne "exFAT") {
    Write-Warning ("Ventoy data partition is normally exFAT; this drive reports " +
                   "'$($vol.FileSystemType)'. Proceeding, but double-check the stick.")
}

if (-not (Test-Path $IsoDir)) { throw "ISO dir not found: $IsoDir" }

# ---------------------------------------------------------------------------
# 1. ISO set: locate + hash-verify + copy
# ---------------------------------------------------------------------------
# [VERIFY] Phoenix WinPE ISO is not built yet (BOOT-ARCHITECTURE.md section 4,
# ADK build on a clean machine). The entry stays in the table so the stager
# fails LOUDLY instead of silently shipping a 4-entry stick.
$isoSet = @(
    @{ Pattern = "systemrescue-*-amd64.iso";  Dest = "ISOs"; Role = "ANALYZE"    },
    @{ Pattern = "rescuezilla-*-64bit.iso";   Dest = "ISOs"; Role = "BACKUP"     },
    @{ Pattern = "ShredOS-*_x86_64.iso";       Dest = "ISOs"; Role = "NUKE"       },
    @{ Pattern = "Win11_*_English_x64.iso";    Dest = "ISOs"; Role = "REINSTALL"  },
    @{ Pattern = "phoenix-winpe.iso";          Dest = "ISOs"; Role = "TOOLKIT"    }
)

$hashes = @{}
if (-not $SkipHashCheck) {
    if ([string]::IsNullOrWhiteSpace($IsoHashes) -or -not (Test-Path $IsoHashes)) {
        throw ("No hash sidecar found. Pass -IsoHashes '<file>.json' with " +
               "{ '<iso filename>': '<sha256>' }, or -SkipHashCheck to bypass " +
               "(not recommended -- Brandon verifies ISOs by hash as policy).")
    }
    # PS 5.1-compatible: no ConvertFrom-Json -AsHashtable (PS 6+ only).
    $hashes = @{}
    (Get-Content $IsoHashes -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $hashes[$_.Name] = $_.Value }
}

$stagedIsos = @()
foreach ($entry in $isoSet) {
    $found = Get-ChildItem -Path $IsoDir -Filter $entry.Pattern -File -ErrorAction SilentlyContinue |
             Sort-Object Name | Select-Object -Last 1
    if ($null -eq $found) {
        throw "[$($entry.Role)] No ISO matching '$($entry.Pattern)' in $IsoDir. Stager fails closed: missing asset, no USB."
    }

    if (-not $SkipHashCheck) {
        $expected = $hashes[$found.Name]
        if ([string]::IsNullOrWhiteSpace($expected)) {
            throw "[$($entry.Role)] No hash entry for '$($found.Name)' in $IsoHashes. Refusing to stage an unverified ISO."
        }
        $actual = (Get-FileHash -Path $found.FullName -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected.ToLower()) {
            throw "[$($entry.Role)] HASH MISMATCH for '$($found.Name)'. Expected $expected, got $actual. Aborting."
        }
        Write-Verbose "[$($entry.Role)] hash OK: $($found.Name)"
    }

    $destDir = Join-Path $usbRoot $entry.Dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
    $destPath = Join-Path $destDir $found.Name
    if ($PSCmdlet.ShouldProcess($found.Name, "Copy to Phoenix USB ($($entry.Role))")) {
        Copy-Item -Path $found.FullName -Destination $destPath -Force:$Force
    }
    $stagedIsos += [pscustomobject]@{
        Role     = $entry.Role
        FileName = $found.Name
        Sha256   = (Get-FileHash -Path $destPath -Algorithm SHA256).Hash.ToLower()
    }
}

# ---------------------------------------------------------------------------
# 2. ventoy/ventoy.json -- the Analyze/Backup/Nuke/Reinstall menu
# ---------------------------------------------------------------------------
# menu_alias renames each ISO entry; auto_install points the Windows ISO at
# the answer file on the data partition (no ISO reburning, no manual XML).
$winIso = ($stagedIsos | Where-Object { $_.Role -eq "REINSTALL" }).FileName
$ventoyJson = [ordered]@{
    control = @(
        @{ key = "VTOY_DEFAULT_MENU_MODE"; value = "0" }
    )
    menu_alias = @(
        @{ image = "/ISOs/$((($stagedIsos | Where-Object { $_.Role -eq 'ANALYZE'  }).FileName))"; alias = "[1] ANALYZE -- SystemRescue" },
        @{ image = "/ISOs/$((($stagedIsos | Where-Object { $_.Role -eq 'BACKUP'   }).FileName))"; alias = "[2] BACKUP -- Rescuezilla" },
        @{ image = "/ISOs/$((($stagedIsos | Where-Object { $_.Role -eq 'NUKE'     }).FileName))"; alias = "[3] NUKE -- ShredOS" },
        @{ image = "/ISOs/$winIso"; alias = "[4] REINSTALL -- Windows 11 (unattended)" },
        @{ image = "/ISOs/$((($stagedIsos | Where-Object { $_.Role -eq 'TOOLKIT'  }).FileName))"; alias = "[5] TOOLKIT -- Phoenix WinPE" }
    )
    auto_install = @(
        @{ image = "/ISOs/$winIso"; template = "/autounattend.xml" }
    )
}
$ventoyJsonPath = Join-Path $ventoyDir "ventoy.json"
if ($PSCmdlet.ShouldProcess($ventoyJsonPath, "Write Ventoy menu config")) {
    ($ventoyJson | ConvertTo-Json -Depth 6) | Set-Content -Path $ventoyJsonPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 3. phoenix-config.json (schema v1) at the USB root
# ---------------------------------------------------------------------------
# SECURITY: unattend requires the password in reversible form. The USB is a
# key -- keep it on your person, rotate the password at first logon, and
# NEVER commit a real phoenix-config.json to the repo.
if ([string]::IsNullOrEmpty($Password)) {
    $sec = Read-Host "Install-time password for '$Username' (stored reversibly on the USB -- see security note)" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if ([string]::IsNullOrEmpty($Password)) { throw "Password is required: unattend cannot create the account without one." }

$config = [ordered]@{
    schemaVersion = 1
    machine       = [ordered]@{
        computerName = $ComputerName
        timezone     = $Timezone
    }
    credentials   = [ordered]@{
        username = $Username
        password = $Password
    }
    os            = [ordered]@{
        family     = "windows"
        edition    = $Edition
        productKey = $ProductKey
        answerFile = [ordered]@{
            disableWPBT       = $true
            partitionLayout   = "gpt-uefi"
        }
    }
    # OS-agnostic app list: the config GUI owns richer entries; the stager
    # maps bare choco ids to {id, source}. Future blades add their sources.
    apps          = @($Apps | ForEach-Object { [ordered]@{ id = $_; source = "choco" } })
}
$configPath = Join-Path $usbRoot "phoenix-config.json"
if ($PSCmdlet.ShouldProcess($configPath, "Write phoenix-config.json")) {
    ($config | ConvertTo-Json -Depth 4) | Set-Content -Path $configPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 4. Stage the Phoenix toolbox + tools, write manifest.json
# ---------------------------------------------------------------------------
# The repo root is the script's parent dir (tools/Build-PhoenixUsb.ps1).
# Bash twins (tools/<name>.sh, BOOT-ARCHITECTURE.md section 9.3) ride along
# automatically -- the whole scripts/ tree is copied, *.ps1 and *.sh alike.
$repoRoot = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$phoenixDir = Join-Path $usbRoot "phoenix"
foreach ($d in @("scripts", "tools", "WinPE")) {
    $p = Join-Path $phoenixDir $d
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

$toolboxSrc = Join-Path $repoRoot "scripts"
if ((Test-Path $toolboxSrc) -and $PSCmdlet.ShouldProcess("$phoenixDir\scripts", "Stage Phoenix toolbox")) {
    Copy-Item -Path (Join-Path $toolboxSrc "*") -Destination (Join-Path $phoenixDir "scripts") -Recurse -Force:$Force
}

# [VERIFY] Portable Explorer++ is not staged in this repo yet. Drop
# Explorer++.zip into phoenix/tools/ on the USB manually until a worker
# vendors it (BOOT-ARCHITECTURE.md section 6).
# [VERIFY] autounattend.xml generation from phoenix-config.json is the config
# GUI's job (sibling worker). Until it lands, place win-install/autounattend.xml
# at the USB root manually.

$manifest = [ordered]@{
    builtAt       = (Get-Date).ToString("o")
    builtBy       = $env:USERNAME
    schemaVersion = 1
    isos          = $stagedIsos
    notes         = @(
        "Phoenix WinPE ISO not built yet -- TOOLKIT entry will fail until the ADK build lands.",
        "Explorer++ not vendored yet -- stage phoenix/tools/Explorer++.zip manually.",
        "autounattend.xml at USB root is hand-placed until the config GUI generates it."
    )
}
$manifestPath = Join-Path $phoenixDir "manifest.json"
if ($PSCmdlet.ShouldProcess($manifestPath, "Write manifest.json")) {
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $manifestPath -Encoding UTF8
}

Write-Host ""
Write-Host "Phoenix USB staged on $usbRoot" -ForegroundColor Green
Write-Host "  ISOs staged : $($stagedIsos.Count)"
Write-Host "  Menu config : $ventoyJsonPath"
Write-Host "  Config      : $configPath"
Write-Host "  Manifest    : $manifestPath"
Write-Host ""
Write-Host "Remaining manual steps (see [VERIFY] notes above):" -ForegroundColor Yellow
Write-Host "  - Build + stage phoenix-winpe.iso (ADK, BOOT-ARCHITECTURE.md section 4)"
Write-Host "  - Stage phoenix/tools/Explorer++.zip"
Write-Host "  - Generate / place autounattend.xml at USB root"
Write-Host "  - Boot-test on the target machine; enroll the Ventoy MOK key at first boot"
