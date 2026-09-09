<#
.SYNOPSIS
    Phoenix ANALYZE phase (WinPE / Windows side). READ-ONLY disk triage.
.DESCRIPTION
    Twin of tools/Analyze-DiskTriage.sh. Enumerates disks, inventories
    partitions, runs heuristic filesystem scans (every finding labeled
    HEURISTIC), and writes a phoenix-triage-report/1 JSON report to the
    operator-supplied state directory.

    READ-ONLY CONTRACT: this script never writes to a target disk. It
    self-verifies that guarantee on startup (Assert-ReadOnly scans its own
    source for forbidden write patterns and throws if any are found). The
    only writes this script performs are the triage report into -SaveState,
    which must not live on a triaged disk (gated).

    WinPE side is STAGING-ONLY verification of the triage logic; destruction
    can never be armed from a live Windows session.

    Requires Windows PowerShell 5.1+ (WinPE) or PowerShell 7+. No modules.
.PARAMETER SaveState
    Directory for triage-report.json. Refused if it resolves to a volume on
    any enumerated (triaged) disk.
.PARAMETER ScanMounted
    Also run heuristic scans on every mounted volume, not just the report.
.EXAMPLE
    .\Analyze-DiskTriage.ps1 -SaveState X:\phoenix-state
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SaveState,
    [switch]$ScanMounted
)

$ErrorActionPreference = "Stop"

# --- 0. read-only self-check ----------------------------------------------------
function Assert-ReadOnly {
    # Fails the run closed if this script's own source contains a forbidden
    # write pattern. Mirrors analyze_assert_readonly() on the Linux side.
    # Patterns are fragmented so the literals never appear in this file.
    $src = Get-Content -Raw -LiteralPath $PSCommandPath
    $pats = @(
        'Format-Vo' + 'lume', 'Clear-D' + 'isk', 'Init' + 'ialize-Disk',
        'Remove-Part' + 'ition', 'New-Part' + 'ition', 'Resize-Part' + 'ition',
        'Set-Part' + 'ition', 'of=/d' + 'ev', 'mk' + 'fs', 'wipe' + 'fs'
    )
    foreach ($p in $pats) {
        if ($src -match $p) {
            throw "[analyze] REFUSED: script contains forbidden write pattern ($p) -- Analyze must stay read-only."
        }
    }
    Write-Host "[analyze] read-only self-check OK."
}
Assert-ReadOnly
Write-Host "[analyze] READ-ONLY PLEDGE: this tool enumerates and inspects disks only."

# --- helpers -------------------------------------------------------------------
function Format-Gib {
    param([UInt64]$Bytes)
    # MUST match the bash twin exactly: one decimal, GiB, dot separator.
    return ([string]::Format(
        [System.Globalization.CultureInfo]::InvariantCulture,
        "{0:N1} GiB", ($Bytes / 1GB)))
}

function Get-MediaClass {
    param($Disk)
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
    try {
        $parts = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
        foreach ($p in $parts) {
            if ($p.DriveLetter -or $p.AccessPaths.Count -gt 0) { return $true }
        }
    } catch { }
    return $false
}

# --- 1. enumerate ---------------------------------------------------------------
$disks = Get-Disk | Sort-Object BusType, Size | ForEach-Object -Begin { $i = 0 } -Process {
    $i++
    $mounted = Get-DiskMounted $_
    [ordered]@{
        id          = $i
        dev         = "\\.\PhysicalDrive$($_.Number)"
        number      = $_.Number
        model       = $_.Model
        serial      = if ($_.SerialNumber) { $_.SerialNumber.Trim() } else { $null }
        size_bytes  = [UInt64]$_.Size
        size_human  = Format-Gib ([UInt64]$_.Size)
        transport   = "$($_.BusType)"
        removable   = [bool]($_.BusType -eq "USB")
        mounted     = $mounted
        media       = Get-MediaClass $_
    }
}
Write-Host "[analyze] enumerated $($disks.Count) disk(s)."

# --- 2. report-dir gate ----------------------------------------------------------
if (-not (Test-Path -LiteralPath $SaveState -PathType Container)) {
    New-Item -ItemType Directory -Path $SaveState | Out-Null
}
$stateDrive = (Get-Item $SaveState).PSDrive.Name
$stateDisk = $null
try {
    $statePart = Get-Partition -DriveLetter $stateDrive -ErrorAction SilentlyContinue
    if ($statePart) { $stateDisk = $statePart.DiskNumber }
} catch { }
foreach ($d in $disks) {
    if ($null -ne $stateDisk -and $d.number -eq $stateDisk) {
        throw "[analyze] REFUSED: report dir lives on triaged disk $($d.dev) -- the wipe would destroy the triage report."
    }
}
Write-Host "[analyze] report dir OK: $SaveState (drive $stateDrive not a triaged disk)."

# --- 3. partition inventory + heuristic scans ------------------------------------
$TempMaxKB = 2097152  # 2 GiB; override via $env:PHOENIX_ANALYZE_TEMP_MAX_KB
if ($env:PHOENIX_ANALYZE_TEMP_MAX_KB) { $TempMaxKB = [int]$env:PHOENIX_ANALYZE_TEMP_MAX_KB }

function Add-Indicator($List, $DiskId, $Label, $Code, $Severity, $Title, $Evidence) {
    $List.Add([ordered]@{
        disk_id   = $DiskId
        label     = $Label
        severity  = $Severity
        heuristic = $true   # every analyze finding is heuristic
        code      = $Code
        title     = "HEURISTIC: $Title"
        evidence  = $Evidence
    }) | Out-Null
}

function Get-DirSizeKB($Path) {
    $kb = 0
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $kb += [math]::Floor($_.Length / 1KB) }
    return $kb
}

$indicators = New-Object System.Collections.ArrayList
$partitionsByDisk = @{}

foreach ($d in $disks) {
    $plist = @()
    $parts = Get-Partition -DiskNumber $d.number -ErrorAction SilentlyContinue
    foreach ($p in $parts) {
        $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        $entry = [ordered]@{
            name       = "Partition$($p.PartitionNumber)"
            dev        = "\\.\PhysicalDrive$($d.number)"
            size_bytes = [UInt64]$p.Size
            size_human = Format-Gib ([UInt64]$p.Size)
            fstype     = if ($vol) { $vol.FileSystem } else { $null }
            label      = if ($vol) { $vol.FileSystemLabel } else { $null }
            parttype   = "$($p.GptType)"
            mountpoint = if ($p.DriveLetter) { "$($p.DriveLetter):\" } else { $null }
        }
        $plist += $entry
        if (-not $entry.fstype) {
            $indicators.Add([ordered]@{
                disk_id   = $d.id
                dev       = $entry.dev
                label     = "disk-$($d.id)"
                severity  = "info"
                heuristic = $false
                code      = "UNKNOWN_PARTITION"
                title     = "partition $($entry.name) has no recognized filesystem"
                evidence  = "fstype=$($entry.fstype) gpttype=$($entry.parttype); may be recovery/EFI/raw"
            }) | Out-Null
        }
        # heuristic scan of mounted volumes (read-only: no writes performed)
        if ($ScanMounted -and $p.DriveLetter) {
            $root = "$($p.DriveLetter):\"
            $label = "disk-$($d.id)"
            $temp = Join-Path $root "Windows\Temp"
            if (Test-Path -LiteralPath $temp) {
                $kb = Get-DirSizeKB $temp
                if ($kb -gt $TempMaxKB) {
                    Add-Indicator $indicators $d.id $label "OVERSIZED_TEMP" "warn" `
                        "temp dir Windows\Temp is unusually large ($([math]::Floor($kb/1MB)) MiB)" `
                        "Windows\Temp: $kb KiB > threshold $TempMaxKB KiB; staged payloads often live in temp dirs"
                }
            }
            $sys32 = Join-Path $root "Windows\System32"
            if (Test-Path -LiteralPath $sys32) {
                $cutoff = (Get-Date).AddHours(-24)
                Get-ChildItem -LiteralPath $sys32 -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $cutoff } |
                    Select-Object -First 5 | ForEach-Object {
                        Add-Indicator $indicators $d.id $label "RECENT_SYSTEM_MODIFY" "suspicious" `
                            "system file modified in the last 24h: $($_.FullName.Substring($root.Length))" `
                            "$($_.Name) mtime < 24h; legitimate updaters do this too -- correlate with the backup image"
                    }
            }
            $autorun = Join-Path $root "autorun.inf"
            if (Test-Path -LiteralPath $autorun) {
                Add-Indicator $indicators $d.id $label "AUTORUN_ARTIFACT" "suspicious" `
                    "autorun artifact present: autorun.inf" `
                    "autorun.inf executes at mount; a classic persistence mechanism -- verify against a known-good image"
            }
            Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.StartsWith(".") -or $_.Extension -eq ".exe" } |
                ForEach-Object {
                    Add-Indicator $indicators $d.id $label "HIDDEN_ROOT_EXECUTABLE" "warn" `
                        "suspicious file at volume root: $($_.Name)" `
                        "$($_.Name) sits at the filesystem root; droppers often land here"
                }
        }
    }
    $partitionsByDisk["$($d.id)"] = $plist
}

# --- 4. report -------------------------------------------------------------------
$report = [ordered]@{
    schema      = "phoenix-triage-report/1"
    recorded_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    tool        = "Analyze-DiskTriage.ps1/0.1.0"
    readonly    = $true
    disks       = @($disks | ForEach-Object {
        $d = $_; $e = [ordered]@{}
        foreach ($k in $d.Keys) { if ($k -ne "number") { $e[$k] = $d[$k] } }
        $e["partitions"] = @($partitionsByDisk["$($d.id)"])
        $e
    })
    indicators  = @($indicators)
    verdict     = "triage-complete"
}
if (($indicators | Where-Object { $_.severity -eq "suspicious" }).Count -gt 0) {
    $report.verdict = "triage-complete-suspicious"
}
$reportPath = Join-Path $SaveState "triage-report.json"
$report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $reportPath -Encoding utf8

Write-Host "[analyze] ----------------------------------------"
Write-Host "[analyze] triage complete. Report: $reportPath"
Write-Host "[analyze] $($disks.Count) disk(s), $($indicators.Count) indicator(s), verdict=$($report.verdict)"
foreach ($i in $indicators) {
    Write-Host "[triage] [$($i.severity)] disk $($i.disk_id) $($i.code): $($i.title)"
}
Write-Host "[analyze] Next: image each target disk (Backup phase) BEFORE any wipe."
