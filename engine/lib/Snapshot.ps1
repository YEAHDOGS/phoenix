# Phoenix engine: snapshots taken before apply, and undo.
#
# A snapshot is C:\ProgramData\Phoenix\snapshots\<ts>-<phase>\ with:
#   meta.json      { id, phase, created, steps, computer }
#   records.json   { services: [], registry: [], autoruns: [], devices: [], tasks: [], bindings: [], commands: [], nonRestorable: [] }
#   firewall.wfw   netsh advfirewall export (when a firewall step runs)

$script:PhxSnap = $null

function Get-PhxSnapshotsRoot { Join-Path (Get-PhxDataRoot) 'snapshots' }

function New-PhxSnapshot([string]$Phase, [string[]]$StepIds) {
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $Phase
    $dir = Join-Path (Get-PhxSnapshotsRoot) $id
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:PhxSnap = @{
        id      = $id
        dir     = $dir
        records = @{
            services = New-Object System.Collections.Generic.List[object]
            registry = New-Object System.Collections.Generic.List[object]
            autoruns = New-Object System.Collections.Generic.List[object]
            devices  = New-Object System.Collections.Generic.List[object]
            tasks    = New-Object System.Collections.Generic.List[object]
            bindings = New-Object System.Collections.Generic.List[object]
            commands = New-Object System.Collections.Generic.List[object]
            nonRestorable = New-Object System.Collections.Generic.List[object]
        }
        firewallExported = $false
    }
    Write-PhxJson (Join-Path $dir 'meta.json') ([ordered]@{
            id = $id; phase = $Phase; created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            steps = @($StepIds); computer = $env:COMPUTERNAME
        })
    Save-PhxSnapshot
    $script:PhxSnap
}

# Record prior state. Only active during apply; a no-op otherwise.
function Add-PhxSnapshotRecord([ValidateSet('services', 'registry', 'autoruns', 'devices', 'tasks', 'bindings', 'commands', 'nonRestorable')][string]$Kind, $Record) {
    if (-not $script:PhxSnap) { return }
    $script:PhxSnap.records[$Kind].Add($Record)
}

function Save-PhxSnapshot {
    if (-not $script:PhxSnap) { return }
    $r = $script:PhxSnap.records
    $out = [ordered]@{}
    foreach ($k in @($r.Keys)) { $out[$k] = @($r[$k].ToArray()) }
    Write-PhxJson (Join-Path $script:PhxSnap.dir 'records.json') $out
}

function Export-PhxSnapshotFirewall {
    if (-not $script:PhxSnap -or $script:PhxSnap.firewallExported) { return }
    $file = Join-Path $script:PhxSnap.dir 'firewall.wfw'
    $out = & netsh.exe advfirewall export "$file" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "netsh advfirewall export failed: $out" }
    $script:PhxSnap.firewallExported = $true
}

function Close-PhxSnapshot {
    Save-PhxSnapshot
    $script:PhxSnap = $null
}

function Invoke-PhxSnapshots([hashtable]$A) {
    $root = Get-PhxSnapshotsRoot
    if (-not (Test-Path $root)) { return , @() }
    , @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending | ForEach-Object {
            $meta = $null; $counts = [ordered]@{}
            $mp = Join-Path $_.FullName 'meta.json'
            $rp = Join-Path $_.FullName 'records.json'
            if (Test-Path $mp) { try { $meta = Read-PhxJson $mp } catch { } }
            if (Test-Path $rp) {
                try { $rec = Read-PhxJson $rp; foreach ($k in @($rec.Keys)) { $counts[$k] = @($rec[$k]).Count } } catch { }
            }
            [ordered]@{
                id = $_.Name; phase = $(if ($meta) { $meta['phase'] } else { $null })
                created = $(if ($meta) { $meta['created'] } else { $_.CreationTimeUtc.ToString('s') })
                steps = $(if ($meta) { $meta['steps'] } else { @() })
                hasFirewall = (Test-Path (Join-Path $_.FullName 'firewall.wfw'))
                counts = $counts
            }
        })
}

function Invoke-PhxUndo([hashtable]$A) {
    Assert-PhxAdmin 'undo'
    $id = [string]$A['snapshotId']
    if (-not $id) { throw "undo: 'snapshotId' is required." }
    $dir = Join-Path (Get-PhxSnapshotsRoot) $id
    if (-not (Test-Path -LiteralPath $dir)) { throw "Snapshot not found: $id" }
    $rec = Read-PhxJson (Join-Path $dir 'records.json')
    $restored = 0; $failed = 0
    $step = 'undo'

    $tryRestore = {
        param([string]$Key, [scriptblock]$Do, $Current, $Target)
        try { & $Do; Write-PhxChange -Step $step -Key $Key -Current $Current -Target $Target -Action set -Applied $true; $script:PhxUndoOk++ }
        catch { Write-PhxChange -Step $step -Key $Key -Current $Current -Target $Target -Action set -Applied $false -Msg ('FAILED: ' + $_.Exception.Message); $script:PhxUndoFail++ }
    }
    $script:PhxUndoOk = 0; $script:PhxUndoFail = 0

    Write-PhxStep -Step $step -Status start -Msg "Restoring snapshot $id"

    # Reverse order inside each kind so the earliest prior value wins.
    $rev = { param($list) $a = @($list); [array]::Reverse($a); $a }

    foreach ($r in (& $rev $rec['autoruns'])) {
        & $tryRestore ("autoruns:" + $r['name']) { Restore-PhxAutorunRecord $r } 'disabled' 'enabled'
    }
    foreach ($r in (& $rev $rec['registry'])) {
        & $tryRestore ("registry:" + $r['path'] + '\' + $r['name']) { Restore-PhxRegistryRecord $r } '' $(if ($r['existed']) { $r['value'] } else { '(absent)' })
    }
    foreach ($r in (& $rev $rec['services'])) {
        & $tryRestore ("service:" + $r['name']) { Restore-PhxServiceRecord $r } '' $r['start']
    }
    foreach ($r in (& $rev $rec['tasks'])) {
        & $tryRestore ("task:" + $r['path']) {
            if ($r['state'] -ne 'Disabled') { Enable-ScheduledTask -TaskPath $r['taskPath'] -TaskName $r['taskName'] -ErrorAction Stop | Out-Null }
        } 'Disabled' $r['state']
    }
    foreach ($r in (& $rev $rec['devices'])) {
        if ($r['action'] -eq 'disable' -and $r['wasEnabled']) {
            & $tryRestore ("device:" + $r['instanceId']) {
                $o = & pnputil.exe /enable-device "$($r['instanceId'])" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "pnputil: $o" }
            } 'disabled' 'enabled'
        }
    }
    foreach ($r in (& $rev $rec['bindings'])) {
        & $tryRestore ("binding:" + $r['adapter'] + ':' + $r['componentId']) {
            if ($r['enabled']) { Enable-NetAdapterBinding -Name $r['adapter'] -ComponentID $r['componentId'] -ErrorAction Stop }
            else { Disable-NetAdapterBinding -Name $r['adapter'] -ComponentID $r['componentId'] -ErrorAction Stop }
        } '' $r['enabled']
    }
    foreach ($r in (& $rev $rec['commands'])) {
        & $tryRestore ("command:" + $r['label']) {
            $o = & cmd.exe /c $r['undo'] 2>&1
            if ($LASTEXITCODE -ne 0) { throw "$($r['undo']): $o" }
        } '' $r['undo']
    }
    $fw = Join-Path $dir 'firewall.wfw'
    if (Test-Path $fw) {
        & $tryRestore 'firewall' {
            $o = & netsh.exe advfirewall import "$fw" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh import: $o" }
        } '' 'snapshot policy'
    }

    $nr = @($rec['nonRestorable'])
    foreach ($n in $nr) {
        Write-PhxChange -Step $step -Key ([string]$n['key']) -Current 'removed' -Target 'n/a' -Action skip -Msg ("Not restorable automatically: " + $n['hint'])
    }
    $status = if ($script:PhxUndoFail -gt 0) { 'fail' } else { 'ok' }
    Write-PhxStep -Step $step -Status $status -Msg "$($script:PhxUndoOk) restored, $($script:PhxUndoFail) failed, $($nr.Count) not restorable"
    [ordered]@{ snapshotId = $id; restored = $script:PhxUndoOk; failed = $script:PhxUndoFail; nonRestorable = $nr }
}
