<#
.SYNOPSIS
    Phoenix candidate disk enumeration -- Windows/WinPE side of the pair.
    The bash twin is tools/lib/phoenix-disk-inventory.sh. Both implement the
    SAME exclusion contract -- keep them in sync.

.DESCRIPTION
    Enumerates disks via Get-Disk and prints the candidate table (device,
    model, serial, size, bus, ARM-CODE). EXCLUDES -- never lists as
    candidates -- the boot/system disk and any disk marked protected in
    phoenix-config.json ("nuke": { "protectedDisks": [...] }, matched by
    serial or \\.\PhysicalDriveN path). Excluded disks are named in a summary
    line so the operator can see the exclusion logic fired.

    The ARM-CODE is a per-disk transcription challenge: the first 6
    uppercase hex chars of sha256("phoenix-nuke-arm|<serial>|<model>|<size>").
    Derivation is byte-identical to the bash twin so codes agree across the
    pair. It is NOT a secret -- it forces the operator to read the row
    deliberately on a real console.

    Confirm-PhoenixArmCode prompts for the ARM-CODE (or exact serial) and
    refuses piped/redirected stdin structurally
    ([Console]::IsInputRedirected). Disks with no readable serial can never
    be armed. No Y/N, no default-yes.

    Contains NO destructive primitive. Dry-run (enumerate only) is the only
    mode of this script; arming happens in tools/Invoke-PhoenixNuke.ps1.

.EXAMPLE
    .\Get-PhoenixDiskInventory.ps1
    Enumerate candidates and exit 0.

.EXAMPLE
    .\Get-PhoenixDiskInventory.ps1 -ConfigPath E:\phoenix-config.json
    Enumerate with protected-disk exclusions from the given config.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PhoenixArmCode {
    <# Deterministic per-disk arm code. MUST match the bash twin byte for
       byte: sha256("phoenix-nuke-arm|<serial>|<model>|<size>"), first 6
       hex chars, uppercase. #>
    param([string]$Serial, [string]$Model, [string]$SizeBytes)
    $input = "phoenix-nuke-arm|$Serial|$Model|$SizeBytes"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($input)
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex   = ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
    return $hex.Substring(0, 6).ToUpper()
}

function Get-PhoenixProtectedList {
    <# Read "nuke.protectedDisks" from phoenix-config.json. Missing file or
       missing key => empty list (not an error). #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try {
        $cfg = Get-Content -Raw -Path $Path | ConvertFrom-Json
        $list = $cfg.nuke.protectedDisks
        if ($null -eq $list) { return @() }
        return @($list | ForEach-Object { "$_" })
    } catch {
        Write-Warning "Could not parse protectedDisks from $Path : $_"
        return @()
    }
}

function Get-PhoenixCandidates {
    param([string]$ConfigPath)
    $protected = Get-PhoenixProtectedList -Path $ConfigPath

    # Boot/system disk: Get-Disk flags plus the disk hosting the system drive.
    $systemDiskNumber = $null
    try {
        $sysPart = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($sysPart) { $systemDiskNumber = $sysPart.DiskNumber }
    } catch { }

    $candidates = @()
    $hidden = @()
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        if ($d.BusType -eq "File Backed Virtual") { continue }  # VHD/X mounts
        $dev    = "\\.\PhysicalDrive$($d.Number)"
        $model  = if ($d.FriendlyName) { $d.FriendlyName.Trim() } else { "(unknown)" }
        $serial = if ($d.SerialNumber)  { $d.SerialNumber.Trim() } else { "" }
        $size   = "$($d.Size)"
        $bus    = "$($d.BusType)".ToLower()

        $isBootish = $d.IsBoot -or $d.IsSystem -or
                     ($null -ne $systemDiskNumber -and $d.Number -eq $systemDiskNumber)
        if ($isBootish) {
            $hidden += [pscustomobject]@{ Device = $dev; Why = "BOOT-USB" }
            continue
        }
        $isProtected = $false
        foreach ($p in $protected) {
            if ($p -ceq $serial -or $p -ceq $dev) { $isProtected = $true; break }
        }
        if ($isProtected) {
            $hidden += [pscustomobject]@{ Device = $dev; Why = "PROTECTED(config)" }
            continue
        }

        $flags = ""
        if (-not $serial) { $serial = "(unknown)"; $flags = "NO-SERIAL " }
        if ($bus -eq "usb") { $flags += "USB " }
        $code = Get-PhoenixArmCode -Serial $serial -Model $model -SizeBytes $size
        $candidates += [pscustomobject]@{
            Row     = $candidates.Count
            Device  = $dev
            Model   = $model
            Serial  = $serial
            Size    = $size
            Bus     = $bus
            ArmCode = $code
            Flags   = $flags.Trim()
        }
    }
    return @{ Candidates = $candidates; Hidden = $hidden }
}

function Format-PhoenixSize {
    param([string]$Bytes)
    $b = 0; [void][long]::TryParse($Bytes, [ref]$b)
    if ($b -ge 1TB) { return "{0:N1} TB" -f ($b / 1TB) }
    if ($b -ge 1GB) { return "{0:N1} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    return "$b B"
}

function Confirm-PhoenixArmCode {
    <#
    .SYNOPSIS
        Typed-confirmation gate: the operator must type the target's ARM-CODE
        or its exact serial on a real console. Piped/redirected stdin is
        refused structurally. Returns $true only on an exact match.
    #>
    param([string]$Serial, [string]$ArmCode)
    if (-not $Serial -or $Serial -eq "(unknown)") {
        Write-Error "REFUSED: disk has no readable serial -- cannot be armed."
        return $false
    }
    if ([Console]::IsInputRedirected) {
        Write-Error "REFUSED: confirmation requires a real console (stdin is redirected)."
        return $false
    }
    $got = Read-Host "Type the ARM-CODE (or exact serial) of the disk to arm"
    if ($got -ceq $ArmCode -or $got -ceq $Serial) {
        Write-Host "ARMED [$(Get-Date -Format o)] evidence=typed-arm-code-or-serial"
        return $true
    }
    Write-Error "ABORTED: input did not match the ARM-CODE or the exact serial."
    return $false
}

# --- main: enumerate only, exit 0 ---------------------------------------------
if (-not $ConfigPath -and (Test-Path ".\phoenix-config.json")) {
    $ConfigPath = ".\phoenix-config.json"
}
$result = Get-PhoenixCandidates -ConfigPath $ConfigPath

Write-Host "=== Phoenix NUKE -- candidate disks (dry-run: nothing will be touched) ==="
"{0,-3} {1,-22} {2,-20} {3,-16} {4,-9} {5,-8} {6,-8} {7}" -f "#","DEVICE","MODEL","SERIAL","SIZE","BUS","ARM-CODE","FLAGS"
foreach ($c in $result.Candidates) {
    "{0,-3} {1,-22} {2,-20} {3,-16} {4,-9} {5,-8} {6,-8} {7}" -f `
        $c.Row, $c.Device, $c.Model.Substring(0, [Math]::Min(20, $c.Model.Length)),
        $c.Serial.Substring(0, [Math]::Min(16, $c.Serial.Length)),
        (Format-PhoenixSize $c.Size), $c.Bus, $c.ArmCode, $c.Flags
}
Write-Host ""
if ($result.Hidden.Count -gt 0) {
    Write-Host "Excluded from candidacy ($($result.Hidden.Count)):"
    foreach ($h in $result.Hidden) { Write-Host "  hidden: $($h.Device) ($($h.Why))" }
} else {
    Write-Host "Excluded from candidacy: none"
}
Write-Host ""
Write-Host "To arm a wipe, a NUKE-path tool must call Confirm-PhoenixArmCode"
Write-Host "with the target's ARM-CODE (or exact serial), typed by the operator"
Write-Host "on a real console. Row numbers, device paths, Y/N and piped input"
Write-Host "are refused."
exit 0
