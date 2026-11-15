# Phoenix engine: `launch` - start a loadout tool from the kit (e.g. AME Wizard for the playbook step).
# Looks in <kit>\loadout\<id>\ first, then the build PC's cache. The manifest's optional
# `launch` field (exe path relative to the item folder) picks the executable.

function Get-PhxManifestItem([string]$Id) {
    $mp = Join-Path (Get-PhxKitRoot) 'loadout\manifest.json'
    if (-not (Test-Path -LiteralPath $mp)) { return $null }
    $m = Read-PhxJson $mp
    $items = if ($m -is [System.Collections.IDictionary] -and $m.Contains('items')) { @($m['items']) } else { @($m) }
    $items | Where-Object { [string]$_['id'] -eq $Id } | Select-Object -First 1
}

function Get-PhxLoadoutDirs([string]$Id) {
    , @(@((Join-Path (Get-PhxKitRoot) "loadout\$Id"), (Join-Path (Get-PhxCacheRoot) $Id)) | Where-Object { Test-Path -LiteralPath $_ })
}

# Path of a loadout item: its manifest `filename` inside the item folder when present
# (single-file items such as dogs-playbook.apbx), else the folder (extracted zips).
function Resolve-PhxLoadoutPath([string]$Id) {
    $dirs = Get-PhxLoadoutDirs $Id
    if ($dirs.Count -eq 0) { throw "Loadout '$Id' is not in the kit or the cache." }
    $item = Get-PhxManifestItem $Id
    foreach ($d in $dirs) {
        if ($item -and $item['filename']) {
            $f = Join-Path $d ([string]$item['filename'])
            if (Test-Path -LiteralPath $f) { return $f }
        }
    }
    $dirs[0]
}

# Expands {loadout:<id>} placeholders and environment variables in launch args.
function Expand-PhxLaunchArg([string]$Arg) {
    $out = [regex]::Replace($Arg, '\{loadout:([A-Za-z0-9._-]+)\}', { param($m) Resolve-PhxLoadoutPath $m.Groups[1].Value })
    [Environment]::ExpandEnvironmentVariables($out)
}

function Invoke-PhxLaunch([hashtable]$A) {
    $id = [string]$A['loadout']
    if (-not $id) { throw "launch: 'loadout' is required." }
    $dirs = Get-PhxLoadoutDirs $id
    if ($dirs.Count -eq 0) { throw "Loadout '$id' is not in the kit or the cache. Fetch it in the USB builder first." }
    $dir = $dirs[0]
    $item = Get-PhxManifestItem $id
    $exe = $null
    if ($item -and $item['launch']) {
        $cand = Join-Path $dir ([string]$item['launch'])
        $hits = @(Get-ChildItem -Path $cand -ErrorAction SilentlyContinue)
        if ($hits) { $exe = $hits[0].FullName }
    }
    if (-not $exe) {
        $exe = Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $exe) { throw "No executable found for loadout '$id' in $dir." }
    $argList = @($A['args'] | Where-Object { $_ } | ForEach-Object { $x = Expand-PhxLaunchArg ([string]$_); if ($x -match '\s' -and $x -notmatch '^".*"$') { '"' + $x + '"' } else { $x } })
    $sp = @{ FilePath = $exe; WorkingDirectory = (Split-Path -Parent $exe); PassThru = $true }
    if ($argList.Count -gt 0) { $sp.ArgumentList = $argList }
    $p = Start-Process @sp
    Write-PhxLog -Msg "Launched $exe (pid $($p.Id))"
    [ordered]@{ pid = $p.Id; path = $exe; args = $argList }
}
