# Phoenix engine: the first-boot script.
#
# Commands: setup-script, harden-options. See docs/FIRST-BOOT.md.
#
# One self-contained PowerShell 5.1 script that installs Chocolatey and the
# chosen apps, and optionally runs a pinned third-party hardening script. It
# runs three ways: by hand on any PC, from the answer file at first logon
# (config.firstBoot.enabled), or from a test VM. It needs nothing from the
# Phoenix kit, and it records what it did in C:\ProgramData\Phoenix\firstboot.json.

$script:PhxFirstBootMarker = '# phoenix-firstboot v1'

function Get-PhxSourcesRoot { Join-Path (Get-PhxKitRoot) 'config\sources' }

function Get-PhxHardenSource {
    $p = Join-Path (Get-PhxSourcesRoot) 'sos-harden.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "Hardening source not found: $p" }
    $s = Read-PhxJson $p
    if (([string]$s['commit']) -notmatch '^[0-9a-f]{40}$') { throw 'sos-harden.json: commit must be a full 40-character commit id.' }
    if (([string]$s['zipSha256']) -notmatch '^[0-9a-f]{64}$') { throw 'sos-harden.json: zipSha256 must be a SHA-256.' }
    if (([string]$s['repo']) -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw 'sos-harden.json: repo must be owner/name.' }
    if (([string]$s['script']) -notmatch '^[A-Za-z0-9._-]+\.ps1$') { throw 'sos-harden.json: script must be a .ps1 file name.' }
    foreach ($o in @($s['options'])) {
        if (([string]$o['name']) -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "sos-harden.json: option name '$($o['name'])' is not a parameter name." }
    }
    $s
}

function Invoke-PhxHardenOptions([hashtable]$A) {
    $s = Get-PhxHardenSource
    [ordered]@{
        id = $s['id']; name = $s['name']; description = $s['description']; homepage = $s['homepage']; license = $s['license']
        repo = $s['repo']; commit = $s['commit']
        options = @($s['options'] | ForEach-Object {
                [ordered]@{ name = $_['name']; group = $_['group']; label = $_['label']; why = $_['why']; default = [bool]$_['default']; risk = $(if ($_['risk']) { $_['risk'] } else { 'safe' }) }
            })
    }
}

# A Chocolatey package id, as the community feed allows them.
function Test-PhxChocoId([string]$Id) { $Id -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' }

function ConvertTo-PhxPsLiteral([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

# The hardening choices as a full, explicit set: every option the source lists
# is passed, true or false, so the script's own "everything on" defaults never apply.
function Resolve-PhxHardenChoices($Harden) {
    if (-not ($Harden -is [System.Collections.IDictionary]) -or -not $Harden['enabled']) { return $null }
    $s = Get-PhxHardenSource
    $picked = $Harden['options']
    $out = [ordered]@{}
    foreach ($o in @($s['options'])) {
        $name = [string]$o['name']
        $val = [bool]$o['default']
        if ($picked -is [System.Collections.IDictionary]) {
            foreach ($k in @($picked.Keys)) { if ($k -ieq $name) { $val = [bool]$picked[$k] } }
        }
        $out[$name] = $val
    }
    if (@($out.Values | Where-Object { $_ }).Count -eq 0) { return $null }
    @{ source = $s; choices = $out }
}

function New-PhxFirstBootScript([string[]]$Apps, $Harden, [int]$WaitMinutes = 10, [string]$ReportUrl = '') {
    if ($ReportUrl -and $ReportUrl -notmatch '^https?://[A-Za-z0-9.\-:\[\]]+(/[A-Za-z0-9._~/\-?=&%]*)?$') { throw "reportUrl '$ReportUrl' is not a plain http or https address." }
    foreach ($a in $Apps) { if (-not (Test-PhxChocoId $a)) { throw "'$a' is not a Chocolatey package id." } }
    $appList = if ($Apps.Count -gt 0) { '@(' + ((@($Apps | ForEach-Object { ConvertTo-PhxPsLiteral $_ })) -join ', ') + ')' } else { '@()' }
    $h = Resolve-PhxHardenChoices $Harden
    $hardenBlock = "`$harden = `$null"
    if ($h) {
        $pairs = @($h.choices.Keys | ForEach-Object { "    $_ = `$$(([string]$h.choices[$_]).ToLower())" }) -join "`r`n"
        $hardenBlock = @"
`$harden = @{
  Repo = $(ConvertTo-PhxPsLiteral ([string]$h.source['repo']))
  Commit = $(ConvertTo-PhxPsLiteral ([string]$h.source['commit']))
  ZipSha256 = $(ConvertTo-PhxPsLiteral ([string]$h.source['zipSha256']))
  Script = $(ConvertTo-PhxPsLiteral ([string]$h.source['script']))
  Options = [ordered]@{
$pairs
  }
}
"@
    }
    $head = @"
$($script:PhxFirstBootMarker)
# Made by Phoenix on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC.
# Installs Chocolatey, then each app below at its latest version$(if ($h) { ', then runs the pinned hardening script' }).
# Run it elevated. It can be run again: apps already installed are left alone.
# What it did: C:\ProgramData\Phoenix\firstboot.json  Log: C:\ProgramData\Phoenix\logs\firstboot-setup.log
`$apps = $appList
`$waitMinutes = $WaitMinutes
`$reportUrl = $(if ($ReportUrl) { ConvertTo-PhxPsLiteral $ReportUrl } else { '$null' })
$hardenBlock
"@
    # The body is literal: nothing below is filled in by Phoenix.
    $body = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'Phoenix'
$logs = Join-Path $data 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$log = Join-Path $logs 'firstboot-setup.log'
$statePath = Join-Path $data 'firstboot.json'
function Write-SetupLog([string]$m) {
  $line = '{0:s} {1}' -f (Get-Date), $m
  Add-Content -LiteralPath $log -Value $line
  Write-Host $line
}
$state = [ordered]@{ started = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; finished = $null; ok = $false; network = $false; chocolatey = $null; apps = @(); harden = $null; error = $null }
function Save-SetupState {
  $json = ConvertTo-Json -InputObject $state -Depth 6
  [IO.File]::WriteAllText($statePath, $json, (New-Object Text.UTF8Encoding $false))
  if (-not $reportUrl) { return }
  # Tell whoever asked how it is going. Never holds the setup up for long.
  try {
    $body = [Text.Encoding]::UTF8.GetBytes($json)
    $req = [Net.WebRequest]::Create($reportUrl)
    $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 5000; $req.ContentLength = $body.Length
    $stream = $req.GetRequestStream(); $stream.Write($body, 0, $body.Length); $stream.Close()
    $req.GetResponse().Close()
  } catch { }
}
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  if ($PSCommandPath) {
    Write-Host 'Asking for administrator rights...'
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    return
  }
  $state.error = 'Not run as administrator.'; Save-SetupState
  Write-SetupLog 'This script has to run as administrator. Nothing was done.'
  return
}
Save-SetupState
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
  $deadline = (Get-Date).AddMinutes($waitMinutes)
  while ($true) {
    try {
      $tcp = New-Object Net.Sockets.TcpClient
      $tcp.Connect('community.chocolatey.org', 443)
      $tcp.Close()
      $state.network = $true
      break
    } catch {
      if ((Get-Date) -gt $deadline) { break }
      Write-SetupLog 'Waiting for the internet...'
      Start-Sleep -Seconds 10
    }
  }
  if (-not $state.network) { throw "No internet after $waitMinutes minutes. Connect, then run this script again." }

  $choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
  if (-not (Test-Path -LiteralPath $choco)) {
    Write-SetupLog 'Installing Chocolatey.'
    $installer = (New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
    Invoke-Expression $installer *>&1 | ForEach-Object { Add-Content -LiteralPath $log -Value ([string]$_) }
  }
  if (-not (Test-Path -LiteralPath $choco)) { throw 'Chocolatey did not install. See the log.' }
  $state.chocolatey = ((& $choco --version) | Select-Object -First 1)
  Write-SetupLog "Chocolatey $($state.chocolatey) is ready."
  Save-SetupState

  $done = New-Object System.Collections.ArrayList
  foreach ($app in $apps) {
    Write-SetupLog "Installing $app."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $choco install $app -y --no-progress --limit-output 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    foreach ($l in @($out | Select-Object -Last 12)) { Add-Content -LiteralPath $log -Value "  [$app] $l" }
    # 1641 and 3010 mean "installed, restart wanted".
    $ok = ($code -eq 0 -or $code -eq 1641 -or $code -eq 3010)
    $version = $null
    $listed = & $choco list --limit-output --exact $app 2>$null
    foreach ($l in @($listed)) { if ([string]$l -match '^[^|]+\|(.+)$') { $version = $Matches[1] } }
    [void]$done.Add([ordered]@{ id = $app; ok = $ok; exit = $code; version = $version; seconds = [int]$sw.Elapsed.TotalSeconds; restart = ($code -eq 1641 -or $code -eq 3010) })
    $state.apps = @($done.ToArray())
    Save-SetupState
    Write-SetupLog "$app $(if ($ok) { 'installed' } else { 'FAILED' }) (exit $code, $([int]$sw.Elapsed.TotalSeconds) s)."
  }

  if ($harden) {
    $on = @($harden.Options.Keys | Where-Object { $harden.Options[$_] })
    Write-SetupLog "Hardening: $($harden.Repo) at $($harden.Commit), $($on.Count) parts."
    $h = [ordered]@{ repo = $harden.Repo; commit = $harden.Commit; ok = $false; options = $on; error = $null }
    try {
      $work = Join-Path $data 'sources'
      New-Item -ItemType Directory -Force -Path $work | Out-Null
      $zip = Join-Path $work 'harden.zip'
      (New-Object Net.WebClient).DownloadFile("https://github.com/$($harden.Repo)/archive/$($harden.Commit).zip", $zip)
      $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
      if ($got -ne $harden.ZipSha256) { throw "The download does not match the pinned copy (got $got). Not running it." }
      $dest = Join-Path $work 'harden'
      if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
      Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
      $entry = Get-ChildItem -LiteralPath $dest -Recurse -Filter $harden.Script | Select-Object -First 1
      if (-not $entry) { throw "$($harden.Script) is not in the download." }
      # -Command, not -File: Windows PowerShell 5.1 hands -File arguments over as text,
      # and the script's [bool] parameters refuse the text "$false".
      $call = "& '" + $entry.FullName.Replace("'", "''") + "'"
      foreach ($k in $harden.Options.Keys) { $call += (' -{0}:${1}' -f $k, ([string]$harden.Options[$k]).ToLower()) }
      $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $call + '; exit $LASTEXITCODE"'))
      $hlog = Join-Path $logs 'firstboot-harden.log'
      $p = Start-Process -FilePath powershell.exe -ArgumentList $argList -WorkingDirectory $entry.DirectoryName -Wait -PassThru -RedirectStandardOutput $hlog -WindowStyle Hidden
      $h.ok = ($p.ExitCode -eq 0)
      if (-not $h.ok) { $h.error = "exit $($p.ExitCode)" }
      Write-SetupLog "Hardening finished (exit $($p.ExitCode)). Its output: $hlog. Restart the PC for all of it to apply."
    } catch {
      $h.error = $_.Exception.Message
      Write-SetupLog "Hardening did not run: $($h.error)"
    }
    $state.harden = $h
  }
  $state.ok = (@($state.apps | Where-Object { -not $_.ok }).Count -eq 0) -and (-not $state.harden -or $state.harden.ok)
} catch {
  $state.error = $_.Exception.Message
  Write-SetupLog "Stopped: $($state.error)"
}
$state.finished = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
Save-SetupState
Write-SetupLog "Done. $(@($state.apps | Where-Object { $_.ok }).Count) of $($apps.Count) apps installed."
'@
    ($head.TrimEnd() + "`r`n" + $body) -replace "(?<!`r)`n", "`r`n"
}

# The apps and hardening choices a config asks for at first boot.
function Get-PhxFirstBootPlan([hashtable]$Config) {
    $fb = $Config['firstBoot']
    if (-not ($fb -is [System.Collections.IDictionary])) { $fb = @{} }
    $apps = @()
    if (-not ($fb.Contains('choco') -and $fb['choco'] -eq $false)) {
        $src = if ($fb['apps']) { $fb['apps'] } else { $Config['apps'] }
        $apps = @($src | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    }
    @{
        enabled = [bool]$fb['enabled']
        apps = [string[]]$apps
        harden = $fb['harden']
        waitMinutes = $(if ($fb['waitMinutes']) { [int]$fb['waitMinutes'] } else { 10 })
        reportUrl = [string]$fb['reportUrl']
    }
}

function Invoke-PhxSetupScript([hashtable]$A) {
    $apps = $null; $harden = $null; $wait = 10; $report = ''
    if ($A.Contains('apps')) {
        $apps = [string[]]@($A['apps'] | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        $harden = $A['harden']
        if ($A['waitMinutes']) { $wait = [int]$A['waitMinutes'] }
        $report = [string]$A['reportUrl']
    } else {
        $plan = Get-PhxFirstBootPlan (Get-PhxConfig $A['configPath'])
        $apps = $plan.apps; $harden = $plan.harden; $wait = $plan.waitMinutes; $report = $plan.reportUrl
    }
    $script = New-PhxFirstBootScript $apps $harden $wait $report
    $bytes = [Text.Encoding]::UTF8.GetBytes($script)
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    $out = $null
    if ($A['outPath']) {
        $out = [IO.Path]::GetFullPath([string]$A['outPath'])
        $dir = Split-Path -Parent $out
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($out, $script, [Text.UTF8Encoding]::new($false))
    }
    $h = Resolve-PhxHardenChoices $harden
    [ordered]@{
        script = $script; sha256 = $sha; bytes = $bytes.Length; outPath = $out
        apps = @($apps)
        harden = $(if ($h) { @($h.choices.Keys | Where-Object { $h.choices[$_] }) } else { @() })
    }
}
