# Phoenix engine: NDJSON event output. See docs/ARCHITECTURE.md "Event schema".
# Every engine function reports through these; nothing else writes to stdout.

$script:PhxLogPath = $null

function Set-PhxLogPath([string]$Path) {
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    $script:PhxLogPath = $Path
}

function Write-PhxEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('log', 'step', 'change', 'progress', 'result')][string]$Type,
        [hashtable]$Fields = @{}
    )
    $evt = [ordered]@{ t = $Type; ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    foreach ($k in $Fields.Keys) { $evt[$k] = $Fields[$k] }
    $line = ConvertTo-Json -InputObject $evt -Compress -Depth 12
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    if ($script:PhxLogPath) {
        try { [IO.File]::AppendAllText($script:PhxLogPath, $line + "`n", [Text.UTF8Encoding]::new($false)) } catch { }
    }
}

function Write-PhxLog {
    param([Parameter(Mandatory)][string]$Msg, [ValidateSet('info', 'warn', 'error')][string]$Level = 'info')
    Write-PhxEvent -Type log -Fields @{ level = $Level; msg = $Msg }
}

function Write-PhxStep {
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][ValidateSet('start', 'ok', 'skip', 'fail')][string]$Status, [string]$Msg = '')
    Write-PhxEvent -Type step -Fields @{ step = $Step; status = $Status; msg = $Msg }
}

function Write-PhxChange {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Key,
        $Current,
        $Target,
        [ValidateSet('set', 'remove', 'disable', 'enable', 'add', 'skip')][string]$Action = 'set',
        [bool]$Applied = $false,
        [string]$Msg = ''
    )
    Write-PhxEvent -Type change -Fields @{
        step = $Step; key = $Key; current = $Current; target = $Target
        action = $Action; applied = $Applied; msg = $Msg
    }
}

function Write-PhxProgress {
    param([string]$Step = '', [int]$Pct, [string]$Msg = '')
    Write-PhxEvent -Type progress -Fields @{ step = $Step; pct = $Pct; msg = $Msg }
}

function Write-PhxResult {
    param([bool]$Ok = $true, $Data = $null)
    Write-PhxEvent -Type result -Fields @{ ok = $Ok; data = $Data }
}
