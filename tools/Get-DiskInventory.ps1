<#
.SYNOPSIS
    Phoenix disk enumeration (WinPE / Windows side).
.DESCRIPTION
    Twin of tools/Get-DiskInventory.sh. Emits the same inventory JSON contract
    (see docs/NUKE-SAFETY.md section 2) using Get-Disk / CIM, so the
    pre-boot staging flow on a working machine verifies the exact gate logic
    the boot side will run.

    The WinPE side is STAGING-ONLY: it verifies enumeration, fingerprint and
    allowlist gate logic. Destruction can never be armed from a live Windows
    session -- the interlocks must live where the destruction happens.

    Requires Windows PowerShell 5.1+ (WinPE) or PowerShell 7+. No modules.
.PARAMETER SaveState
    Directory in which to write disk-fingerprints.json (the Analyze step).
    On the WinPE side partition_hash is always null (raw disk reads are not
    performed from a live Windows session); staging verification only.
.EXAMPLE
    .\Get-DiskInventory.ps1
.EXAMPLE
    .\Get-DiskInventory.ps1 -SaveState X:\phoenix-state
#>
[CmdletBinding()]
param(
    [string]$SaveState = ""
)

$ErrorActionPreference = "Stop"

function Format-Gib {
    param([UInt64]$Bytes)
    # MUST match the bash twin exactly: one decimal, GiB, dot separator.
    # InvariantCulture: -f is locale-dependent ("931,5 GiB" in de-DE), which
    # would break exact-match confirmation against the Linux-rendered card.
    return ([string]::Format(
        [System.Globalization.CultureInfo]::InvariantCulture,
        "{0:N1} GiB", ($Bytes / 1GB)))
}

function Get-MediaClass {
    param($Disk)
    # WinPE Get-Disk: MediaType is SSD/HDD/UnSpecified; BusType covers NVMe/USB
    if ($Disk.BusType -eq "NVMe") { return "nvme" }
    switch ($Disk.MediaType) {
        "SSD" { return "ssd" }
        "HDD" { return "hdd" }
    }
    if ($Disk.Model -match "(?i)ssd|nvme") { return "ssd" }
    return "unknown"
}

function Get-DiskMounted {
    param($Disk)
    # A disk counts as mounted if any of its partitions has a drive letter or
    # an access path (mounted volume). Conservative: when in doubt, mounted.
    try {
        $parts = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
        foreach ($p in $parts) {
            if ($p.DriveLetter -or $p.AccessPaths.Count -gt 0) { return $true }
        }
    } catch { return $true }
    return $false
}

$rawDisks = Get-Disk | Where-Object { $_.BusType -ne "File Backed Virtual" } |
    Sort-Object BusType, Size

$disks = @()
$id = 0
foreach ($d in $rawDisks) {
    $id++
    $serial = ($d.SerialNumber | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($serial)) { $serial = $null }

    $transport = "$($d.BusType)"
    if ([string]::IsNullOrWhiteSpace($transport)) { $transport = "unknown" }

    $disks += [ordered]@{
        id          = $id
        dev         = "\\.\PhysicalDrive$($d.Number)"
        model       = "$($d.Model)".Trim()
        serial      = $serial
        size_bytes  = [UInt64]$d.Size
        size_human  = Format-Gib ([UInt64]$d.Size)
        transport   = $transport
        removable   = [bool]($d.BusType -eq "USB")
        mounted     = Get-DiskMounted $d
        boot        = [bool]$d.IsBoot     # authoritative: the disk Windows booted from
        system      = [bool]$d.IsSystem   # authoritative: holds the running system volume
        media       = Get-MediaClass $d
    }
}

$inventory = [ordered]@{
    schema = "phoenix-disk-inventory/1"
    disks  = $disks
}
$inventory | ConvertTo-Json -Depth 6

if ($SaveState -ne "") {
    if (-not (Test-Path $SaveState)) { New-Item -ItemType Directory -Path $SaveState | Out-Null }

    $fpDisks = @()
    foreach ($d in $disks) {
        $fpDisks += [ordered]@{
            serial         = $d.serial
            model          = $d.model
            size_bytes     = $d.size_bytes
            transport      = $d.transport
            partition_hash = $null   # staging-only: raw reads never happen here
        }
    }
    $fp = [ordered]@{
        schema_version = 1
        recorded_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        recorded_by    = "analyze"
        disks          = $fpDisks
    }
    $fpPath = Join-Path $SaveState "disk-fingerprints.json"
    $fp | ConvertTo-Json -Depth 6 | Out-File -FilePath $fpPath -Encoding utf8
    Write-Host "fingerprints recorded -> $fpPath"
}
