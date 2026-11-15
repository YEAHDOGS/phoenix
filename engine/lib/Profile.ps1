# Phoenix engine: pack loading and profile resolution (docs/ARCHITECTURE.md "Packs").

$script:PhxKnownKinds = @(
    'setting', 'services', 'devices', 'tasks', 'features', 'appx', 'registry', 'autoruns',
    'firewall', 'network', 'defender', 'bitlocker', 'choco', 'tools', 'manual'
)
$script:PhxPhases = @('admin', 'admin-post', 'user-offline', 'user-online')

# Deep copy of hashtables/arrays (JSON-shaped data only).
function Copy-PhxData($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($Obj.Keys)) { $h[$k] = Copy-PhxData $Obj[$k] }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return , @($Obj | ForEach-Object { Copy-PhxData $_ })
    }
    return $Obj
}

# Stable JSON for a hashtable (sorted keys) - used as the default key for device matches.
function ConvertTo-PhxStableJson($Obj) {
    if ($Obj -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in (@($Obj.Keys) | Sort-Object)) { '"' + $k + '":' + (ConvertTo-PhxStableJson $Obj[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    return (ConvertTo-Json -InputObject $Obj -Compress -Depth 5)
}

# The merge/override key of an item, per kind (docs: "default key").
function Get-PhxItemKey([string]$Kind, $Item) {
    if ($Item -isnot [System.Collections.IDictionary]) { return [string]$Item }
    if ($Item.Contains('key') -and $Item['key']) { return [string]$Item['key'] }
    switch ($Kind) {
        'setting' { return [string]$Item['setting'] }
        'services' { return [string]$Item['name'] }
        'devices' { return (ConvertTo-PhxStableJson $Item['match']) }
        'tasks' { return [string]$Item['path'] }
        'features' { return [string]$Item['name'] }
        'appx' { return [string]$Item['pattern'] }
        'registry' { return ([string]$Item['path']).TrimEnd('\') + '\' + [string]$Item['name'] }
        'autoruns' { return [string]$Item['name'] }
        'firewall' { return [string]$Item['name'] }
        'network' { return [string]$Item['binding'] }
        'tools' {
            foreach ($f in 'loadout', 'env', 'profileSnippet') {
                if ($Item.Contains($f) -and $Item[$f]) {
                    if ($f -eq 'profileSnippet') { return 'profileSnippet:' + (Get-PhxStringHash $Item[$f]) }
                    if ($f -eq 'env') { return 'env:' + $Item[$f] + '=' + $Item['value'] }
                    return 'loadout:' + $Item[$f]
                }
            }
        }
    }
    if ($Item.Contains('name')) { return [string]$Item['name'] }
    return (ConvertTo-PhxStableJson $Item)
}

function Get-PhxStringHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# Merge item lists by key: later fields win, new keys append. Returns a new array.
function Merge-PhxItems([string]$Kind, $BaseItems, $NewItems) {
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($src in @($BaseItems), @($NewItems)) {
        foreach ($it in $src) {
            if ($null -eq $it) { continue }
            $k = Get-PhxItemKey $Kind $it
            if ($map.ContainsKey($k)) {
                if ($it -is [System.Collections.IDictionary]) { foreach ($f in @($it.Keys)) { $map[$k][$f] = Copy-PhxData $it[$f] } }
            } else {
                $copy = Copy-PhxData $it
                if ($copy -isnot [System.Collections.IDictionary]) { $copy = @{ name = $copy } }
                $map[$k] = $copy
                $order.Add($k)
            }
        }
    }
    , @(foreach ($k in $order) { $map[$k]['_key'] = $k; $map[$k] })
}

function Merge-PhxStep($Base, $New) {
    $kind = if ($New.Contains('kind') -and $New['kind']) { $New['kind'] } else { $Base['kind'] }
    foreach ($f in @($New.Keys)) {
        if ($f -eq 'items') { continue }
        $Base[$f] = Copy-PhxData $New[$f]
    }
    if ($New.Contains('items')) {
        $baseItems = if ($Base.Contains('items')) { $Base['items'] } else { @() }
        $Base['items'] = Merge-PhxItems $kind $baseItems $New['items']
    }
    $Base
}

function Read-PhxPack([string]$Path) {
    $p = Read-PhxJson $Path
    if (-not $p.Contains('id') -or -not $p['id']) { $p['id'] = [IO.Path]::GetFileNameWithoutExtension($Path) }
    if (-not $p.Contains('steps') -or $null -eq $p['steps']) { $p['steps'] = @() }
    $p['_path'] = $Path
    $p
}

function Get-PhxPackIndex([string]$PacksRoot) {
    $index = @{}
    if (-not $PacksRoot -or -not (Test-Path -LiteralPath $PacksRoot)) { return $index }
    foreach ($f in Get-ChildItem -LiteralPath $PacksRoot -Filter '*.json' -File -Recurse) {
        try {
            $p = Read-PhxPack $f.FullName
            $index[[string]$p['id']] = $p
        } catch {
            Write-PhxLog -Level warn -Msg "Skipping unreadable pack $($f.FullName): $($_.Exception.Message)"
        }
    }
    $index
}

<#
 Resolves config + packs into the final step list.
   Get-PhxResolvedProfile -Config <hashtable from Get-PhxConfig> [-PacksRoot <dir>]
 Returns @{ configPath; packsRoot; packs = @(@{id;name;found;path}); steps = @(<step>) }
 Each step gets: enabled (bool), risk, phase, _sources (pack ids), items (each with _key, enabled).
#>
function Get-PhxResolvedProfile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [string]$PacksRoot)
    if (-not $PacksRoot) { $PacksRoot = Get-PhxPacksRoot }
    $index = Get-PhxPackIndex $PacksRoot

    $packInfo = New-Object System.Collections.Generic.List[object]
    $order = New-Object System.Collections.Generic.List[string]
    $steps = @{}
    $packIds = @()
    if ($Config.Contains('packs') -and $Config['packs']) { $packIds = @($Config['packs']) }

    foreach ($packRef in $packIds) {
        $pidS = [string]$packRef
        if (-not $index.ContainsKey($pidS)) {
            Write-PhxLog -Level warn -Msg "Pack '$pidS' listed in config was not found in $PacksRoot"
            $packInfo.Add([ordered]@{ id = $pidS; name = $pidS; found = $false; path = $null })
            continue
        }
        $pack = $index[$pidS]
        $packInfo.Add([ordered]@{ id = $pidS; name = $pack['name']; found = $true; path = $pack['_path'] })
        foreach ($s in @($pack['steps'])) {
            if ($null -eq $s -or -not $s.Contains('id')) { Write-PhxLog -Level warn -Msg "Pack '$pidS' has a step without an id; skipped."; continue }
            $sid = [string]$s['id']
            if ($steps.ContainsKey($sid)) {
                $steps[$sid] = Merge-PhxStep $steps[$sid] $s
                $steps[$sid]['_sources'] = @($steps[$sid]['_sources']) + $pidS
            } else {
                $copy = Copy-PhxData $s
                if ($copy.Contains('items')) { $copy['items'] = Merge-PhxItems ([string]$copy['kind']) @() $copy['items'] }
                $copy['_sources'] = @($pidS)
                $steps[$sid] = $copy
                $order.Add($sid)
            }
        }
    }

    # Defaults + danger gate (before overrides, so only overrides can enable danger).
    foreach ($sid in $order) {
        $s = $steps[$sid]
        if (-not $s.Contains('enabled')) { $s['enabled'] = $true }
        if (-not $s.Contains('risk') -or -not $s['risk']) { $s['risk'] = 'safe' }
        if ($s['risk'] -eq 'danger') { $s['enabled'] = $false }
        if (-not $s.Contains('items')) { $s['items'] = @() }
        foreach ($it in @($s['items'])) {
            if (-not $it.Contains('enabled')) { $it['enabled'] = $true }
            if ($it.Contains('risk') -and $it['risk'] -eq 'danger') { $it['enabled'] = $false }
        }
        if ($script:PhxKnownKinds -notcontains [string]$s['kind']) {
            $s['enabled'] = $false
            $s['_error'] = "Unknown step kind '$($s['kind'])'"
            Write-PhxLog -Level warn -Msg "Step '$sid' has unknown kind '$($s['kind'])'; disabled."
        }
        if ($s.Contains('phase') -and $script:PhxPhases -notcontains [string]$s['phase']) {
            Write-PhxLog -Level warn -Msg "Step '$sid' has unknown phase '$($s['phase'])'."
        }
    }

    # Config overrides.
    $ov = if ($Config.Contains('overrides') -and $Config['overrides']) { $Config['overrides'] } else { @{} }
    $ovSteps = if ($ov.Contains('steps') -and $ov['steps']) { $ov['steps'] } else { @{} }
    $ovItems = if ($ov.Contains('items') -and $ov['items']) { $ov['items'] } else { @{} }
    foreach ($sid in @($ovSteps.Keys)) {
        if (-not $steps.ContainsKey($sid)) { Write-PhxLog -Level warn -Msg "Override for unknown step '$sid' ignored."; continue }
        foreach ($f in @($ovSteps[$sid].Keys)) { $steps[$sid][$f] = Copy-PhxData $ovSteps[$sid][$f] }
        $steps[$sid]['_overridden'] = $true
    }
    foreach ($sid in @($ovItems.Keys)) {
        if (-not $steps.ContainsKey($sid)) { Write-PhxLog -Level warn -Msg "Item overrides for unknown step '$sid' ignored."; continue }
        $s = $steps[$sid]
        $s['items'] = Merge-PhxItems ([string]$s['kind']) $s['items'] $ovItems[$sid]
        foreach ($it in @($s['items'])) { if (-not $it.Contains('enabled')) { $it['enabled'] = $true } }
    }

    [ordered]@{
        configPath = $Config['_path']
        packsRoot  = $PacksRoot
        packs      = $packInfo.ToArray()
        steps      = @(foreach ($sid in $order) { $steps[$sid] })
    }
}

function Invoke-PhxProfile([hashtable]$A) {
    $cfg = Get-PhxConfig $A['configPath']
    Get-PhxResolvedProfile -Config $cfg -PacksRoot $A['packsRoot']
}

function Invoke-PhxPacks([hashtable]$A) {
    $root = if ($A['packsRoot']) { $A['packsRoot'] } else { Get-PhxPacksRoot }
    $index = Get-PhxPackIndex $root
    , @(foreach ($id in (@($index.Keys) | Sort-Object)) {
            $p = $index[$id]
            $steps = @($p['steps'])
            [ordered]@{
                id          = $id
                name        = $p['name']
                description = $p['description']
                version     = $p['version']
                tags        = $p['tags']
                stepCount   = $steps.Count
                phases      = @($steps | ForEach-Object { $_['phase'] } | Where-Object { $_ } | Sort-Object -Unique)
                path        = $p['_path']
            }
        })
}
