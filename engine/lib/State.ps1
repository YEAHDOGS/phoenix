# Phoenix engine: runbook state (C:\ProgramData\Phoenix\state.json).

function Get-PhxStatePath { Join-Path (Get-PhxDataRoot) 'state.json' }

function Get-PhxState {
    $p = Get-PhxStatePath
    $st = $null
    if (Test-Path -LiteralPath $p) {
        try { $st = Read-PhxJson $p } catch { Write-PhxLog -Level warn -Msg "state.json unreadable, starting fresh: $($_.Exception.Message)" }
    }
    if (-not $st) { $st = @{} }
    if (-not $st.Contains('stages') -or -not $st['stages']) { $st['stages'] = @{} }
    if (-not $st.Contains('phases') -or -not $st['phases']) { $st['phases'] = @{} }
    $st
}

function Save-PhxState($State) {
    $State['updated'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-PhxJson (Get-PhxStatePath) $State
}

function Set-PhxStageStatus([string]$Stage, [string]$Status, [string]$Note = '') {
    $st = Get-PhxState
    $st['stages'][$Stage] = [ordered]@{ status = $Status; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); note = $Note }
    Save-PhxState $st
}

function Set-PhxPhaseStatus([string]$Phase, [string]$Status, [string]$Snapshot = '', $Summary = $null) {
    $st = Get-PhxState
    $st['phases'][$Phase] = [ordered]@{ status = $Status; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); snapshot = $Snapshot; summary = $Summary }
    Save-PhxState $st
}

function Get-PhxRunbookPath { Join-Path $PhxEngineRoot 'runbook.json' }

# engine/runbook.json may be an array of stages or { stages: [...] }.
function Get-PhxRunbookStages {
    $p = Get-PhxRunbookPath
    if (-not (Test-Path -LiteralPath $p)) { throw "Runbook not found at $p (engine/runbook.json has not been written yet)." }
    $rb = Read-PhxJson $p
    if ($rb -is [System.Collections.IDictionary]) {
        if ($rb.Contains('stages')) { return , @($rb['stages']) }
        throw "engine/runbook.json has no 'stages' array."
    }
    , @($rb)
}

function Invoke-PhxState([hashtable]$A) {
    $st = Get-PhxState
    [ordered]@{ path = (Get-PhxStatePath); stages = $st['stages']; phases = $st['phases']; updated = $st['updated'] }
}

function Invoke-PhxMark([hashtable]$A) {
    $stage = [string]$A['stage']
    $status = [string]$A['status']
    if (-not $stage) { throw "mark: 'stage' is required." }
    $allowed = 'pending', 'running', 'done', 'skipped', 'failed'
    if ($allowed -notcontains $status) { throw "mark: status must be one of $($allowed -join ', ')." }
    Set-PhxStageStatus -Stage $stage -Status $status -Note ([string]$A['note'])
    Invoke-PhxState @{}
}

function Invoke-PhxRunbook([hashtable]$A) {
    $stages = Get-PhxRunbookStages
    $st = Get-PhxState
    $out = foreach ($s in $stages) {
        $id = [string]$s['id']
        $status = 'pending'; $at = $null; $note = ''
        if ($st['stages'].Contains($id)) {
            $status = $st['stages'][$id]['status']; $at = $st['stages'][$id]['at']; $note = $st['stages'][$id]['note']
        } elseif ($s.Contains('phase') -and $s['phase'] -and $st['phases'].Contains([string]$s['phase'])) {
            $ph = $st['phases'][[string]$s['phase']]
            $status = if ($ph['status'] -eq 'ok') { 'done' } else { $ph['status'] }
            $at = $ph['at']
        }
        $copy = Copy-PhxData $s
        $copy['status'] = $status
        $copy['at'] = $at
        $copy['note'] = $note
        $copy
    }
    [ordered]@{ stages = @($out); statePath = (Get-PhxStatePath) }
}
