# Phoenix engine: `choco`, `tools` and `manual` step kinds.

function Get-PhxChocoExe {
    $c = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $null
}

# @{ id(lowercase) = version } of locally installed packages.
function Get-PhxChocoInstalled([string]$Choco) {
    $map = @{}
    if (-not $Choco) { return $map }
    $out = & $Choco list --limit-output 2>$null
    if ($LASTEXITCODE -ne 0) { $out = & $Choco list --local-only --limit-output 2>$null }
    foreach ($l in @($out)) { if ($l -match '^([^|]+)\|(.+)$') { $map[$matches[1].ToLower()] = $matches[2] } }
    $map
}

function Install-PhxChocolatey([string]$KitRoot, [string]$From) {
    $nupkg = $null
    if ($From -eq 'usb') {
        $nupkg = Get-ChildItem -Path (Join-Path $KitRoot 'loadout') -Recurse -Filter 'chocolatey*.nupkg' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^chocolatey\.\d' -or $_.Name -eq 'chocolatey.nupkg' } | Sort-Object Name -Descending | Select-Object -First 1
    }
    if ($nupkg) {
        # Documented offline install: unzip the nupkg and run tools\chocolateyInstall.ps1.
        $tmp = Join-Path $env:TEMP ('phx-choco-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'choco.zip'
            Copy-Item -LiteralPath $nupkg.FullName -Destination $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            $inst = Join-Path $tmp 'tools\chocolateyInstall.ps1'
            if (-not (Test-Path $inst)) { throw "chocolateyInstall.ps1 not found in $($nupkg.Name)" }
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inst 2>&1
            if ($LASTEXITCODE -ne 0 -and -not (Get-PhxChocoExe)) { throw "offline Chocolatey install failed: $(($o | Out-String).Trim())" }
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        return "installed from $($nupkg.Name)"
    }
    if ($From -eq 'usb') { Write-PhxLog -Level warn -Msg 'No chocolatey nupkg in the kit loadout; installing online.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $script = (New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $script 2>&1
    if (-not (Get-PhxChocoExe)) { throw "online Chocolatey install failed: $(($o | Out-String).Trim())" }
    'installed online'
}

function Invoke-PhxStep_choco {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $apps = @()
    if ($Ctx.Config.Contains('apps') -and $Ctx.Config['apps']) { $apps = @($Ctx.Config['apps'] | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [string]$_['id'] } else { [string]$_ } } | Where-Object { $_ }) }
    foreach ($it in (Get-PhxEnabledItems $Step)) { if ($it['id']) { $apps += [string]$it['id'] } }
    $apps = @($apps | Select-Object -Unique)
    $from = [string](Get-PhxField $Step 'bootstrapFrom' 'usb')
    $window = Get-PhxField $Step 'window' $null
    $minutes = if ($window) { [int](Get-PhxField $window 'minutes' 30) } else { 0 }

    $choco = Get-PhxChocoExe
    $installed = Get-PhxChocoInstalled $choco
    $chocoCur = if ($choco) { 'installed ' + $(if ($installed.ContainsKey('chocolatey')) { $installed['chocolatey'] } else { '' }) } else { '(not installed)' }

    $prior = $null
    try {
        if ($Ctx.Mode -eq 'apply' -and $minutes -gt 0) { $prior = Open-PhxFirewallWindow -Minutes $minutes }
        elseif ($minutes -gt 0) {
            Write-PhxChange -Step $sid -Key 'firewall install window' -Current 'closed' -Target "open up to $minutes min, then closed" -Action set -Msg 'outbound allowed only while this step runs'
            $Ctx.Stats.changes++
        }

        $kr = $Ctx.KitRoot
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key 'chocolatey' -Current $chocoCur -Target "installed (from $from)" -Action add -AtTarget:([bool]$choco) -Do {
            Install-PhxChocolatey -KitRoot $kr -From $from
        }
        if ($Ctx.Mode -eq 'apply') { $choco = Get-PhxChocoExe }

        $localSrc = Join-Path $Ctx.KitRoot 'loadout\choco-packages'
        $srcArg = if (Test-Path -LiteralPath $localSrc) { @('--source', "`"$localSrc;https://community.chocolatey.org/api/v2/`"") } else { @() }
        foreach ($app in $apps) {
            $aid = $app.ToLower()
            $cur = if ($installed.ContainsKey($aid)) { 'installed ' + $installed[$aid] } else { '(not installed)' }
            $appId = $app
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "app:$app" -Current $cur -Target 'installed' -Action add -AtTarget:($installed.ContainsKey($aid)) -Do {
                if (-not $choco) { throw 'choco.exe not available' }
                $lines = & $choco install $appId -y --no-progress --limit-output @srcArg 2>&1
                foreach ($l in @($lines | Select-Object -Last 8)) { Write-PhxLog -Msg "[choco $appId] $l" }
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "choco install exited with $LASTEXITCODE" }
                if ($LASTEXITCODE -eq 3010) { 'installed; reboot required' }
            }
        }
    } finally {
        if ($prior) { Close-PhxFirewallWindow $prior }
    }
}

# $PROFILE (CurrentUserAllHosts) paths of the interactive user, for both PowerShell editions.
function Get-PhxProfilePaths {
    $u = Get-PhxInteractiveUser
    $docs = $null
    if ($u.isSelf) { $docs = [Environment]::GetFolderPath('MyDocuments') }
    else {
        $r = Get-PhxInteractiveUserRoot
        if ($r.root) {
            $v = Get-PhxRegValue ($r.root + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') 'Personal'
            if ($v.exists) {
                $docs = [string]$v.value
                $i = $docs.IndexOf('%USERPROFILE%', [StringComparison]::OrdinalIgnoreCase)
                if ($i -ge 0) { $docs = $docs.Substring(0, $i) + $u.profilePath + $docs.Substring($i + 13) }
                if ($docs -like '*%*') { $docs = $null }  # other variables (e.g. OneDrive) can't be resolved for another user
            }
        }
        if (-not $docs -and $u.profilePath) { $docs = Join-Path $u.profilePath 'Documents' }
    }
    if (-not $docs) { throw 'Cannot resolve the interactive user''s Documents folder.' }
    @(
        (Join-Path $docs 'WindowsPowerShell\profile.ps1'),
        (Join-Path $docs 'PowerShell\profile.ps1')
    )
}

# User-scope environment variables of the interactive user (HKU\<sid>\Environment when it is not us).
function Get-PhxUserEnv([string]$Name) {
    $u = Get-PhxInteractiveUser
    if ($u.isSelf) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $r = Get-PhxInteractiveUserRoot
    if (-not $r.root) { throw "Cannot load the registry hive of $($u.name)." }
    $v = Get-PhxRegValue ($r.root + '\Environment') $Name
    if ($v.exists) { [string]$v.value } else { $null }
}

function Set-PhxUserEnv([string]$Name, [string]$Value) {
    $u = Get-PhxInteractiveUser
    if ($u.isSelf) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User'); return }
    $r = Get-PhxInteractiveUserRoot
    if (-not $r.root) { throw "Cannot load the registry hive of $($u.name)." }
    $type = if ($Value -like '*%*') { 'ExpandString' } else { 'String' }
    Set-PhxRegValue -Path ($r.root + '\Environment') -Name $Name -Type $type -Value $Value -Hive $r.hive -SubPath 'Environment'
}

function Invoke-PhxStep_tools {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        $key = [string]$it['_key']
        try {
            if ($it['loadout']) {
                $src = Join-Path $Ctx.KitRoot ('loadout\' + $it['loadout'])
                $dest = [Environment]::ExpandEnvironmentVariables([string](Get-PhxField $it 'dest' ("C:\Tools\" + $it['loadout'])))
                if (-not (Test-Path -LiteralPath $src)) {
                    # On the build PC the kit has no loadout yet; that's only an error when applying.
                    $miss = "NEEDS KIT: loadout '$($it['loadout'])' is not in the kit ($src); include it when building the USB"
                    if ($Ctx.Mode -eq 'apply') { Write-PhxItemError $Ctx $sid $key $miss }
                    else { Write-PhxChange -Step $sid -Key $key -Current '(not in kit)' -Target "copied to $dest" -Action add -Msg $miss; $Ctx.Stats.changes++ }
                    continue
                }
                $srcCount = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue).Count
                $dstCount = if (Test-Path -LiteralPath $dest) { @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count } else { 0 }
                $s = $src; $d = $dest
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $key -Current "$dstCount files at $dest" -Target "$srcCount files at $dest" -Action add -AtTarget:($dstCount -ge $srcCount -and $srcCount -gt 0) -Do {
                    New-Item -ItemType Directory -Force -Path $d | Out-Null
                    Copy-Item -Path (Join-Path $s '*') -Destination $d -Recurse -Force -ErrorAction Stop
                }
            } elseif ($it['env']) {
                $scope = [string](Get-PhxField $it 'scope' 'machine')
                $isUser = $scope -eq 'user'
                # User scope = the interactive user, even when elevated as the admin.
                $who = if ($isUser) { ' [interactive user ' + (Get-PhxInteractiveUser).name + ']' } else { ' [machine]' }
                $val = [string]$it['value']
                if (-not $isUser) { $val = [Environment]::ExpandEnvironmentVariables($val) }
                $envName = [string]$it['env']
                $var = $envName.TrimEnd('+')
                $cur = if ($isUser) { Get-PhxUserEnv $var } else { [Environment]::GetEnvironmentVariable($var, 'Machine') }
                $v = $var; $u = $isUser; $nv = $val
                if ($envName.EndsWith('+')) {
                    $has = @(([string]$cur) -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $val.TrimEnd('\') }).Count -gt 0
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key ($key + $who) -Current $(if ($has) { "contains $val" } else { "missing $val" }) -Target "contains $val" -Action add -AtTarget:$has -Do {
                        $now = if ($u) { Get-PhxUserEnv $v } else { [Environment]::GetEnvironmentVariable($v, 'Machine') }
                        $joined = ((@(([string]$now) -split ';' | Where-Object { $_ }) + $nv) -join ';')
                        if ($u) { Set-PhxUserEnv $v $joined }
                        else {
                            Add-PhxSnapshotRecord registry ([ordered]@{ path = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; name = $v; existed = ($null -ne $now); kind = 'ExpandString'; value = $now; hive = ''; subPath = '' })
                            [Environment]::SetEnvironmentVariable($v, $joined, 'Machine')
                        }
                    }
                } else {
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key ($key + $who) -Current $(if ($null -eq $cur) { '(unset)' } else { $cur }) -Target $val -AtTarget:($cur -eq $val) -Do {
                        if ($u) { Set-PhxUserEnv $v $nv } else { [Environment]::SetEnvironmentVariable($v, $nv, 'Machine') }
                    }
                }
            } elseif ($it['profileSnippet']) {
                $snippet = [string]$it['profileSnippet']
                $marker = '# >>> phoenix ' + (Get-PhxStringHash $snippet)
                foreach ($pp in (Get-PhxProfilePaths)) {
                    $has = (Test-Path -LiteralPath $pp) -and ((Get-Content -LiteralPath $pp -Raw -ErrorAction SilentlyContinue) -like "*$marker*")
                    $path = $pp; $block = "`r`n$marker`r`n$snippet`r`n# <<< phoenix`r`n"
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "$key -> $pp" -Current $(if ($has) { 'present' } else { 'absent' }) -Target 'present' -Action add -AtTarget:$has -Do {
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                        Add-Content -LiteralPath $path -Value $block -Encoding UTF8
                    }
                }
            } else {
                Write-PhxItemError $Ctx $sid $key 'tools item needs loadout, env or profileSnippet'
            }
        } catch {
            Write-PhxItemError $Ctx $sid $key $_.Exception.Message
        }
    }
}

function Invoke-PhxStep_manual {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    Write-PhxChange -Step $sid -Key 'manual' -Current '' -Target '' -Action skip -Msg ('Manual step, done in the app: ' + [string](Get-PhxField $Step 'title' $sid))
    $Ctx.Stats.skipped++
}
