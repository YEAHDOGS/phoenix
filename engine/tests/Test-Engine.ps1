<#
.SYNOPSIS
    Read-only self-test for the Phoenix engine. Safe on any machine.

.DESCRIPTION
    Runs only read-only commands (version, packs, profile, plan, scan, drives,
    state, runbook, snapshots, choco-search, launch error path) through
    engine\phoenix.ps1 in a child process of the same PowerShell edition,
    parses the NDJSON, and asserts the event contract. State/logs go to a temp
    dir via PHOENIX_DATA_ROOT, so nothing under C:\ProgramData is touched.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File engine\tests\Test-Engine.ps1 [-Online]
    pwsh -NoProfile -File engine\tests\Test-Engine.ps1

    -Online also queries the Chocolatey community feed.
#>
[CmdletBinding()]
param([switch]$Online)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$engine = Join-Path (Split-Path -Parent $here) 'phoenix.ps1'
$fixtures = Join-Path $here 'fixtures'
$exe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('phx-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:PHOENIX_DATA_ROOT = Join-Path $tmp 'data'

$script:pass = 0; $script:fail = 0
function Check([bool]$Cond, [string]$What) {
    if ($Cond) { $script:pass++; Write-Host "  ok   $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $What" -ForegroundColor Red }
}

function Invoke-Phx([string]$Command, $ArgsObj = $null) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, $Command)
    if ($null -ne $ArgsObj) {
        $ap = Join-Path $tmp ("args-$Command-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        [IO.File]::WriteAllText($ap, (ConvertTo-Json -InputObject $ArgsObj -Depth 8), [Text.UTF8Encoding]::new($false))
        $argv += @('-ArgsPath', $ap)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lines = & $exe @argv 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    $events = New-Object System.Collections.Generic.List[object]
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($lines)) {
        $s = [string]$l
        if (-not $s.Trim()) { continue }
        try { $events.Add(($s | ConvertFrom-Json)) } catch { $bad.Add($s) }
    }
    $results = @($events | Where-Object { $_.t -eq 'result' })
    [pscustomobject]@{
        command = $Command; exit = $code; events = @($events.ToArray()); bad = @($bad.ToArray())
        result = $(if ($results.Count -gt 0) { $results[-1] } else { $null }); resultCount = $results.Count; ms = $sw.ElapsedMilliseconds
    }
}

function Assert-Contract($R, [bool]$ExpectOk = $true) {
    Check ($R.bad.Count -eq 0) "$($R.command): every stdout line is JSON ($($R.bad.Count) bad$(if ($R.bad.Count) { ': ' + $R.bad[0] }))"
    Check ($R.resultCount -eq 1) "$($R.command): exactly one result event (got $($R.resultCount))"
    $allTyped = -not ($R.events | Where-Object { -not $_.t -or -not $_.ts -or ('log', 'step', 'change', 'progress', 'result' -notcontains $_.t) })
    Check $allTyped "$($R.command): every event has a known t and a ts"
    if ($R.result) {
        $why = if (-not $R.result.ok -and $R.result.data) { ' - ' + $R.result.data.error } else { '' }
        Check ([bool]$R.result.ok -eq $ExpectOk) "$($R.command): ok=$ExpectOk, exit $($R.exit) ($($R.ms) ms)$why"
    }
}

Write-Host "Phoenix engine self-test on PowerShell $($PSVersionTable.PSVersion) ($exe)" -ForegroundColor Cyan
Write-Host "Data root: $env:PHOENIX_DATA_ROOT"
$cfgArgs = @{ configPath = (Join-Path $fixtures 'config.json'); packsRoot = (Join-Path $fixtures 'packs') }

# version
$r = Invoke-Phx 'version'
Assert-Contract $r
Check ($r.result.data.commands -contains 'plan') 'version: lists commands'
Check ($r.exit -eq 0) 'version: exit 0'

# unknown command
$r = Invoke-Phx 'no-such-command'
Assert-Contract $r $false
Check ($r.exit -eq 1) 'unknown command: exit 1'

# packs
$r = Invoke-Phx 'packs' @{ packsRoot = $cfgArgs.packsRoot }
Assert-Contract $r
Check (@($r.result.data).Count -eq 2) 'packs: finds both fixture packs'

# profile
$r = Invoke-Phx 'profile' $cfgArgs
Assert-Contract $r
$prof = $r.result.data
$steps = @{}
foreach ($s in @($prof.steps)) { $steps[$s.id] = $s }
Check (@($prof.packs | Where-Object { $_.id -eq 't-missing' -and -not $_.found }).Count -eq 1) 'profile: missing pack reported, not fatal'
Check ([bool]($r.events | Where-Object { $_.t -eq 'log' -and $_.level -eq 'warn' -and $_.msg -like '*t-missing*' })) 'profile: warning event for missing pack'
$svc = $steps['t.services']
Check ($svc.title -eq 'Services (merged)') 'profile: later pack replaces scalar fields'
Check (@($svc._sources) -join ',' -eq 't-base,t-override') 'profile: step records its source packs'
$ssdp = @($svc.items | Where-Object { $_._key -eq 'SSDPSRV' })[0]
Check ($ssdp -and $ssdp.enabled -eq $false -and $ssdp.startup -eq 'Disabled') 'profile: item merge keeps fields, enabled:false disables'
Check ([bool](@($svc.items | Where-Object { $_._key -eq 'WSearch' }))) 'profile: new item appended'
$diag = @($svc.items | Where-Object { $_._key -eq 'DiagTrack' })[0]
Check ($diag.stop -eq $true) 'profile: config item override merged'
Check ($steps['t.tasks'].title -eq 'Tasks (overridden)') 'profile: config step override applied'
Check ($steps['t.danger'].enabled -eq $false) 'profile: danger step disabled by default'
$hide = @($steps['t.extra'].items)[0]
Check ($hide.enabled -eq $false) 'profile: danger item disabled by default'
Check ($steps['t.bogus'].enabled -eq $false -and $steps['t.bogus']._error) 'profile: unknown kind disabled with error'
$devKey = @($steps['t.devices'].items)[0]._key
Check ($devKey -eq '{"friendlyName":"WAN Miniport*"}') "profile: device default key is stable JSON ($devKey)"

# plan (all phases) - read-only
$r = Invoke-Phx 'plan' $cfgArgs
Assert-Contract $r
$plan = $r.result.data
Check ($plan.mode -eq 'plan') 'plan: mode plan'
$changes = @($r.events | Where-Object { $_.t -eq 'change' })
Check ($changes.Count -gt 0) "plan: emitted $($changes.Count) change events"
Check (-not ($changes | Where-Object { $_.applied -eq $true })) 'plan: nothing applied'
Check (-not ($changes | Where-Object { -not $_.step -or -not $_.key -or -not $_.action })) 'plan: change events carry step/key/action'
$stepEv = @($r.events | Where-Object { $_.t -eq 'step' })
Check (@($stepEv | Where-Object { $_.status -eq 'start' }).Count -ge 10) 'plan: step start events'
$byStep = @{}
foreach ($s in @($plan.steps)) { $byStep[$s.id] = $s }
Check ($byStep['t.danger'].status -eq 'skip') 'plan: danger step skipped'
Check ($byStep['t.bogus'].status -eq 'skip') 'plan: unknown-kind step skipped'
Check ([bool]($changes | Where-Object { $_.step -eq 't.services' -and $_.key -eq 'RpcSs' -and $_.action -eq 'skip' -and $_.msg -like 'PROTECTED*' })) 'plan: protected service refused'
Check ([bool]($changes | Where-Object { $_.step -eq 't.services' -and $_.key -eq 'NoSuchServicePhx' -and $_.action -eq 'skip' })) 'plan: missing service is a skip, not an error'
Check (-not ($changes | Where-Object { $_.step -eq 't.services' -and $_.key -eq 'SSDPSRV' })) 'plan: disabled item not planned'
Check ([bool]($changes | Where-Object { $_.step -eq 't.devices' -and $_.msg -like 'PROTECTED*' })) 'plan: protected devices refused'
Check (-not ($changes | Where-Object { $_.step -eq 't.devices' -and $_.action -ne 'skip' -and $_.key -like 'Programmable interrupt controller*' })) 'plan: PIC never targeted'
Check ([bool]($changes | Where-Object { $_.step -eq 't.appx' -and $_.key -eq 'Microsoft.SecHealthUI' -and $_.msg -like 'PROTECTED*' }) -or -not ($changes | Where-Object { $_.step -eq 't.appx' -and $_.key -eq 'Microsoft.SecHealthUI' -and $_.action -ne 'skip' })) 'plan: Defender UI appx protected'
Check (-not ($changes | Where-Object { $_.step -eq 't.appx' -and $_.key -eq 'Microsoft.WindowsStore' -and $_.action -ne 'skip' })) 'plan: kept appx not removed'
Check ([bool]($changes | Where-Object { $_.step -eq 't.manual' })) 'plan: manual step reported'
Check ([bool]($changes | Where-Object { $_.step -eq 't.choco' -and $_.key -eq 'app:git' })) 'plan: choco apps from config planned'
Check ([bool]($changes | Where-Object { $_.step -eq 't.features' })) 'plan: features evaluated'
Check ([bool]($changes | Where-Object { $_.step -eq 't.settings' -and $_.key -eq 'pagefile' })) 'plan: pagefile setting evaluated'
Check ([bool]($changes | Where-Object { $_.step -eq 't.firewall' })) 'plan: firewall evaluated'
Check ($plan.totals.steps -eq @($plan.steps).Count) 'plan: totals add up'
foreach ($s in @($plan.steps)) { if ($s.status -eq 'fail') { Write-Host "    note: $($s.id) reported fail in plan: $($s.msg)" -ForegroundColor Yellow } }

# plan one phase
$a2 = @{ configPath = $cfgArgs.configPath; packsRoot = $cfgArgs.packsRoot; phase = 'user-online' }
$r = Invoke-Phx 'plan' $a2
Assert-Contract $r
Check (-not (@($r.result.data.steps) | Where-Object { $_.phase -ne 'user-online' })) 'plan -phase: only that phase'

# real packs + example config (whatever is in packs/ and config/)
$repo = Split-Path -Parent (Split-Path -Parent $here)
$example = Join-Path $repo 'config\phoenix.example.json'
if (Test-Path $example) {
    $r = Invoke-Phx 'packs'
    Assert-Contract $r
    Check (@($r.result.data).Count -ge 1) "real packs: $(@($r.result.data).Count) found ($((@($r.result.data) | ForEach-Object { $_.id }) -join ', '))"
    $r = Invoke-Phx 'profile' @{ configPath = $example }
    Assert-Contract $r
    Check (-not (@($r.result.data.packs) | Where-Object { -not $_.found })) 'real profile: every configured pack exists'
    Check (-not ($r.events | Where-Object { $_.t -eq 'log' -and $_.level -ne 'info' })) 'real profile: no warnings'
    $r = Invoke-Phx 'plan' @{ configPath = $example }
    Assert-Contract $r
    $failedSteps = @($r.result.data.steps | Where-Object { $_.status -eq 'fail' })
    Check ($failedSteps.Count -eq 0) "real plan: no failing steps$(if ($failedSteps) { ' (' + (($failedSteps | ForEach-Object { $_.id + ': ' + $_.msg }) -join '; ') + ')' })"
    Check (-not ($r.events | Where-Object { $_.t -eq 'change' -and $_.applied })) 'real plan: nothing applied'
    $userKeys = @($r.events | Where-Object { $_.t -eq 'change' -and $_.key -like '*interactive user*' })
    Check ($userKeys.Count -gt 0) "real plan: user-scoped items target the interactive user ($(if ($userKeys) { ($userKeys[0].key -replace '^.*\[interactive user ', '' -replace '\].*$', '') }))"
    Write-Host "    real plan totals: $($r.result.data.totals | ConvertTo-Json -Compress)"
} else {
    Write-Host '  (no config/phoenix.example.json: skipping real-pack checks)' -ForegroundColor Yellow
}

# apply refuses without admin
$isAdmin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $r = Invoke-Phx 'apply' @{ configPath = $cfgArgs.configPath; packsRoot = $cfgArgs.packsRoot; phase = 'admin' }
    Assert-Contract $r $false
    Check ($r.exit -eq 2 -and $r.result.data.needsAdmin) 'apply: non-admin gets exit 2 / needsAdmin'
    $r = Invoke-Phx 'undo' @{ snapshotId = 'x' }
    Check ($r.exit -eq 2) 'undo: non-admin gets exit 2'
} else {
    Write-Host '  (elevated: skipping the non-admin apply refusal checks; apply is never run by this test)' -ForegroundColor Yellow
}

# scan
$r = Invoke-Phx 'scan'
Assert-Contract $r
$scan = $r.result.data
Check ([bool]$scan.manufacturer -and [bool]$scan.model) "scan: $($scan.manufacturer) $($scan.model)"
Check (@($scan.devices).Count -gt 10) "scan: $(@($scan.devices).Count) devices ($($scan.hidden) not present)"
Check (@($scan.services).Count -gt 50) "scan: $(@($scan.services).Count) services"
Check ($null -ne $scan.counts) 'scan: counts block'

# drives
$r = Invoke-Phx 'drives'
Assert-Contract $r
Check (-not (@($r.result.data) | Where-Object { $_.isSystem })) "drives: $(@($r.result.data).Count) removable, none is the system disk"

# state / mark / runbook / snapshots (temp data root)
$r = Invoke-Phx 'state'
Assert-Contract $r
Check ($r.result.data.path -like "$env:PHOENIX_DATA_ROOT*") 'state: uses PHOENIX_DATA_ROOT'
$r = Invoke-Phx 'mark' @{ stage = 'test-stage'; status = 'done' }
Assert-Contract $r
Check ($r.result.data.stages.'test-stage'.status -eq 'done') 'mark: stage recorded'
$r = Invoke-Phx 'mark' @{ stage = 'x'; status = 'bogus' }
Assert-Contract $r $false
$r = Invoke-Phx 'runbook'
$rbExists = Test-Path (Join-Path (Split-Path -Parent $here) 'runbook.json')
Assert-Contract $r $rbExists
$r = Invoke-Phx 'snapshots'
Assert-Contract $r

# launch error path
$r = Invoke-Phx 'launch' @{ loadout = 'no-such-tool-phx' }
Assert-Contract $r $false

# choco-search (offline catalog always; online only with -Online)
$r = Invoke-Phx 'choco-search' @{ query = 'git'; offline = $true }
Assert-Contract $r
Write-Host "    offline catalog hits for 'git': $(@($r.result.data).Count)"
if ($Online) {
    $r = Invoke-Phx 'choco-search' @{ query = 'firefox' }
    Assert-Contract $r
    $hits = @($r.result.data)
    Check ($hits.Count -gt 0 -and $hits[0].source -eq 'online') "choco-search online: $($hits.Count) hits, first $($hits[0].id) $($hits[0].version)"
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:fail) { 'Red' } else { 'Green' }
Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor $color
exit $(if ($script:fail) { 1 } else { 0 })
