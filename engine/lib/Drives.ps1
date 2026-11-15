# Phoenix engine: `drives` - removable/USB disks the USB builder may write to. Read-only.
# Uses CIM associations (works without admin); Get-Disk enriches when available.

function Invoke-PhxDrives([hashtable]$A) {
    $sysLetter = $env:SystemDrive.TrimEnd('\')
    $out = New-Object System.Collections.Generic.List[object]
    $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceType -eq 'USB' -or $_.MediaType -like 'Removable*' -or $_.PNPDeviceID -like 'USBSTOR*'
        })
    $diskInfo = @{}
    try { foreach ($d in @(Get-Disk -ErrorAction Stop)) { $diskInfo[[int]$d.Number] = $d } } catch { }

    foreach ($d in $disks) {
        $num = [int]$d.Index
        $gd = if ($diskInfo.ContainsKey($num)) { $diskInfo[$num] } else { $null }
        $parts = @(Get-CimAssociatedInstance -InputObject $d -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)
        $vols = New-Object System.Collections.Generic.List[object]
        $isBoot = $false
        foreach ($p in $parts) {
            if ($p.BootPartition) { $isBoot = $true }
            foreach ($ld in @(Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
                $vols.Add([ordered]@{
                        letter = $ld.DeviceID; label = $ld.VolumeName; fileSystem = $ld.FileSystem
                        sizeBytes = [int64]$ld.Size; freeBytes = [int64]$ld.FreeSpace
                        hasPhoenix = (Test-Path -LiteralPath (Join-Path ($ld.DeviceID + '\') 'phoenix\phoenix.id'))
                        hasVentoy = (Test-Path -LiteralPath (Join-Path ($ld.DeviceID + '\') 'ventoy'))
                    })
            }
        }
        $isSystem = [bool]($vols | Where-Object { $_.letter -eq $sysLetter })
        if ($gd) { $isBoot = $isBoot -or [bool]$gd.IsBoot; $isSystem = $isSystem -or [bool]$gd.IsSystem }
        $first = $vols | Select-Object -First 1
        $out.Add([ordered]@{
                number     = $num
                model      = ([string]$d.Model).Trim()
                busType    = $(if ($gd) { [string]$gd.BusType } else { [string]$d.InterfaceType })
                sizeBytes  = [int64]$d.Size
                letter     = $(if ($first) { $first.letter } else { $null })
                label      = $(if ($first) { $first.label } else { $null })
                fileSystem = $(if ($first) { $first.fileSystem } else { $null })
                volumes    = @($vols.ToArray())
                isBoot     = $isBoot
                isSystem   = $isSystem
                readOnly   = $(if ($gd) { [bool]$gd.IsReadOnly } else { $null })
                serial     = ([string]$d.SerialNumber).Trim()
            })
    }
    , @($out.ToArray())
}
