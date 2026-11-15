<#
.SYNOPSIS
    Phoenix engine CLI. The only entry point the Phoenix app spawns.

.DESCRIPTION
    phoenix.ps1 <command> [-ArgsPath <json>] [-LogPath <file>]

    Writes NDJSON events to stdout (and to -LogPath when given). Exactly one
    "result" event ends every command. Exit codes: 0 ok, 1 failure, 2 needs
    admin. See docs/ARCHITECTURE.md for commands, args and the event schema.

    Runs on Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'version',
    [string]$ArgsPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

$PhxEngineRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$PhxRepoRoot = Split-Path -Parent $PhxEngineRoot
$PhxEngineVersion = '2.0.0'

# Every module in lib/ is a set of function definitions; order does not matter
# except Events.ps1, which the others use at call time.
. (Join-Path $PhxEngineRoot 'lib\Events.ps1')
Get-ChildItem -Path (Join-Path $PhxEngineRoot 'lib') -Filter '*.ps1' |
    Where-Object { $_.Name -ne 'Events.ps1' } |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

Set-PhxLogPath $LogPath

function Read-PhxArgs {
    if (-not $ArgsPath) { return @{} }
    if (-not (Test-Path -LiteralPath $ArgsPath)) { throw "ArgsPath not found: $ArgsPath" }
    $obj = Get-Content -LiteralPath $ArgsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    ConvertTo-PhxHashtable $obj
}

# PowerShell 5.1 has no ConvertFrom-Json -AsHashtable.
function ConvertTo-PhxHashtable($InputObject) {
    if ($null -eq $InputObject) { return $null }
    # PS 5.1 wraps JSON strings/numbers in PSObject, which also matches [pscustomobject].
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    # It also wraps a top-level JSON array; unwrap so arrays aren't mistaken for objects.
    $base = $InputObject.PSObject.BaseObject
    if ($base -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $base.Keys) { $h[$k] = ConvertTo-PhxHashtable $base[$k] }
        return $h
    }
    if ($base -is [System.Collections.IEnumerable] -and $base -isnot [string]) {
        return , @($base | ForEach-Object { ConvertTo-PhxHashtable $_ })
    }
    if ($base -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PhxHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-PhxHashtable $_ })
    }
    return $InputObject
}

function Test-PhxIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Command name -> function. Each function takes one [hashtable] of args and
# returns the result data (or throws). Long-running ones emit events as they go.
$PhxCommands = [ordered]@{
    'version'      = 'Invoke-PhxVersion'
    'profile'      = 'Invoke-PhxProfile'
    'packs'        = 'Invoke-PhxPacks'
    'plan'         = 'Invoke-PhxPlan'
    'apply'        = 'Invoke-PhxApply'
    'undo'         = 'Invoke-PhxUndo'
    'snapshots'    = 'Invoke-PhxSnapshots'
    'scan'         = 'Invoke-PhxScan'
    'state'        = 'Invoke-PhxState'
    'mark'         = 'Invoke-PhxMark'
    'runbook'      = 'Invoke-PhxRunbook'
    'drives'       = 'Invoke-PhxDrives'
    'unattend'     = 'Invoke-PhxUnattend'
    'unattend-schema'   = 'Invoke-PhxUnattendSchema'
    'unattend-defaults' = 'Invoke-PhxUnattendDefaults'
    'loadout'      = 'Invoke-PhxLoadout'
    'fetch'        = 'Invoke-PhxFetch'
    'usb-build'    = 'Invoke-PhxUsbBuild'
    'usb-verify'   = 'Invoke-PhxUsbVerify'
    'choco-search' = 'Invoke-PhxChocoSearch'
    'launch'       = 'Invoke-PhxLaunch'
}

function Invoke-PhxVersion([hashtable]$A) {
    [ordered]@{
        engineVersion = $PhxEngineVersion
        psVersion     = $PSVersionTable.PSVersion.ToString()
        isAdmin       = (Test-PhxIsAdmin)
        os            = $(try { (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version } catch { [Environment]::OSVersion.VersionString })
        kitRoot       = $PhxRepoRoot
        commands      = @($PhxCommands.Keys)
    }
}

$exit = 0
try {
    if (-not $PhxCommands.Contains($Command)) {
        throw "Unknown command '$Command'. Known: $($PhxCommands.Keys -join ', ')"
    }
    $fn = $PhxCommands[$Command]
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "Command '$Command' is not implemented yet ($fn)." }
    $a = Read-PhxArgs
    $data = & $fn $a
    Write-PhxResult -Ok $true -Data $data
} catch {
    $msg = $_.Exception.Message
    $needsAdmin = $msg -like 'NEEDS_ADMIN*'
    Write-PhxLog -Level error -Msg $msg
    Write-PhxResult -Ok $false -Data @{ error = $msg; needsAdmin = $needsAdmin; at = "$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" }
    $exit = if ($needsAdmin) { 2 } else { 1 }
}
exit $exit
