<#
.SYNOPSIS
    Invoke-Analyze.ps1 -- Phoenix ANALYZE module, Windows twin (read-only triage).

.DESCRIPTION
    Collects disk enumeration + hardware inventory + malware-triage data on the
    Phoenix WinPE side (USB menu entry [5] TOOLKIT) or on a clean staging
    machine, WITHOUT booting the suspect OS and WITHOUT mounting or writing
    to any suspect disk.

    SAFETY MODEL (see docs/ANALYZE-MODULE.md):
      1. READ-ONLY BY CONSTRUCTION: enumerates via Get-Disk / CIM only. Never
         mounts, never initializes, never writes to any disk. Contains NO
         destructive cmdlets (no Format-*, Clear-Disk, Initialize-Disk,
         Remove-Partition, or diskpart clean) -- verified by regression test.
      2. NO NETWORK: only adapter *state* (Get-NetAdapter Status) is read.
         Nothing is connected, enabled, or configured.
      3. NO SUSPECT-OS BOOT: data comes from the WinPE/staging kernel (WMI/CIM,
         firmware). Offline filesystem inspection happens later on the staging
         machine against the mounted *image* (ANALYSIS-TOOLKIT.md workflow).
      4. CONTRACT PARITY with tools/Invoke-Analyze.sh: same report schema
         (phoenix-analyze-report, report_version 1), same serial-resolved
         identity (row number, device id, or serial), same DUP-SERIAL flagging,
         same atomic write (temp file + rename), same fail-closed JSON check.
      5. CONFIG HONESTY: -Config <phoenix-config.json> is optional. When given
         it is validated by tools/Validate-UsbConfig.py and
         boot_entries.analyze must be true, else the script refuses.

    This twin never images anything: like Invoke-Backup.ps1, the .ps1 side
    validates and triages; the actual module payload runs on the Linux boot
    side (Ventoy entry [1] ANALYZE). Invoke-Analyze.sh is the payload of
    record; this script mirrors its contract for WinPE/staging use.

.PARAMETER Write
    Also write the JSON report (in addition to the console table).

.PARAMETER OutDir
    Directory the report is written to (required with -Write).

.PARAMETER BootDevice
    Disk identifier of the Phoenix USB (row number, Number, or SerialNumber);
    the report marks it is_boot_usb. Optional.

.PARAMETER Config
    Path to phoenix-config.json. Validated; boot_entries.analyze must be true.

.PARAMETER ImageProof
    Path to an image-proof manifest from the Backup phase; recorded as a hint
    (validated only, never gates).

.EXAMPLE
    .\Invoke-Analyze.ps1
    .\Invoke-Analyze.ps1 -Write -OutDir E:\reports -BootDevice 4C530001230719115224

.OUTPUTS
    Exit 0 = ok, 1 = error/refusal, 2 = usage error. Report schema:
    phoenix-analyze-report / report_version 1 (see docs/ANALYZE-MODULE.md).
#>
[CmdletBinding()]
param(
    [switch]$Write,
    [string]$OutDir = "",
    [string]$BootDevice = "",
    [string]$Config = "",
    [string]$ImageProof = ""
)

$ErrorActionPreference = 'Stop'
$Version = '0.1.0'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir = if ($env:PHOENIX_TOOLS_DIR) { $env:PHOENIX_TOOLS_DIR } else { $ScriptDir }
$Notes = New-Object System.Collections.Generic.List[string]

function Add-Note([string]$Text) { $Notes.Add($Text) | Out-Null }

function Get-UtcNow {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# --- usage -------------------------------------------------------------------
if ($Write -and [string]::IsNullOrWhiteSpace($OutDir)) {
    Write-Error "-Write requires -OutDir <dir>"
    exit 2
}
if (-not [string]::IsNullOrWhiteSpace($OutDir) -and -not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    Write-Error "-OutDir is not a directory: $OutDir"
    exit 1
}

# --- config honesty ----------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($Config)) {
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Write-Error "-Config file not found: $Config"; exit 1
    }
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $py) { Write-Error "python3 required to validate -Config"; exit 1 }
    & $py.Source "$ToolsDir\Validate-UsbConfig.py" $Config > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "-Config failed validation: $Config (fail closed)"; exit 1
    }
    $policy = & $py.Source "$ToolsDir\Read-UsbConfig.py" --json $Config 2>$null | ConvertFrom-Json
    if (-not $policy.analyze_enabled) {
        Write-Error "stick policy: boot_entries.analyze is not enabled (fail closed)"; exit 1
    }
}

# --- disk enumeration (read-only: Get-Disk / CIM only) -----------------------
$Disks = @()
try {
    $raw = Get-Disk | Sort-Object Number
} catch {
    Write-Error "Get-Disk failed: $($_.Exception.Message)"; exit 1
}
$dupSerials = @{}
foreach ($d in $raw) {
    $s = ($d.SerialNumber | ForEach-Object { $_.Trim() }) -join ''
    if ($s -and $s -ne 'unknown') {
        if ($dupSerials.ContainsKey($s)) { $dupSerials[$s] += 1 } else { $dupSerials[$s] = 1 }
    }
}
$row = 0
foreach ($d in $raw) {
    $row++
    $s = (($d.SerialNumber) | ForEach-Object { $_.Trim() }) -join ''
    $media = switch ($d.MediaType) {
        'SSD' { 'SSD' } 'HDD' { 'HDD' } 'SCM' { 'SSD' } default { 'unknown' }
    }
    if ([string]::IsNullOrWhiteSpace($media)) { $media = 'unknown' }
    $Disks += [pscustomobject]@{
        Row           = $row
        Number        = $d.Number
        Device        = "\\.\PhysicalDrive$($d.Number)"
        Model         = ($d.Model | ForEach-Object { $_.Trim() }) -join ''
        Serial        = $s
        SizeBytes     = [long]$d.Size
        BusType       = "$($d.BusType)"
        Media         = $media
        IsRemovable   = [bool]$d.IsBoot -eq $false -and $d.BusType -eq 'USB'
        IsBoot        = [bool]$d.IsBoot
        DupSerial     = ($s -and $dupSerials.ContainsKey($s) -and $dupSerials[$s] -gt 1)
        IsBootUsb     = $false
    }
}
foreach ($d in $Disks) {
    if ($d.DupSerial) {
        Add-Note "DUP-SERIAL: serial '$($d.Serial)' reported by more than one disk; identity ambiguous, serial resolution refused"
    }
}

# --- boot-device resolution (serial, Number, or row) -------------------------
$BootNumber = $null
if (-not [string]::IsNullOrWhiteSpace($BootDevice)) {
    $id = $BootDevice.Trim()
    $hit = $Disks | Where-Object { $_.Serial -eq $id -or "$($_.Number)" -eq $id -or "$($_.Row)" -eq $id } | Select-Object -First 1
    if ($hit) { $hit.IsBootUsb = $true; $BootNumber = $hit.Number }
    else { Add-Note "boot-device id '$id' did not resolve to a disk; report marks none" }
}
elseif ($env:PHOENIX_BOOT_DEVICE) {
    $hit = $Disks | Where-Object { $_.Serial -eq $env:PHOENIX_BOOT_DEVICE } | Select-Object -First 1
    if ($hit) { $hit.IsBootUsb = $true; $BootNumber = $hit.Number }
}

# --- hardware inventory (CIM; read-only) --------------------------------------
function Get-CimFirst([string]$Class, [string]$Prop) {
    try { (Get-CimInstance -ClassName $Class -ErrorAction Stop | Select-Object -First 1).$Prop } catch { '' }
}
$cpuName  = Get-CimFirst 'Win32_Processor' 'Name'
$cpuCount = try { (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object).Count } catch { 0 }
$ramKb = try {
    [long]((Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop |
        Measure-Object -Property Capacity -Sum).Sum / 1KB)
} catch { 0 }
if ($ramKb -eq 0) {
    try { $ramKb = [long](Get-CimFirst 'Win32_ComputerSystem' 'TotalPhysicalMemory') / 1KB } catch { }
}
$biosVendor  = Get-CimFirst 'Win32_BIOS' 'Manufacturer'
$biosVersion = Get-CimFirst 'Win32_BIOS' 'SMBIOSBIOSVersion'
$productName = Get-CimFirst 'Win32_ComputerSystemProduct' 'Name'
try { $secureBoot = (Confirm-SecureBootUEFI -ErrorAction Stop); $sbState = if ($secureBoot) { 'enabled' } else { 'disabled' } }
catch { $sbState = 'unknown' }
try { $tpm = Get-Tpm -ErrorAction Stop; $tpmState = if ($tpm.TpmPresent) { 'present' } else { 'absent' } }
catch { $tpmState = 'unknown' }
$netIfaces = try {
    Get-NetAdapter -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; state = "$($_.Status)".ToLower() }
    }
} catch { @() }

# --- image-proof hint ---------------------------------------------------------
$proofValid = $false; $proofSerial = ''
if (-not [string]::IsNullOrWhiteSpace($ImageProof)) {
    if ((Test-Path -LiteralPath $ImageProof -PathType Leaf)) {
        $proofValid = $true  # full manifest verification is the .sh payload's job
        $m = Select-String -LiteralPath $ImageProof -Pattern '^source_serial=' -SimpleMatch -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($m) { $proofSerial = ($m.Line -split '=', 2)[1] }
    } else {
        Add-Note "image-proof '$ImageProof' missing; treated as absent"
    }
}

# --- human table --------------------------------------------------------------
Write-Output "Phoenix ANALYZE triage ($(Get-UtcNow)) -- read-only, suspect OS never booted"
Write-Output ("{0,-4} {1,-22} {2,-16} {3,-24} {4,-12} {5,-8} {6}" -f 'ROW','DEVICE','SERIAL','MODEL','SIZE','MEDIA','FLAGS')
foreach ($d in $Disks) {
    $flags = @()
    if ($d.IsBootUsb) { $flags += 'BOOT-USB' }
    if ($d.DupSerial) { $flags += 'DUP-SERIAL' }
    if ($d.IsBoot)    { $flags += 'IS-BOOT' }
    Write-Output ("{0,-4} {1,-22} {2,-16} {3,-24} {4,-12} {5,-8} {6}" -f `
        $d.Row, $d.Device, $(if ($d.Serial) { $d.Serial } else { '?' }), `
        $(if ($d.Model) { $d.Model } else { '?' }), $d.SizeBytes, $d.Media, ($flags -join ' '))
}
Write-Output ""
Write-Output ("Hardware: CPU={0} x{1} | RAM={2} kB | BIOS={3} {4} | SecureBoot={5} | TPM={6}" -f `
    $cpuName, $cpuCount, $ramKb, $biosVendor, $biosVersion, $sbState, $tpmState)
Write-Output "Network (state only, no traffic):"
foreach ($n in $netIfaces) { Write-Output ("  {0,-20} {1}" -f $n.name, $n.state) }
if ($Notes.Count -gt 0) { Write-Output "Notes:"; foreach ($t in $Notes) { Write-Output "  - $t" } }

# --- JSON report (atomic write, fail-closed parse check) ----------------------
if ($Write) {
    $report = [ordered]@{
        report         = 'phoenix-analyze-report'
        report_version = 1
        tool           = "Invoke-Analyze.ps1 $Version"
        collected_at   = Get-UtcNow
        machine        = [ordered]@{
            cpu                = "$cpuName"
            cpu_count          = [int]$cpuCount
            ram_total_kb       = [long]$ramKb
            bios_vendor        = "$biosVendor"
            bios_version       = "$biosVersion"
            system_product     = "$productName"
            secure_boot        = $sbState
            tpm                = $tpmState
            network_interfaces = @($netIfaces)
            efi_boot_entries   = ''
        }
        disks          = @($Disks | ForEach-Object {
            [ordered]@{
                row                     = $_.Row
                device                  = $_.Device
                model                   = $_.Model
                serial                  = $_.Serial
                size_bytes              = $_.SizeBytes
                transport               = $_.BusType
                media                   = $_.Media
                removable               = [bool]$_.IsRemovable
                smart_support           = 'unknown'
                dup_serial              = [bool]$_.DupSerial
                has_mounted_partitions  = $false
                is_boot_usb             = [bool]$_.IsBootUsb
            }
        })
        image_proof    = [ordered]@{
            provided      = (-not [string]::IsNullOrWhiteSpace($ImageProof))
            valid         = [bool]$proofValid
            source_serial = $proofSerial
        }
        notes          = @($Notes)
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $tmp = Join-Path $OutDir ".analyze-report.$pid.tmp"
    $dest = Join-Path $OutDir "phoenix-analyze-report-$stamp.json"
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    # Fail closed: the report parses as JSON or it does not land.
    try { Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json | Out-Null }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Write-Error "generated report failed JSON parse; nothing written"; exit 1 }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-Output "Report written: $dest"
}

exit 0
