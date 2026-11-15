# Phoenix engine: `firewall`, `network`, `defender` and `bitlocker` step kinds.

$script:PhxFwProfiles = @('Domain', 'Private', 'Public')

function Get-PhxFwEffectiveDefault($Value, [string]$Direction) {
    $v = [string]$Value
    if ($v -eq 'NotConfigured' -or -not $v) { if ($Direction -eq 'Inbound') { return 'Block' } else { return 'Allow' } }
    $v
}

function Invoke-PhxStep_firewall {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    if ($Ctx.Mode -eq 'apply') { Export-PhxSnapshotFirewall }

    # Logging on every profile.
    if ([bool](Get-PhxField $Step 'logging' $false)) {
        foreach ($p in $profiles) {
            $cur = "allowed=$($p.LogAllowed) blocked=$($p.LogBlocked)"
            $pn = [string]$p.Name
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "logging:$pn" -Current $cur -Target 'allowed=True blocked=True' -AtTarget:([string]$p.LogAllowed -eq 'True' -and [string]$p.LogBlocked -eq 'True') -Do {
                Set-NetFirewallProfile -Name $pn -LogAllowed True -LogBlocked True -LogMaxSizeKilobytes 16384 -ErrorAction Stop
            }
        }
    }

    # Disable every enabled rule outside the kept display groups (Phoenix's own rules are always kept).
    if ([bool](Get-PhxField $Step 'disableOtherRules' $false)) {
        $keepGroups = @(Get-PhxField $Step 'keepGroups' @())
        $enabled = @(Get-NetFirewallRule -Enabled True -ErrorAction Stop)
        $victims = @($enabled | Where-Object {
                $g = [string]$_.DisplayGroup
                ([string]$_.Group -ne 'Phoenix') -and -not ($keepGroups | Where-Object { $g -like $_ })
            })
        $kept = $enabled.Count - $victims.Count
        $sample = (@($victims | Select-Object -First 25 | ForEach-Object { $_.DisplayName }) -join '; ')
        $names = @($victims | ForEach-Object { $_.Name })
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key 'rules outside kept groups' -Current "$($victims.Count) enabled ($kept kept in: $($keepGroups -join ', '))" -Target 'disabled' -Action disable -AtTarget:($victims.Count -eq 0) -Msg $sample -Do {
            foreach ($n in $names) { Disable-NetFirewallRule -Name $n -ErrorAction Stop }
            "$($names.Count) rules disabled (snapshot firewall.wfw restores them)"
        }
    }

    # Phoenix rules.
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        $name = [string]$it['name']
        try {
            $dir = [string](Get-PhxField $it 'direction' 'Outbound')
            $act = [string](Get-PhxField $it 'action' 'Allow')
            $prog = [string](Get-PhxField $it 'program' '')
            $progExp = if ($prog) { [Environment]::ExpandEnvironmentVariables($prog) } else { '' }
            if ($progExp -and $progExp -notlike '*`**' -and -not (Test-Path -LiteralPath $progExp)) {
                Write-PhxChange -Step $sid -Key "rule:$name" -Current '(program not installed)' -Target "$act $dir $prog" -Action skip -Msg "$progExp not found; re-run after installing it"
                $Ctx.Stats.skipped++
                continue
            }
            $existing = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'Phoenix' })
            $ok = $false
            if ($existing.Count -eq 1) {
                $e = $existing[0]
                $appOk = $true
                if ($progExp) { $af = $e | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue; $appOk = $af -and ([string]$af.Program -ieq $progExp -or [string]$af.Program -ieq $prog) }
                $ok = ([string]$e.Direction -eq $dir) -and ([string]$e.Action -eq $act) -and ([string]$e.Enabled -eq 'True') -and $appOk
            }
            $cur = if ($existing.Count -eq 0) { '(absent)' } else { 'present' + $(if ($ok) { '' } else { ' (differs)' }) }
            $r = $it
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "rule:$name" -Current $cur -Target "$act $dir $prog" -Action add -AtTarget:$ok -Do {
                Get-NetFirewallRule -DisplayName $r['name'] -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'Phoenix' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                $p = @{ DisplayName = $r['name']; Group = 'Phoenix'; Direction = (Get-PhxField $r 'direction' 'Outbound'); Action = (Get-PhxField $r 'action' 'Allow'); Enabled = 'True'; Profile = 'Any' }
                if ($r['program']) { $p.Program = [Environment]::ExpandEnvironmentVariables([string]$r['program']) }
                if ($r['protocol']) { $p.Protocol = [string]$r['protocol'] }
                if ($r['remotePort']) { $p.RemotePort = @($r['remotePort']) }
                if ($r['remoteAddress']) { $p.RemoteAddress = @($r['remoteAddress']) }
                if ($r['service']) { $p.Service = [string]$r['service'] }
                New-NetFirewallRule @p -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-PhxItemError $Ctx $sid "rule:$name" $_.Exception.Message
        }
    }

    # Default actions last.
    foreach ($pair in @(@('defaultInbound', 'Inbound', 'DefaultInboundAction'), @('defaultOutbound', 'Outbound', 'DefaultOutboundAction'))) {
        $want = [string](Get-PhxField $Step $pair[0] '')
        if (-not $want) { continue }
        foreach ($p in $profiles) {
            $cur = Get-PhxFwEffectiveDefault $p.($pair[2]) $pair[1]
            $pn = [string]$p.Name; $prop = $pair[2]; $val = $want
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "$($pair[1].ToLower()) default:$pn" -Current $cur -Target $want -AtTarget:($cur -eq $want) -Do {
                $args2 = @{ Name = $pn; ErrorAction = 'Stop' }
                $args2[$prop] = $val
                Set-NetFirewallProfile @args2
            }
        }
    }
}

# Opens/closes the outbound "install window" used by the choco step.
function Open-PhxFirewallWindow([int]$Minutes = 30) {
    $prior = @{}
    foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) { $prior[[string]$p.Name] = [string]$p.DefaultOutboundAction }
    if (-not ($prior.Values | Where-Object { $_ -eq 'Block' })) { return $null }
    # Failsafe: a SYSTEM task re-blocks outbound if Phoenix dies with the window open.
    $at = (Get-Date).AddMinutes($Minutes).ToString('HH:mm')
    $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Set-NetFirewallProfile -All -DefaultOutboundAction Block"'
    $null = & schtasks.exe /Create /F /TN 'Phoenix\CloseFirewallWindow' /SC ONCE /ST $at /RU SYSTEM /RL HIGHEST /TR $cmd 2>&1
    Set-NetFirewallProfile -All -DefaultOutboundAction Allow -ErrorAction Stop
    Write-PhxLog -Level warn -Msg "Firewall install window OPEN: outbound allowed until the step finishes (failsafe re-block at $at)."
    $prior
}

function Close-PhxFirewallWindow($Prior) {
    if (-not $Prior) { return }
    foreach ($n in @($Prior.Keys)) {
        $v = $Prior[$n]; if ($v -ne 'Block' -and $v -ne 'Allow') { $v = 'NotConfigured' }
        try { Set-NetFirewallProfile -Name $n -DefaultOutboundAction $v -ErrorAction Stop } catch { Write-PhxLog -Level error -Msg "Could not restore outbound default on $n`: $($_.Exception.Message)" }
    }
    $null = & schtasks.exe /Delete /F /TN 'Phoenix\CloseFirewallWindow' 2>&1
    Write-PhxLog -Msg 'Firewall install window closed.'
}

function Invoke-PhxStep_network {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        Write-PhxChange -Step $sid -Key 'adapters' -Current '(no physical adapters)' -Target 'bindings' -Action skip -Msg 'no network hardware present (re-run after reinserting the network card)'
        $Ctx.Stats.skipped++
        return
    }
    $only = @(Get-PhxField $Step 'onlyBindings' @())
    $explicit = @{}
    foreach ($it in (Get-PhxEnabledItems $Step)) { $explicit[[string]$it['binding']] = [bool](Get-PhxField $it 'enabled' $true) }
    foreach ($a in $adapters) {
        $bindings = @(Get-NetAdapterBinding -Name $a.Name -ErrorAction SilentlyContinue)
        foreach ($b in $bindings) {
            $comp = [string]$b.ComponentID
            $want = $null
            if ($explicit.ContainsKey($comp)) { $want = $explicit[$comp] }
            elseif ($only.Count -gt 0) { $want = ($only -contains $comp) }
            if ($null -eq $want) { continue }
            $cur = [bool]$b.Enabled
            $an = $a.Name; $cid = $comp; $wantB = $want; $curB = $cur
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "$an`: $($b.DisplayName) ($comp)" -Current $cur -Target $want -Action $(if ($want) { 'enable' } else { 'disable' }) -AtTarget:($cur -eq $want) -Do {
                Add-PhxSnapshotRecord bindings ([ordered]@{ adapter = $an; componentId = $cid; enabled = $curB })
                if ($wantB) { Enable-NetAdapterBinding -Name $an -ComponentID $cid -ErrorAction Stop } else { Disable-NetAdapterBinding -Name $an -ComponentID $cid -ErrorAction Stop }
            }
        }
    }
}

# ASR rules (Microsoft Defender attack surface reduction reference).
$script:PhxAsrRules = [ordered]@{
    '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Block abuse of exploited vulnerable signed drivers'
    '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Block Adobe Reader from creating child processes'
    'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Block all Office applications from creating child processes'
    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Block credential stealing from LSASS'
    'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Block executable content from email client and webmail'
    '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'Block executables unless they meet prevalence, age, or trusted list criteria'
    '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Block execution of potentially obfuscated scripts'
    'd3e037e1-3eb8-44c8-a917-57927947596d' = 'Block JavaScript or VBScript from launching downloaded executable content'
    '3b576869-a4ec-4529-8536-b80a7769e899' = 'Block Office applications from creating executable content'
    '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Block Office applications from injecting code into other processes'
    '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Block Office communication application from creating child processes'
    'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Block persistence through WMI event subscription'
    'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'Block process creations originating from PSExec and WMI commands'
    '33ddedf1-c6e0-47cb-833e-de6133960387' = 'Block rebooting machine in Safe Mode'
    'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Block untrusted and unsigned processes that run from USB'
    'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = 'Block use of copied or impersonated system tools'
    'a8f5898e-1dc8-49a9-9878-85004b8a61e6' = 'Block Webshell creation for Servers'
    '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Block Win32 API calls from Office macros'
    'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'Use advanced protection against ransomware'
}
$script:PhxAsrActionNames = @{ 0 = 'Off'; 1 = 'Block'; 2 = 'Audit'; 6 = 'Warn' }
$script:PhxAsrActionValues = @{ 'Off' = 0; 'Block' = 1; 'Audit' = 2 }

function Invoke-PhxStep_defender {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $status = $null; $pref = $null
    try { $status = Get-MpComputerStatus -ErrorAction Stop } catch { }
    try { $pref = Get-MpPreference -ErrorAction Stop } catch { }
    if (-not $status) {
        Write-PhxItemError $Ctx $sid 'defender' 'Microsoft Defender is not available (service missing or removed?). Nothing can be configured.'
        return
    }

    if ($Step.Contains('realtime')) {
        $want = [bool]$Step['realtime']
        # Policy values (e.g. left by a playbook's "disable Defender") override Set-MpPreference.
        if ($want) {
            foreach ($pv in @(
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender', 'DisableAntiSpyware'),
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender', 'DisableAntiVirus'),
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', 'DisableRealtimeMonitoring'),
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', 'DisableBehaviorMonitoring'),
                    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection', 'DisableOnAccessProtection'))) {
                $c = Get-PhxRegValue $pv[0] $pv[1]
                $pp = $pv[0]; $pn = $pv[1]
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "policy:$pn" -Current $(if ($c.exists) { $c.value } else { '(absent)' }) -Target '(absent)' -Action remove -AtTarget:(-not $c.exists -or [int]$c.value -eq 0) -Do {
                    Remove-PhxRegValue -Path $pp -Name $pn
                }
            }
        }
        $cur = [bool]$status.RealTimeProtectionEnabled
        $wantRt = $want
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key 'realtime protection' -Current $cur -Target $want -AtTarget:($cur -eq $want) -Do {
            Set-MpPreference -DisableRealtimeMonitoring (-not $wantRt) -ErrorAction Stop
            if ($wantRt -and -not (Get-MpComputerStatus).RealTimeProtectionEnabled) { return 'set; Tamper Protection or a reboot may be needed for it to show as on' }
        }
    }

    $asrMode = [string](Get-PhxField $Step 'asr' '')
    if ($asrMode) {
        if (-not $script:PhxAsrActionValues.ContainsKey($asrMode)) { throw "asr must be Block, Audit or Off (got '$asrMode')" }
        $exclude = @(Get-PhxField $Step 'asrExclude' @() | ForEach-Object { ([string]$_).ToLower() })
        $audit = @(Get-PhxField $Step 'asrAudit' @() | ForEach-Object { ([string]$_).ToLower() })
        $curMap = @{}
        $prefReadable = $false
        if ($pref) {
            $ids = @($pref.AttackSurfaceReductionRules_Ids); $acts = @($pref.AttackSurfaceReductionRules_Actions)
            for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i]) { $curMap[([string]$ids[$i]).ToLower()] = [int]$acts[$i] } }
            $prefReadable = $true
        }
        foreach ($gid in $script:PhxAsrRules.Keys) {
            $title = $script:PhxAsrRules[$gid]
            if ($exclude -contains $gid) {
                Write-PhxChange -Step $sid -Key "asr: $title" -Current '' -Target '' -Action skip -Msg 'excluded by pack'
                $Ctx.Stats.skipped++
                continue
            }
            $wantName = if ($audit -contains $gid) { 'Audit' } else { $asrMode }
            $curName = if ($curMap.ContainsKey($gid)) { $script:PhxAsrActionNames[$curMap[$gid]] } elseif ($prefReadable) { 'Off' } else { '(unknown: needs admin)' }
            $g = $gid; $v = $script:PhxAsrActionValues[$wantName]
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "asr: $title" -Current $curName -Target $wantName -AtTarget:($curName -eq $wantName) -Msg $gid -Do {
                Add-MpPreference -AttackSurfaceReductionRules_Ids $g -AttackSurfaceReductionRules_Actions $v -ErrorAction Stop
            }
        }
    }

    $sigFrom = [string](Get-PhxField $Step 'signaturesFrom' 'none')
    if ($sigFrom -eq 'usb') {
        $file = Get-ChildItem -Path (Get-PhxLoadoutRoot $Ctx.KitRoot) -Recurse -Filter 'mpam-fe*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        $cur = "$($status.AntivirusSignatureVersion) ($([int]$status.AntivirusSignatureAge) days old)"
        if (-not $file) {
            $miss = "NEEDS KIT: no mpam-fe.exe under $(Get-PhxLoadoutRoot $Ctx.KitRoot) (include the 'defender-defs' loadout item when building the USB)"
            if ($Ctx.Mode -eq 'apply') { Write-PhxItemError $Ctx $sid 'signatures' $miss }
            else { Write-PhxChange -Step $sid -Key 'signatures' -Current $cur -Target 'update from kit' -Action set -Msg $miss; $Ctx.Stats.changes++ }
        } else {
            $fp = $file.FullName
            Invoke-PhxChange -Ctx $Ctx -Step $sid -Key 'signatures' -Current $cur -Target "update from $($file.Name) ($($file.LastWriteTime.ToString('yyyy-MM-dd')))" -Action set -Do {
                $p = Start-Process -FilePath $fp -ArgumentList '-q' -Wait -PassThru -WindowStyle Hidden
                if ($p.ExitCode -ne 0) { throw "mpam-fe.exe exited with $($p.ExitCode)" }
                "now $((Get-MpComputerStatus).AntivirusSignatureVersion)"
            }
        }
    } elseif ($sigFrom -eq 'online') {
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key 'signatures' -Current "$($status.AntivirusSignatureVersion)" -Target 'latest (online)' -Do {
            Update-MpSignature -ErrorAction Stop
        }
    }
}

# Finds the drive holding the Phoenix kit marker (\phoenix\phoenix.id). Returns 'E:' or $null.
function Find-PhxUsbKitDrive {
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID })) {
        $marker = Join-Path ($v.DeviceID + '\') 'phoenix\phoenix.id'
        if (Test-Path -LiteralPath $marker) { return $v.DeviceID }
    }
    $null
}

function Invoke-PhxStep_bitlocker {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    if (-not [bool](Get-PhxField $Step 'enable' $false)) { return }
    $mount = $env:SystemDrive
    $vol = $null
    if ($Ctx.IsAdmin) { try { $vol = Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop } catch { } }
    $cur = if ($vol) { "$($vol.VolumeStatus), protection $($vol.ProtectionStatus)" } else { '(unknown: needs admin)' }
    $on = $vol -and ([string]$vol.VolumeStatus -ne 'FullyDecrypted')
    $keyTo = [string](Get-PhxField $Step 'recoveryKeyTo' 'usb')
    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "bitlocker $mount" -Current $cur -Target 'XtsAes256, TPM + recovery password' -Action enable -AtTarget:$on -Do {
        if ($keyTo -ne 'usb') { throw "recoveryKeyTo '$keyTo' is not supported (use usb)" }
        $tpm = Get-Tpm -ErrorAction Stop
        if (-not $tpm.TpmReady) { throw 'TPM is not ready; enable it in firmware first.' }
        $drive = Find-PhxUsbKitDrive
        if (-not $drive) { throw 'Phoenix USB not found: plug it in so the recovery key can be saved before encrypting.' }
        $dir = Join-Path ($drive + '\') 'phoenix\recovery'
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        $file = Join-Path $dir ("{0}-{1}-bitlocker.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        # Prove the USB is writable (a write-locked Rock fails here, before anything is encrypted).
        [IO.File]::WriteAllText($file, "pending`r`n")
        $v = Enable-BitLocker -MountPoint $mount -EncryptionMethod XtsAes256 -UsedSpaceOnly -RecoveryPasswordProtector -ErrorAction Stop
        $rp = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }) | Select-Object -Last 1
        [IO.File]::WriteAllText($file, "BitLocker recovery for $env:COMPUTERNAME $mount`r`nID: $($rp.KeyProtectorId)`r`nRecovery password: $($rp.RecoveryPassword)`r`n")
        Add-BitLockerKeyProtector -MountPoint $mount -TpmProtector -ErrorAction Stop | Out-Null
        Add-PhxSnapshotRecord nonRestorable ([ordered]@{ key = 'bitlocker'; hint = "decrypt with Disable-BitLocker -MountPoint $mount; recovery key saved to $file" })
        "encryption started; recovery key saved to $file - store it somewhere safe and off this USB"
    }
}
