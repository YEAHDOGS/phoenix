#Requires -Version 5.1
# Back up plugged-in USB drives / SD cards: raw image, folder copy, burnable ISO, zip - pick any combination from a checklist
<#
.SYNOPSIS
    Back up plugged-in USB drives / SD cards every useful way at once.

.DESCRIPTION
    Pick one or more removable disks and any of these outputs (checklist GUI, or -Do on the command line):
      Image   raw sector-for-sector .img of the whole disk + .sha256   (restore with clone tools; 7-Zip can open it and extract files)
      Folder  plain copy of every mounted volume's files (robocopy)
      Iso     burnable UDF/Joliet .iso built from the files (Windows "Burn disc image" / any burner; 7-Zip can open it)
      Zip     .zip of the files (7-Zip zip64, falls back to Compress-Archive)
      Burn    hand the .iso to Windows' built-in isoburn.exe (opens the burn dialog)
    Everything lands in <Destination>\<label>_<serial>_<timestamp>\ with a manifest.json and a log.
    When Folder is selected together with Iso/Zip, the card is read once and the ISO/ZIP are built from the copy.

.EXAMPLE
    usb-backup.ps1                                   # GUI: choose drives + outputs
    usb-backup.ps1 -Disks 1 -Do Image,Folder,Iso     # no GUI
    usb-backup.ps1 -Disks 1,2 -Do Image -Destination D:\Backups\usb
#>
param(
    [int[]]$Disks,
    [ValidateSet('Image','Folder','Iso','Zip','Burn')][string[]]$Do,
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Backups\usb'),
    [switch]$NoGui,
    [switch]$KeepFolderWhenZipped   # by default the Folder copy is kept; this is here for clarity only
)
$ErrorActionPreference = 'Stop'
$SevenZip = @('C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- discovery
function Get-RemovableDisks {
    Get-Disk | Where-Object { $_.BusType -in 'USB','SD','MMC' -or $_.IsRemovable } | Sort-Object Number | ForEach-Object {
        $d = $_
        $vols = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object {
            $v = Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue
            if ($v) { [PSCustomObject]@{ Letter=$_.DriveLetter; Label=$v.FileSystemLabel; FS=$v.FileSystem; UsedBytes=($v.Size-$v.SizeRemaining) } }
        }
        [PSCustomObject]@{
            Number=$d.Number; Name=$d.FriendlyName; Serial=($d.SerialNumber -replace '[^A-Za-z0-9]','').Trim(); Bytes=$d.Size
            SizeGB=[math]::Round($d.Size/1GB,2); Style=$d.PartitionStyle; Volumes=@($vols)
            Text=("Disk {0}: {1}  {2} GB  [{3}]" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size/1GB,1), (($vols | ForEach-Object { "$($_.Letter): $($_.Label)" }) -join ', '))
        }
    }
}
$all = @(Get-RemovableDisks)
if (-not $all) { Write-Host 'No removable disks found.' -ForegroundColor Yellow; exit 1 }
$actions = [ordered]@{
    Image  = 'Raw disk image (.img + sha256) - exact clone, 7-Zip can open it'
    Folder = 'Folder copy of all files (robocopy)'
    Iso    = 'Burnable .iso of the files (UDF/Joliet, 7-Zip can open it)'
    Zip    = '.zip of the files'
    Burn   = 'Burn the .iso to a disc now (Windows burn dialog)'
}

# ---------------------------------------------------------------- selection (GUI / console / params)
if (-not $Disks -or -not $Do) {
    $useGui = -not $NoGui -and $env:OS -eq 'Windows_NT'
    if ($useGui) {
        try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing } catch { $useGui = $false }
    }
    if ($useGui) {
        $f = New-Object Windows.Forms.Form; $f.Text = 'USB backup'; $f.Size = '620,520'; $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false
        $l1 = New-Object Windows.Forms.Label; $l1.Text = 'Drives to back up'; $l1.Location = '12,10'; $l1.AutoSize = $true; $f.Controls.Add($l1)
        $clbD = New-Object Windows.Forms.CheckedListBox; $clbD.Location = '12,30'; $clbD.Size = '580,120'; $clbD.CheckOnClick = $true
        foreach ($d in $all) { [void]$clbD.Items.Add($d.Text, ($null -eq $Disks -or $d.Number -in $Disks)) }
        $f.Controls.Add($clbD)
        $l2 = New-Object Windows.Forms.Label; $l2.Text = 'What to make'; $l2.Location = '12,160'; $l2.AutoSize = $true; $f.Controls.Add($l2)
        $clbA = New-Object Windows.Forms.CheckedListBox; $clbA.Location = '12,180'; $clbA.Size = '580,120'; $clbA.CheckOnClick = $true
        foreach ($k in $actions.Keys) { [void]$clbA.Items.Add("$k  -  $($actions[$k])", ($k -in @('Image','Folder','Iso','Zip') -and ($null -eq $Do -or $k -in $Do))) }
        $f.Controls.Add($clbA)
        $l3 = New-Object Windows.Forms.Label; $l3.Text = 'Destination folder'; $l3.Location = '12,310'; $l3.AutoSize = $true; $f.Controls.Add($l3)
        $tb = New-Object Windows.Forms.TextBox; $tb.Location = '12,330'; $tb.Size = '500,24'; $tb.Text = $Destination; $f.Controls.Add($tb)
        $br = New-Object Windows.Forms.Button; $br.Text = '...'; $br.Location = '518,328'; $br.Size = '74,26'
        $br.Add_Click({ $fb = New-Object Windows.Forms.FolderBrowserDialog; if ($fb.ShowDialog() -eq 'OK') { $tb.Text = $fb.SelectedPath } }); $f.Controls.Add($br)
        $free = try { [math]::Round((Get-PSDrive ($Destination.Substring(0,1))).Free/1GB,1) } catch { '?' }
        $l4 = New-Object Windows.Forms.Label; $l4.Text = "Free space on destination drive: $free GB.  A raw image needs the full disk size; Folder/Iso/Zip need the used size each."; $l4.Location = '12,362'; $l4.Size = '580,36'; $f.Controls.Add($l4)
        $ok = New-Object Windows.Forms.Button; $ok.Text = 'Start'; $ok.Location = '412,430'; $ok.Size = '90,30'; $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
        $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = '508,430'; $cancel.Size = '84,30'; $cancel.DialogResult = 'Cancel'; $f.Controls.Add($cancel); $f.CancelButton = $cancel
        if ($f.ShowDialog() -ne 'OK') { exit }
        $Disks = @(0..($all.Count-1) | Where-Object { $clbD.GetItemChecked($_) } | ForEach-Object { $all[$_].Number })
        $Do = @(0..($actions.Count-1) | Where-Object { $clbA.GetItemChecked($_) } | ForEach-Object { @($actions.Keys)[$_] })
        $Destination = $tb.Text
    } else {
        Write-Host "Removable disks:"; $all | ForEach-Object { Write-Host "  $($_.Text)" }
        if (-not $Disks) { $Disks = @((Read-Host 'Disk numbers to back up (comma separated)') -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
        if (-not $Do) { Write-Host "Outputs:"; $actions.Keys | ForEach-Object { Write-Host "  $_  -  $($actions[$_])" }; $Do = @((Read-Host 'Outputs (comma separated, e.g. Image,Folder,Iso,Zip)') -split '[,\s]+' | Where-Object { $_ }) }
    }
}
if (-not $Disks -or -not $Do) { Write-Host 'Nothing selected.'; exit }
if ('Burn' -in $Do -and 'Iso' -notin $Do) { $Do += 'Iso' }

# ---------------------------------------------------------------- elevation: ONLY the raw image needs it
# Folder / Iso / Zip / Burn are ordinary file reads and run as the normal user.
if ('Image' -in $Do -and -not $isAdmin) {
    Write-Host 'Raw disk image needs administrator rights (Windows blocks raw sector reads otherwise); relaunching elevated for this run...' -ForegroundColor Yellow
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Disks',($Disks -join ','),'-Do',($Do -join ','),'-Destination',"`"$Destination`"",'-NoGui')
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    try { Start-Process $exe -Verb RunAs -ArgumentList $args -Wait } catch { Write-Host 'Elevation declined. Rerun without Image, or run from an admin shell.' -ForegroundColor Red; exit 1 }
    exit
}

# ---------------------------------------------------------------- helpers
$script:Log = $null
function L($m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $line; if ($script:Log) { Add-Content -Path $script:Log -Value $line } }

function New-RawImage([int]$DiskNumber, [long]$Bytes, [string]$Path) {
    $src = New-Object IO.FileStream("\\.\PhysicalDrive$DiskNumber",'Open','Read','ReadWrite')
    $dst = [IO.File]::Create($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] 8MB; $one = New-Object byte[] 512; $zero = New-Object byte[] 512
    [long]$pos = 0; $bad = New-Object System.Collections.Generic.List[long]; $sw = [Diagnostics.Stopwatch]::StartNew(); $lastPct = -1
    while ($pos -lt $Bytes) {
        [int]$want = [Math]::Min([long]$buf.Length, $Bytes - $pos); $ok = $false
        try { $src.Seek($pos,'Begin') | Out-Null; $n = $src.Read($buf,0,$want); if ($n -eq $want) { $ok = $true } } catch { }
        if (-not $ok) {   # per-sector retry for this chunk, zero-fill what still fails
            for ([long]$s = 0; $s -lt $want; $s += 512) {
                $got = $false
                for ($t = 0; $t -lt 4 -and -not $got; $t++) { try { $src.Seek($pos+$s,'Begin') | Out-Null; if ($src.Read($one,0,512) -eq 512) { $got = $true } } catch { Start-Sleep -Milliseconds 50 } }
                if ($got) { [Array]::Copy($one,0,$buf,$s,512) } else { [Array]::Copy($zero,0,$buf,$s,512); $bad.Add(($pos+$s)/512) }
            }
        }
        $dst.Write($buf,0,$want); $sha.TransformBlock($buf,0,$want,$null,0) | Out-Null; $pos += $want
        $pct = [int]($pos*100/$Bytes); if ($pct -ne $lastPct -and $pct % 10 -eq 0) { L ("    image {0}%  {1} MB/s" -f $pct, [math]::Round($pos/1MB/$sw.Elapsed.TotalSeconds,1)); $lastPct = $pct }
    }
    $sha.TransformFinalBlock($buf,0,0) | Out-Null; $dst.Close(); $src.Close()
    $hash = ([BitConverter]::ToString($sha.Hash)) -replace '-',''
    $hash | Set-Content "$Path.sha256" -NoNewline
    return @{ Hash = $hash; BadSectors = $bad.Count; BadList = @($bad | Select-Object -First 200); Seconds = [int]$sw.Elapsed.TotalSeconds }
}

# IStream -> file helper for IMAPI2 (the standard New-IsoFile pattern)
if (-not ('UsbBackup.IsoWriter' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices.ComTypes;
namespace UsbBackup { public static class IsoWriter {
  public static void Write(string path, object streamObj, int blockSize, long totalBlocks) {
    IStream stream = (IStream)streamObj; byte[] buf = new byte[blockSize * 256];
    using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
      IntPtr pRead = System.Runtime.InteropServices.Marshal.AllocHGlobal(sizeof(int));
      try {
        long remaining = totalBlocks;
        while (remaining > 0) {
          int want = (int)Math.Min((long)buf.Length, remaining * blockSize);
          stream.Read(buf, want, pRead);
          int read = System.Runtime.InteropServices.Marshal.ReadInt32(pRead);
          if (read <= 0) break;
          fs.Write(buf, 0, read); remaining -= read / blockSize;
        }
      } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(pRead); }
    } } } }
'@
}
function New-IsoFromFolders([hashtable]$Roots, [string]$Path, [string]$Label) {
    # $Roots: @{ 'SUBFOLDER' = 'X:\source' } - each source becomes a top-level folder in the ISO
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $big = $false
    foreach ($r in $Roots.Values) { if (Get-ChildItem $r -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -ge 4GB } | Select-Object -First 1) { $big = $true } }
    $fsi.FileSystemsToCreate = if ($big) { 4 } else { 7 }   # 4 = UDF only (files >= 4 GB), 7 = ISO9660 + Joliet + UDF
    $fsi.UDFRevision = 0x102
    $fsi.VolumeName = ($Label -replace '[^A-Za-z0-9_ -]','').Substring(0, [Math]::Min(30, $Label.Length))
    $fsi.FreeMediaBlocks = 2147483647   # no media-size limit; the burner decides later
    foreach ($k in $Roots.Keys) {
        $sub = ($k -replace '[\\/:*?"<>|]','_')
        $fsi.Root.AddDirectory($sub)            # returns nothing; fetch the item afterwards
        $fsi.Root.Item($sub).AddTree($Roots[$k], $false)
    }
    $result = $fsi.CreateResultImage()
    [UsbBackup.IsoWriter]::Write($Path, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
    return @{ Blocks = $result.TotalBlocks; BlockSize = $result.BlockSize; Udf = $big }
}

# ---------------------------------------------------------------- main
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
foreach ($n in $Disks) {
    $d = $all | Where-Object Number -eq $n
    if (-not $d) { Write-Host "Disk $n is not a removable disk, skipping." -ForegroundColor Yellow; continue }
    $labels = ($d.Volumes | ForEach-Object { $_.Label } | Where-Object { $_ }) -join '+'
    $name = (@($labels, $d.Serial, $stamp) | Where-Object { $_ }) -join '_'
    $name = $name -replace '[\\/:*?"<>|]','_'
    $out = Join-Path $Destination $name
    New-Item -ItemType Directory -Force $out | Out-Null
    $script:Log = Join-Path $out 'backup.log'
    L "=== $($d.Text)"
    L "=== outputs: $($Do -join ', ')  ->  $out"
    $manifest = [ordered]@{
        created = (Get-Date).ToString('o'); disk = $d.Number; friendlyName = $d.Name; serial = $d.Serial; bytes = $d.Bytes; partitionStyle = $d.Style
        partitions = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ number=$_.PartitionNumber; offset=$_.Offset; size=$_.Size; type=$_.Type; gptType=$_.GptType; letter=$_.DriveLetter } })
        volumes = @($d.Volumes | ForEach-Object { [ordered]@{ letter=$_.Letter; label=$_.Label; fs=$_.FS; usedBytes=$_.UsedBytes } })
        outputs = [ordered]@{}
    }
    $filesDir = Join-Path $out 'files'
    $sources = @{}   # name -> path, used by Iso/Zip
    foreach ($v in $d.Volumes) { $sources[($(if ($v.Label) { $v.Label } else { "drive_$($v.Letter)" }))] = "$($v.Letter):\" }

    if ('Folder' -in $Do) {
        L "-- Folder copy"
        $copied = @{}
        foreach ($k in @($sources.Keys)) {
            $dst = Join-Path $filesDir $k
            robocopy $sources[$k] $dst /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NP /NFL /NDL /XJ /XD 'System Volume Information' '$RECYCLE.BIN' /LOG+:"$out\robocopy.log" | Out-Null
            if ($LASTEXITCODE -ge 8) { L "   !! robocopy reported failures for $k (exit $LASTEXITCODE), see robocopy.log" }
            $copied[$k] = $dst
            L "   $k -> $dst"
        }
        $sources = $copied   # Iso/Zip now read from the local copy, not the card
        $manifest.outputs.folder = $filesDir
    }
    if ('Image' -in $Do) {
        $img = Join-Path $out "$name.img"
        L "-- Raw image -> $img ($($d.SizeGB) GB)"
        $r = New-RawImage -DiskNumber $d.Number -Bytes $d.Bytes -Path $img
        L ("   done in {0}s  sha256={1}  unreadable sectors={2}" -f $r.Seconds, $r.Hash, $r.BadSectors)
        $manifest.outputs.image = [ordered]@{ path=$img; sha256=$r.Hash; unreadableSectors=$r.BadSectors; unreadableLbas=$r.BadList }
    }
    if ('Iso' -in $Do) {
        $iso = Join-Path $out "$name.iso"
        L "-- ISO -> $iso"
        $r = New-IsoFromFolders -Roots $sources -Path $iso -Label ($(if ($labels) { $labels } else { $d.Serial }))
        L ("   done: {0} blocks x {1} = {2} MB  ({3})" -f $r.Blocks, $r.BlockSize, [math]::Round($r.Blocks*$r.BlockSize/1MB), $(if ($r.Udf) { 'UDF (files >= 4 GB present)' } else { 'ISO9660+Joliet+UDF' }))
        $manifest.outputs.iso = [ordered]@{ path=$iso; sha256=(Get-FileHash $iso -Algorithm SHA256).Hash }
    }
    if ('Zip' -in $Do) {
        $zip = Join-Path $out "$name.zip"
        L "-- ZIP -> $zip"
        if ($SevenZip) {
            $args = @('a','-tzip','-mx=1','-mmt=on','-bso0','-bsp0',"`"$zip`"")
            foreach ($k in $sources.Keys) { $args += "`"$($sources[$k])`"" }
            & $SevenZip @args
            if ($LASTEXITCODE -ne 0) { L "   !! 7-Zip exit code $LASTEXITCODE" }
        } else {
            Compress-Archive -Path ($sources.Values | ForEach-Object { "$_\*" }) -DestinationPath $zip -CompressionLevel Fastest -Force
        }
        L ("   done: {0} MB" -f [math]::Round((Get-Item $zip).Length/1MB))
        $manifest.outputs.zip = [ordered]@{ path=$zip; sha256=(Get-FileHash $zip -Algorithm SHA256).Hash }
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'manifest.json')
    if ('Burn' -in $Do -and $manifest.outputs.iso) {
        $burner = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($burner) { L "-- Burn: opening Windows burn dialog for $($manifest.outputs.iso.path)"; Start-Process "$env:WINDIR\System32\isoburn.exe" -ArgumentList "`"$($manifest.outputs.iso.path)`"" }
        else { L "-- Burn: no optical drive found; the .iso is ready to burn elsewhere" }
    }
    L "=== finished disk $($d.Number) -> $out"
}
