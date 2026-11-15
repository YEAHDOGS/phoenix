# Phoenix engine: plan / apply orchestration and the per-item change helper.
#
# Step handlers live in Steps.*.ps1 and are named Invoke-PhxStep_<kind>.
# Signature: Invoke-PhxStep_<kind> -Step <hashtable> -Ctx <hashtable>
# Ctx: @{ Mode = 'plan'|'apply'; Config; KitRoot; IsAdmin; Stats = @{changes;skipped;failed} }
# Handlers MUST NOT change anything when Ctx.Mode -eq 'plan'.

function New-PhxCtx([string]$Mode, $Config) {
    @{
        Mode    = $Mode
        Config  = $Config
        KitRoot = (Get-PhxKitRoot)
        IsAdmin = (Test-PhxIsAdmin)
        Stats   = @{ changes = 0; skipped = 0; failed = 0 }
    }
}

<#
 Reports one item and, in apply mode, runs -Do.
   Invoke-PhxChange -Ctx $Ctx -Step $id -Key k -Current c -Target t [-Action set] [-AtTarget] [-Do { ... }] [-Msg m]
 -AtTarget: already compliant -> 'skip' event, nothing runs.
 Variables used inside -Do resolve dynamically from the caller, so helper locals are prefixed.
#>
function Invoke-PhxChange {
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Key,
        $Current,
        $Target,
        [string]$Action = 'set',
        [switch]$AtTarget,
        [scriptblock]$Do,
        [string]$Msg = ''
    )
    $phxIcMsg = $Msg
    if ($AtTarget) {
        if (-not $phxIcMsg) { $phxIcMsg = 'already at target' }
        Write-PhxChange -Step $Step -Key $Key -Current $Current -Target $Target -Action skip -Applied $false -Msg $phxIcMsg
        $Ctx.Stats.skipped++
        return
    }
    if ($Ctx.Mode -ne 'apply') {
        Write-PhxChange -Step $Step -Key $Key -Current $Current -Target $Target -Action $Action -Applied $false -Msg $phxIcMsg
        $Ctx.Stats.changes++
        return
    }
    try {
        if ($Do) { $phxIcOut = & $Do; if ($phxIcOut -is [string] -and $phxIcOut) { $phxIcMsg = $phxIcOut } }
        Write-PhxChange -Step $Step -Key $Key -Current $Current -Target $Target -Action $Action -Applied $true -Msg $phxIcMsg
        $Ctx.Stats.changes++
    } catch {
        Write-PhxChange -Step $Step -Key $Key -Current $Current -Target $Target -Action $Action -Applied $false -Msg ('FAILED: ' + $_.Exception.Message)
        $Ctx.Stats.failed++
    }
}

# Report a problem with an item that isn't a change (bad definition, read error).
function Write-PhxItemError([hashtable]$Ctx, [string]$Step, [string]$Key, [string]$Msg) {
    Write-PhxChange -Step $Step -Key $Key -Current $null -Target $null -Action skip -Applied $false -Msg ('ERROR: ' + $Msg)
    $Ctx.Stats.failed++
}

function Get-PhxEnabledItems($Step) {
    , @(@($Step['items']) | Where-Object { $_ -and $_['enabled'] -ne $false })
}

function Get-PhxField($Obj, [string]$Name, $Default = $null) {
    if ($Obj -is [System.Collections.IDictionary] -and $Obj.Contains($Name) -and $null -ne $Obj[$Name]) { return $Obj[$Name] }
    return $Default
}

function Invoke-PhxStepHandler([hashtable]$Step, [hashtable]$Ctx) {
    $kind = [string]$Step['kind']
    $fn = "Invoke-PhxStep_$kind"
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "No handler for step kind '$kind'." }
    & $fn -Step $Step -Ctx $Ctx
}

function Select-PhxSteps($Prof, [string]$Phase, $StepIds) {
    $ids = @($StepIds | Where-Object { $_ })
    , @($Prof['steps'] | Where-Object {
            (-not $Phase -or [string]$_['phase'] -eq $Phase) -and
            ($ids.Count -eq 0 -or $ids -contains [string]$_['id'])
        })
}

function Invoke-PhxRunSteps([string]$Mode, $Steps, $Ctx) {
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    $total = @($Steps).Count
    foreach ($s in $Steps) {
        $i++
        $sid = [string]$s['id']
        if ($total -gt 0) { Write-PhxProgress -Step $sid -Pct ([int](100 * ($i - 1) / $total)) -Msg ([string]$s['title']) }
        if (-not $s['enabled']) {
            $why = if ($s['_error']) { $s['_error'] } elseif ($s['risk'] -eq 'danger') { 'disabled (danger: enable it explicitly)' } else { 'disabled' }
            Write-PhxStep -Step $sid -Status skip -Msg $why
            $results.Add([ordered]@{ id = $sid; kind = $s['kind']; phase = $s['phase']; status = 'skip'; changes = 0; skipped = 0; failed = 0; msg = $why })
            continue
        }
        $Ctx.Stats = @{ changes = 0; skipped = 0; failed = 0 }
        Write-PhxStep -Step $sid -Status start -Msg ([string]$s['title'])
        $status = 'ok'; $msg = ''
        try {
            Invoke-PhxStepHandler -Step $s -Ctx $Ctx
            if ($Ctx.Stats.failed -gt 0) { $status = 'fail'; $msg = "$($Ctx.Stats.failed) item(s) failed" }
        } catch {
            $status = 'fail'; $msg = $_.Exception.Message
            Write-PhxLog -Level error -Msg "Step $sid failed: $msg"
        } finally {
            Dismount-PhxAllHives
            Save-PhxSnapshot
        }
        Write-PhxStep -Step $sid -Status $status -Msg $msg
        $results.Add([ordered]@{
                id = $sid; kind = $s['kind']; phase = $s['phase']; status = $status
                changes = $Ctx.Stats.changes; skipped = $Ctx.Stats.skipped; failed = $Ctx.Stats.failed; msg = $msg
            })
    }
    if ($total -gt 0) { Write-PhxProgress -Pct 100 -Msg 'done' }
    , @($results.ToArray())
}

function Get-PhxTotals($Results) {
    $t = [ordered]@{ steps = @($Results).Count; ok = 0; fail = 0; skip = 0; changes = 0; skipped = 0; failed = 0 }
    foreach ($r in $Results) {
        $t[[string]$r['status']]++
        $t.changes += [int]$r['changes']; $t.skipped += [int]$r['skipped']; $t.failed += [int]$r['failed']
    }
    $t
}

function Invoke-PhxPlan([hashtable]$A) {
    $cfg = Get-PhxConfig $A['configPath']
    $prof = Get-PhxResolvedProfile -Config $cfg -PacksRoot $A['packsRoot']
    $phase = [string]$A['phase']
    $steps = Select-PhxSteps $prof $phase $A['steps']
    $ctx = New-PhxCtx 'plan' $cfg
    if (-not $ctx.IsAdmin) { Write-PhxLog -Level warn -Msg 'Planning without admin: some current values (features, capabilities, provisioned apps, BitLocker, other users'' hives) cannot be read and are reported as unknown.' }
    $results = Invoke-PhxRunSteps 'plan' $steps $ctx
    [ordered]@{ mode = 'plan'; phase = $phase; isAdmin = $ctx.IsAdmin; steps = $results; totals = (Get-PhxTotals $results) }
}

function Invoke-PhxApply([hashtable]$A) {
    Assert-PhxAdmin 'apply'
    $phase = [string]$A['phase']
    if (-not $phase) { throw "apply: 'phase' is required." }
    $cfg = Get-PhxConfig $A['configPath']
    $prof = Get-PhxResolvedProfile -Config $cfg -PacksRoot $A['packsRoot']
    $steps = Select-PhxSteps $prof $phase $A['steps']
    $unattended = [bool]$A['unattended']

    if (-not $script:PhxLogPath) {
        Set-PhxLogPath (Join-Path (Get-PhxDataRoot) ("logs\{0}-apply-{1}.ndjson" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $phase))
    }
    $snap = New-PhxSnapshot -Phase $phase -StepIds @($steps | ForEach-Object { [string]$_['id'] })
    Write-PhxLog -Msg "Snapshot $($snap.id) at $($snap.dir)"
    Set-PhxPhaseStatus -Phase $phase -Status 'running' -Snapshot $snap.id

    $ctx = New-PhxCtx 'apply' $cfg
    $results = @()
    try {
        $results = Invoke-PhxRunSteps 'apply' $steps $ctx
    } finally {
        Close-PhxSnapshot
    }
    $totals = Get-PhxTotals $results
    $phaseStatus = if ($totals.fail -gt 0) { 'failed' } else { 'ok' }
    Set-PhxPhaseStatus -Phase $phase -Status $phaseStatus -Snapshot $snap.id -Summary $totals

    # Mark the runbook stage(s) bound to this phase.
    try {
        foreach ($stage in (Get-PhxRunbookStages)) {
            if ([string]$stage['phase'] -eq $phase) { Set-PhxStageStatus -Stage ([string]$stage['id']) -Status $(if ($phaseStatus -eq 'ok') { 'done' } else { 'failed' }) -Note "snapshot $($snap.id)" }
        }
    } catch { }

    $data = [ordered]@{ mode = 'apply'; phase = $phase; snapshotId = $snap.id; steps = $results; totals = $totals; poweringOff = $false }

    # Only the unattended admin phase (run by FirstLogon) powers the machine off.
    if ($unattended -and $phase -eq 'admin') {
        $data.poweringOff = $true
        Write-PhxLog -Msg 'Unattended admin phase finished: powering off in 15 seconds.'
        Write-PhxResult -Ok $true -Data $data
        Start-Sleep -Seconds 15
        Stop-Computer -Force
        exit 0
    }
    $data
}
