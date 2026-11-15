# Phoenix engine: USB build and verify (commands: usb-build, usb-verify).
#
# Writes the Phoenix kit onto an EXISTING, already-formatted removable volume.
# It never formats, partitions or cleans a disk, and it refuses system/boot
# disks and non-USB drives. Other files on the drive (e.g. a Ventoy stick)
# are left alone; only paths Phoenix writes are touched.
#
#   <root>\autounattend.xml
#   <root>\phoenix\phoenix.id, Phoenix.exe, phoenix.config.json
#   <root>\phoenix\scripts\engine\  config\packs\  config\catalog\
#   <root>\phoenix\config\loadout\manifest.json
#   <root>\phoenix\config\loadout\<id>\...   (zips extracted, files copied)
#   <root>\phoenix\SHA512SUMS            (every file Phoenix wrote, relative to <root>)

$script:PhxSumsName = 'phoenix\SHA512SUMS'

# Resolves and safety-checks the target. Returns @{ root; label; disk; testing }.
function Resolve-PhxUsbTarget([hashtable]$A) {
    if ($A['targetPath']) {
        $p = [string]$A['targetPath']
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        return @{ root = (Resolve-Path -LiteralPath $p).Path; label = 'test-target'; disk = $null; testing = $true }
    }
    $letter = ([string]$A['driveLetter']).Trim().TrimEnd(':', '\').ToUpper()
    if ($letter -notmatch '^[A-Z]$') { throw 'usb-build needs driveLetter (e.g. "E") or targetPath.' }
    if ($letter -eq ($env:SystemDrive.TrimEnd(':', '\').ToUpper())) { throw "Refusing ${letter}: it is the system drive." }

    $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Refusing ${letter}: disk $($disk.Number) holds the running system or its boot partition." }
    if (@('USB', 'SD', 'MMC') -notcontains [string]$disk.BusType) { throw "Refusing ${letter}: disk $($disk.Number) is on bus '$($disk.BusType)', not USB/SD." }
    if ($disk.IsReadOnly -or $vol.OperationalStatus -match 'ReadOnly') { throw "${letter}: is read-only (write-lock switch on?)." }
    if (@('FAT32', 'exFAT', 'NTFS') -notcontains [string]$vol.FileSystem) { throw "${letter}: has file system '$($vol.FileSystem)'. Format it FAT32, exFAT or NTFS first (Phoenix never formats drives)." }
    @{ root = "${letter}:\"; label = $vol.FileSystemLabel; disk = $disk.Number; testing = $false; freeBytes = $vol.SizeRemaining; fileSystem = [string]$vol.FileSystem }
}

function Copy-PhxTree([string]$From, [string]$To, [string[]]$ExcludeDirs = @()) {
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Force -Path $To | Out-Null }
    Get-ChildItem -LiteralPath $From -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($From.Length).TrimStart('\')
        -not ($ExcludeDirs | Where-Object { $rel -like "$_\*" })
    } | ForEach-Object {
        $rel = $_.FullName.Substring($From.Length).TrimStart('\')
        $dest = Join-Path $To $rel
        $dd = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

function Expand-PhxZip([string]$Zip, [string]$Dest, [string]$StepId) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($z.Entries | Where-Object { $_.Name })   # skip directory entries
        $i = 0; $last = -1
        $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
        foreach ($e in $entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Dest ($e.FullName -replace '/', '\')))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Zip entry escapes the target folder: $($e.FullName)" }
            $td = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $i++
            $pct = [int](($i * 100) / [Math]::Max(1, $entries.Count))
            if ($pct -ge $last + 5) { Write-PhxProgress -Step $StepId -Pct $pct -Msg "$i / $($entries.Count) files"; $last = $pct }
        }
    } finally { $z.Dispose() }
}

function Find-PhxAppExe {
    $kit = Get-PhxKitRoot
    $candidates = @(
        (Join-Path $kit 'Phoenix.exe')
        (Get-ChildItem -Path (Join-Path $kit 'app\src-tauri\target\release') -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'build|setup|installer' } |
            Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName -First 1)
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $candidates | Select-Object -First 1
}

# command: usb-build { configPath, secretsPath, driveLetter | targetPath, items? }
function Invoke-PhxUsbBuild([hashtable]$A) {
    $step = 'usb-build'
    $target = Resolve-PhxUsbTarget $A
    $root = $target['root']
    $kitOut = Join-Path $root 'phoenix'
    $config = Get-PhxConfig $A['configPath']
    $ids = if ($A['items']) { @($A['items']) } else { @($config['loadout']) }
    $ids = @($ids | Where-Object { $_ })
    $lock = Get-PhxLoadoutLock
    $manifest = Get-PhxLoadoutManifest
    Write-PhxLog "Building Phoenix USB at $root$(if ($target['testing']) { ' (test target)' })."

    # Space check (rough: sum of cached sources).
    $need = 0L
    foreach ($id in $ids) { $e = $lock['items'][$id]; if ($e -and $e['sizeBytes']) { $need += [long]$e['sizeBytes'] } }
    if ($target['freeBytes'] -and $need -gt [long]$target['freeBytes']) {
        throw ("Not enough space on {0}: need about {1:N0} MB, {2:N0} MB free." -f $root, ($need / 1MB), ($target['freeBytes'] / 1MB))
    }
    if ($target['fileSystem'] -eq 'FAT32') {
        foreach ($id in $ids) { $e = $lock['items'][$id]; if ($e -and [long]$e['sizeBytes'] -ge 4GB) { throw "$id is over 4 GB and $root is FAT32. Use exFAT or NTFS, or drop $id." } }
    }

    $written = New-Object System.Collections.Generic.List[string]
    function Add-Written([string]$Path) { if (Test-Path -LiteralPath $Path -PathType Leaf) { $written.Add($Path) } else { Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object { $written.Add($_.FullName) } } }

    # 1. Answer file (consumes and deletes the secrets file).
    Write-PhxStep -Step "$step.unattend" -Status start -Msg 'Answer file'
    $ua = Invoke-PhxUnattend @{ configPath = $config['_path']; secretsPath = $A['secretsPath']; outPath = (Join-Path $root 'autounattend.xml') }
    Add-Written (Join-Path $root 'autounattend.xml')
    Write-PhxStep -Step "$step.unattend" -Status ok -Msg 'autounattend.xml written'

    # 2. Kit: engine, packs, catalog, manifest, config, id, app.
    Write-PhxStep -Step "$step.kit" -Status start -Msg 'Engine, packs, config'
    $kit = Get-PhxKitRoot
    foreach ($d in 'scripts\engine', 'config\packs', 'config\catalog') {
        $dest = Join-Path $kitOut $d
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-PhxTree (Join-Path $kit $d) $dest -ExcludeDirs @('tests')
        Add-Written $dest
    }
    $loadoutOut = Get-PhxLoadoutRoot $kitOut
    if (-not (Test-Path $loadoutOut)) { New-Item -ItemType Directory -Force -Path $loadoutOut | Out-Null }
    Copy-Item -LiteralPath (Join-Path (Get-PhxLoadoutRoot $kit) 'manifest.json') -Destination (Join-Path $loadoutOut 'manifest.json') -Force
    Add-Written (Join-Path $loadoutOut 'manifest.json')

    $cfgOut = [ordered]@{}
    foreach ($k in $config.Keys) { if ($k -ne '_path') { $cfgOut[$k] = $config[$k] } }
    Write-PhxJson (Join-Path $kitOut 'phoenix.config.json') $cfgOut
    Add-Written (Join-Path $kitOut 'phoenix.config.json')

    $idPath = Join-Path $kitOut 'phoenix.id'
    Write-PhxJson $idPath ([ordered]@{
        id            = [guid]::NewGuid().ToString()
        builtAt       = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        computerName  = $config['machine']['computerName']
        engineVersion = $PhxEngineVersion
    })
    Add-Written $idPath

    $exe = Find-PhxAppExe
    if ($exe) {
        $exeOut = Join-Path $kitOut 'Phoenix.exe'
        if ([IO.Path]::GetFullPath($exe) -ne [IO.Path]::GetFullPath($exeOut)) { Copy-Item -LiteralPath $exe -Destination $exeOut -Force }
        Add-Written $exeOut
    } else {
        Write-PhxLog -Level warn -Msg 'Phoenix.exe not found (build the app first); the USB will have the engine but no app.'
    }
    Write-PhxStep -Step "$step.kit" -Status ok

    # 3. Loadout items.
    $missing = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($id in $ids) {
        $n++
        $s = "$step.loadout.$id"
        $item = @($manifest['items']) | Where-Object { $_['id'] -eq $id } | Select-Object -First 1
        $e = $lock['items'][$id]
        if (-not $item) { Write-PhxStep -Step $s -Status fail -Msg "Unknown loadout item '$id'."; $missing.Add($id); continue }
        $src = if ($e) { Get-PhxCachedFile $item $e } else { $null }
        if (-not $src -or -not (Test-Path -LiteralPath $src)) {
            Write-PhxStep -Step $s -Status skip -Msg "$id is not fetched yet; skipped."
            $missing.Add($id); continue
        }
        Write-PhxStep -Step $s -Status start -Msg "$($item['name']) ($n/$($ids.Count))"
        $dest = Join-Path $loadoutOut $id
        $marker = Join-Path $dest '.phoenix-source'
        if ((Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $e['sha512'])) {
            Write-PhxStep -Step $s -Status ok -Msg 'Unchanged since the last build.'
        } else {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            if ($item['kind'] -eq 'zip') {
                Expand-PhxZip -Zip $src -Dest $dest -StepId $s
            } else {
                Copy-Item -LiteralPath $src -Destination (Join-Path $dest $item['filename']) -Force
            }
            [IO.File]::WriteAllText($marker, $e['sha512'])
            Write-PhxStep -Step $s -Status ok
        }
        Add-Written $dest
    }

    # 4. SHA512SUMS over everything Phoenix wrote.
    Write-PhxStep -Step "$step.sums" -Status start -Msg 'Hashing everything written (SHA-512)'
    $sumsPath = Join-Path $root $script:PhxSumsName
    $lines = New-Object System.Collections.Generic.List[string]
    $files = @($written | Sort-Object -Unique | Where-Object { $_ -ne $sumsPath })
    $i = 0
    foreach ($f in $files) {
        $i++
        $rel = $f.Substring($root.TrimEnd('\').Length).TrimStart('\') -replace '\\', '/'
        $lines.Add("$(Get-PhxSha $f 'SHA512')  $rel")
        if ($i % 25 -eq 0) { Write-PhxProgress -Step "$step.sums" -Pct ([int](($i * 100) / $files.Count)) -Msg "$i / $($files.Count) files" }
    }
    [IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Write-PhxStep -Step "$step.sums" -Status ok -Msg "$($files.Count) files"

    [ordered]@{
        root          = $root
        testing       = $target['testing']
        unattend      = $ua
        fileCount     = $files.Count
        sha512sums    = $sumsPath
        sumsSha512    = (Get-PhxSha $sumsPath 'SHA512')
        missingItems  = $missing.ToArray()
        app           = [bool]$exe
    }
}

# command: usb-verify { driveLetter | targetPath }
function Invoke-PhxUsbVerify([hashtable]$A) {
    if ($A['targetPath']) { $root = (Resolve-Path -LiteralPath $A['targetPath']).Path }
    else {
        $letter = ([string]$A['driveLetter']).Trim().TrimEnd(':', '\').ToUpper()
        if ($letter -notmatch '^[A-Z]$') { throw 'usb-verify needs driveLetter or targetPath.' }
        $root = "${letter}:\"
    }
    $sumsPath = Join-Path $root $script:PhxSumsName
    if (-not (Test-Path -LiteralPath $sumsPath)) { throw "No SHA512SUMS at $sumsPath. Is this a Phoenix USB?" }
    $entries = @(Get-Content -LiteralPath $sumsPath -Encoding UTF8 | Where-Object { $_ -match '^[0-9a-f]{128}  ' })
    $bad = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($line in $entries) {
        $i++
        $hash = $line.Substring(0, 128)
        $rel = $line.Substring(130)
        $f = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $f)) { $bad.Add([ordered]@{ path = $rel; problem = 'missing' }) }
        elseif ((Get-PhxSha $f 'SHA512') -ne $hash) { $bad.Add([ordered]@{ path = $rel; problem = 'changed' }) }
        if ($i % 25 -eq 0) { Write-PhxProgress -Step 'usb-verify' -Pct ([int](($i * 100) / $entries.Count)) -Msg "$i / $($entries.Count)" }
    }
    if ($bad.Count) { Write-PhxLog -Level warn -Msg "$($bad.Count) of $($entries.Count) files are missing or changed." }
    else { Write-PhxLog "All $($entries.Count) files match SHA512SUMS." }
    [ordered]@{ root = $root; checked = $entries.Count; ok = ($bad.Count -eq 0); problems = $bad.ToArray(); sumsSha512 = (Get-PhxSha $sumsPath 'SHA512') }
}
