# ==============================================================================
# phoenix-import.ps1 -- use phoenix scripts from any other project without copying them
# ==============================================================================
# Dot-source this file, then call Import-PhoenixScript / Invoke-PhoenixScript.
# It fetches the YEAHDOGS/phoenix repo (sparse, blob-less, pinned to a ref) into a
# local cache and hands back the path of the script you asked for. Works on Windows
# and Linux with git + pwsh 7.
#
#   . "$PSScriptRoot/phoenix-import.ps1"          # or the raw-URL bootstrap below
#   $p = Import-PhoenixScript 'scripts/emulationstation/update-card.ps1'
#   & $p -Drive F
#   # or in one line:
#   Invoke-PhoenixScript 'scripts/emulationstation/update-card.ps1' -Args @('-Drive','F')
#
# Bootstrap without having phoenix on disk at all (castle, a fresh Linux box, ...):
#   iex (irm https://raw.githubusercontent.com/YEAHDOGS/phoenix/master/scripts/tools/phoenix-import.ps1)
#
# Pin to a tag or commit for reproducible/verified runs:  -Ref 'v1.2.0'  or  -Ref '0df3304'
# Require signed commits:                                  -VerifySignature  (uses `git verify-commit`)
# ==============================================================================

function Get-PhoenixCacheRoot {
    if ($env:PHOENIX_CACHE) { return $env:PHOENIX_CACHE }
    if ($IsLinux -or $IsMacOS) { return (Join-Path $HOME '.cache/phoenix') }
    return (Join-Path $env:LOCALAPPDATA 'phoenix')
}

function Sync-PhoenixRepo {
    <#
    .SYNOPSIS  Sparse-clone (or update) the phoenix repo at a given ref, only the paths requested.
    .OUTPUTS   Path of the checked-out working tree.
    #>
    param(
        [string]$Repo = 'https://github.com/YEAHDOGS/phoenix.git',
        [string]$Ref = 'master',
        [string[]]$Paths = @('scripts'),
        [switch]$VerifySignature,
        [switch]$Offline
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required' }
    $root = Get-PhoenixCacheRoot
    $tree = Join-Path $root 'repo'
    if (-not (Test-Path (Join-Path $tree '.git'))) {
        if ($Offline) { throw "phoenix cache missing at $tree and -Offline was given" }
        New-Item -ItemType Directory -Force $root | Out-Null
        git clone --quiet --filter=blob:none --no-checkout $Repo $tree
        if ($LASTEXITCODE) { throw 'git clone failed' }
        git -C $tree sparse-checkout init --cone | Out-Null
    }
    git -C $tree sparse-checkout set @Paths | Out-Null
    if (-not $Offline) {
        git -C $tree fetch --quiet origin $Ref
        if ($LASTEXITCODE) { throw "git fetch of ref '$Ref' failed" }
        if ($VerifySignature) {
            git -C $tree verify-commit FETCH_HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE) { throw "commit $Ref is not signed by a trusted key; refusing to run it" }
        }
        git -C $tree checkout --quiet --detach FETCH_HEAD
        if ($LASTEXITCODE) { throw 'git checkout failed' }
    }
    $script:PhoenixCommit = (git -C $tree rev-parse --short HEAD)
    return $tree
}

function Import-PhoenixScript {
    <#
    .SYNOPSIS  Return the local path of a phoenix script (e.g. 'scripts/emulationstation/update-card.ps1'),
               fetching/updating the repo first. Sibling files in the same folder come along.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [string]$Ref = 'master',
        [switch]$VerifySignature,
        [switch]$Offline
    )
    $folder = Split-Path $Script -Parent
    $tree = Sync-PhoenixRepo -Ref $Ref -Paths @($folder) -VerifySignature:$VerifySignature -Offline:$Offline
    $path = Join-Path $tree $Script
    if (-not (Test-Path $path)) { throw "phoenix@$($script:PhoenixCommit) has no file '$Script'" }
    Write-Verbose "phoenix@$($script:PhoenixCommit): $path"
    return $path
}

function Invoke-PhoenixScript {
    <#
    .SYNOPSIS  Fetch and run a phoenix script in one call, passing arguments through.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [object[]]$Args = @(),
        [string]$Ref = 'master',
        [switch]$VerifySignature,
        [switch]$Offline
    )
    $path = Import-PhoenixScript -Script $Script -Ref $Ref -VerifySignature:$VerifySignature -Offline:$Offline
    Write-Host "[phoenix@$($script:PhoenixCommit)] $Script $($Args -join ' ')" -ForegroundColor DarkGray
    & $path @Args
}
