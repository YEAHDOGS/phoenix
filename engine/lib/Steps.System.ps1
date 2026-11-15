# Phoenix engine: `services` and `tasks` step kinds.

# Services Phoenix refuses to change unless the item sets "force": true.
# Disabling these breaks boot, logon, the shell, WMI (which Phoenix itself uses),
# the firewall, Defender, or app/feature servicing.
$script:PhxProtectedServices = @(
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'BrokerInfrastructure', 'Power', 'PlugPlay', 'ProfSvc',
    'SamSs', 'EventLog', 'Winmgmt', 'BFE', 'mpssvc', 'WinDefend', 'SecurityHealthService', 'wscsvc',
    'Dhcp', 'Dnscache', 'nsi', 'CoreMessagingRegistrar', 'StateRepository', 'gpsvc', 'UserManager',
    'SystemEventsBroker', 'TrustedInstaller', 'CryptSvc', 'KeyIso', 'Schedule', 'AppXSvc', 'TimeBrokerSvc',
    'AudioSrv', 'AudioEndpointBuilder', 'Wcmsvc', 'netprofm', 'NlaSvc', 'msiserver', 'WdNisSvc', 'Sense'
)

$script:PhxStartNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
$script:PhxStartValues = @{ 'Automatic' = 2; 'Manual' = 3; 'Disabled' = 4 }

function Get-PhxServiceKeys([string]$Pattern, [bool]$IncludeDrivers) {
    $root = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services'
    , @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object {
            if ($_.PSChildName -notlike $Pattern) { return $false }
            $t = $_.GetValue('Type', $null)
            if ($null -eq $t) { return $false }
            $isService = ([int]$t -band 0x30) -ne 0 -or [int]$t -eq 0x50 -or [int]$t -eq 0x60
            $isService -or $IncludeDrivers
        })
}

function Get-PhxServiceStart($Key) {
    $start = $Key.GetValue('Start', $null)
    $delayed = $Key.GetValue('DelayedAutostart', 0)
    $name = if ($null -ne $start -and $script:PhxStartNames.ContainsKey([int]$start)) { $script:PhxStartNames[[int]$start] } else { "unknown($start)" }
    if ($name -eq 'Automatic' -and [int]$delayed -eq 1) { $name = 'AutomaticDelayed' }
    @{ name = $name; start = $start; delayed = $delayed }
}

function Restore-PhxServiceRecord($R) {
    $rp = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($R['name'])"
    if ($null -ne $R['start']) { Set-ItemProperty -LiteralPath $rp -Name 'Start' -Value ([int]$R['start']) -Type DWord -ErrorAction Stop }
    if ($null -ne $R['delayed']) { Set-ItemProperty -LiteralPath $rp -Name 'DelayedAutostart' -Value ([int]$R['delayed']) -Type DWord -ErrorAction SilentlyContinue }
}

function Invoke-PhxStep_services {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        $pattern = [string]$it['name']
        try {
            $target = [string](Get-PhxField $it 'startup' 'Disabled')
            if (-not $script:PhxStartValues.ContainsKey($target)) { throw "startup must be Disabled, Manual or Automatic (got '$target')" }
            $keys = Get-PhxServiceKeys $pattern ([bool](Get-PhxField $it 'driver' $false))
            if ($keys.Count -eq 0) {
                Write-PhxChange -Step $sid -Key $pattern -Current '(not installed)' -Target $target -Action skip -Msg 'service not present on this machine'
                $Ctx.Stats.skipped++
                continue
            }
            foreach ($k in $keys) {
                $svc = $k.PSChildName
                $cur = Get-PhxServiceStart $k
                if ($script:PhxProtectedServices -contains $svc -and -not (Get-PhxField $it 'force' $false) -and $target -eq 'Disabled') {
                    Write-PhxChange -Step $sid -Key $svc -Current $cur.name -Target $target -Action skip -Msg 'PROTECTED: Phoenix will not disable this service (set "force": true on the item to override)'
                    $Ctx.Stats.skipped++
                    continue
                }
                $atTarget = ($cur.name -eq $target) -or ($target -eq 'Automatic' -and $cur.name -eq 'AutomaticDelayed')
                $svcName = $svc; $svcTarget = $target; $svcCur = $cur; $svcStop = [bool](Get-PhxField $it 'stop' $false)
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $svc -Current $cur.name -Target $target -AtTarget:$atTarget -Do {
                    Add-PhxSnapshotRecord services ([ordered]@{ name = $svcName; start = $svcCur.start; delayed = $svcCur.delayed })
                    $done = $false
                    try { Set-Service -Name $svcName -StartupType $svcTarget -ErrorAction Stop; $done = $true } catch { }
                    if (-not $done) {
                        # Per-user templates and some protected services refuse Set-Service; the registry works as admin.
                        Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$svcName" -Name 'Start' -Value $script:PhxStartValues[$svcTarget] -Type DWord -ErrorAction Stop
                    }
                    if ($svcStop -and $svcTarget -eq 'Disabled') {
                        $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                        if ($s -and $s.Status -ne 'Stopped') {
                            try { Stop-Service -Name $svcName -Force -ErrorAction Stop } catch { return "start type set; stop failed: $($_.Exception.Message)" }
                        }
                    }
                }
            }
        } catch {
            Write-PhxItemError $Ctx $sid $pattern $_.Exception.Message
        }
    }
}

function Invoke-PhxStep_tasks {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $all = $null
    try { $all = @(Get-ScheduledTask -ErrorAction Stop) } catch { throw "Cannot enumerate scheduled tasks: $($_.Exception.Message)" }
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        $pattern = [string]$it['path']
        try {
            if (-not $pattern.StartsWith('\')) { $pattern = '\' + $pattern }
            $action = [string](Get-PhxField $it 'action' 'disable')
            if ($action -ne 'disable') { throw "tasks support only action 'disable'" }
            $hits = @($all | Where-Object { ($_.TaskPath + $_.TaskName) -like $pattern })
            if ($hits.Count -eq 0) {
                Write-PhxChange -Step $sid -Key $pattern -Current '(not present)' -Target 'Disabled' -Action skip -Msg 'no matching task'
                $Ctx.Stats.skipped++
                continue
            }
            foreach ($t in $hits) {
                $full = $t.TaskPath + $t.TaskName
                $state = [string]$t.State
                $tPath = $t.TaskPath; $tName = $t.TaskName; $tState = $state
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $full -Current $state -Target 'Disabled' -Action disable -AtTarget:($state -eq 'Disabled') -Do {
                    Add-PhxSnapshotRecord tasks ([ordered]@{ path = $tPath + $tName; taskPath = $tPath; taskName = $tName; state = $tState })
                    Disable-ScheduledTask -TaskPath $tPath -TaskName $tName -ErrorAction Stop | Out-Null
                }
            }
        } catch {
            Write-PhxItemError $Ctx $sid $pattern $_.Exception.Message
        }
    }
}
