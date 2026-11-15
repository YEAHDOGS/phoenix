# Phoenix engine: registry helpers, user-hive mounting, and the `registry` and `setting` step kinds.

$script:PhxMountedHives = New-Object System.Collections.Generic.List[string]

function ConvertTo-PhxRegPath([string]$Path) {
    $p = $Path.Trim()
    if ($p -like 'Registry::*') { return $p }
    $map = [ordered]@{
        'HKLM:' = 'HKEY_LOCAL_MACHINE'; 'HKCU:' = 'HKEY_CURRENT_USER'; 'HKU:' = 'HKEY_USERS'; 'HKCR:' = 'HKEY_CLASSES_ROOT'
        'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKCU' = 'HKEY_CURRENT_USER'; 'HKU' = 'HKEY_USERS'; 'HKCR' = 'HKEY_CLASSES_ROOT'
    }
    foreach ($k in $map.Keys) {
        if ($p.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'Registry::' + $map[$k] + $p.Substring($k.Length) }
    }
    if ($p -match '^HKEY_[A-Z_]+\\') { return 'Registry::' + $p }
    throw "Unsupported registry path '$Path' (use HKLM:\..., HKCU:\...)"
}

# @{ exists; value; kind } - never throws for a missing key/value.
function Get-PhxRegValue([string]$Path, [string]$Name) {
    $rp = ConvertTo-PhxRegPath $Path
    $res = @{ exists = $false; value = $null; kind = $null }
    try {
        $key = Get-Item -LiteralPath $rp -ErrorAction Stop
        $names = @($key.GetValueNames())
        $lookup = if ($Name) { $Name } else { '' }
        if ($names -contains $lookup) {
            $res.exists = $true
            $res.kind = [string]$key.GetValueKind($lookup)
            $res.value = $key.GetValue($lookup, $null, 'DoNotExpandEnvironmentNames')
        }
    } catch { }
    $res
}

function ConvertTo-PhxRegData([string]$Type, $Value) {
    switch ($Type) {
        'DWord' {
            $u = [uint64]0
            if ($Value -is [string] -and $Value -match '^0x[0-9a-fA-F]+$') { $u = [Convert]::ToUInt64($Value.Substring(2), 16) }
            elseif ([int64]$Value -lt 0) { return [int32]$Value }
            else { $u = [uint64]$Value }
            return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$u), 0)
        }
        'QWord' {
            if ($Value -is [string] -and $Value -match '^0x[0-9a-fA-F]+$') { return [BitConverter]::ToInt64([BitConverter]::GetBytes([Convert]::ToUInt64($Value.Substring(2), 16)), 0) }
            return [int64]$Value
        }
        'Binary' {
            if ($Value -is [string]) {
                $hex = $Value -replace '[^0-9a-fA-F]', ''
                return [byte[]](0..($hex.Length / 2 - 1) | ForEach-Object { [Convert]::ToByte($hex.Substring($_ * 2, 2), 16) })
            }
            return [byte[]]@($Value)
        }
        'MultiString' { return [string[]]@($Value) }
        default { return [string]$Value }
    }
}

function Format-PhxRegValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) { return (-join ($Value | ForEach-Object { $_.ToString('x2') })) }
    if ($Value -is [array]) { return ($Value -join '|') }
    return $Value
}

function Test-PhxRegEqual($Current, [string]$Type, $Target) {
    if (-not $Current.exists) { return $false }
    $t = ConvertTo-PhxRegData $Type $Target
    $c = $Current.value
    switch ($Type) {
        'DWord' { return ([uint32][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$c), 0)) -eq ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$t), 0)) }
        'QWord' { return [int64]$c -eq [int64]$t }
        'Binary' { return (Format-PhxRegValue ([byte[]]$c)) -eq (Format-PhxRegValue $t) }
        'MultiString' { return (@($c) -join "`n") -eq (@($t) -join "`n") }
        default { return [string]$c -eq [string]$t }
    }
}

# Writes a value, recording the prior value in the active snapshot.
function Set-PhxRegValue([string]$Path, [string]$Name, [string]$Type, $Value, [string]$Hive = '', [string]$SubPath = '') {
    $rp = ConvertTo-PhxRegPath $Path
    $prior = Get-PhxRegValue $Path $Name
    Add-PhxSnapshotRecord registry ([ordered]@{
            path = $rp; name = $Name; existed = $prior.exists; kind = $prior.kind
            value = (Format-PhxRegValue $prior.value); hive = $Hive; subPath = $SubPath
        })
    if (-not (Test-Path -LiteralPath $rp)) { New-Item -Path $rp -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $rp -Name $Name -PropertyType $Type -Value (ConvertTo-PhxRegData $Type $Value) -Force -ErrorAction Stop | Out-Null
}

function Remove-PhxRegValue([string]$Path, [string]$Name) {
    $rp = ConvertTo-PhxRegPath $Path
    $prior = Get-PhxRegValue $Path $Name
    if (-not $prior.exists) { return }
    Add-PhxSnapshotRecord registry ([ordered]@{ path = $rp; name = $Name; existed = $true; kind = $prior.kind; value = (Format-PhxRegValue $prior.value); hive = ''; subPath = '' })
    Remove-ItemProperty -LiteralPath $rp -Name $Name -Force -ErrorAction Stop
}

function Restore-PhxRegistryRecord($R) {
    $path = [string]$R['path']
    # Prefer the original location when its hive is loaded (e.g. HKEY_USERS\<sid> of a logged-on user).
    $rootLoaded = $false
    if ($path -match '^Registry::(HKEY_USERS\\[^\\]+)') { $rootLoaded = Test-Path -LiteralPath ('Registry::' + $matches[1]) }
    elseif ($path -match '^Registry::HKEY_(LOCAL_MACHINE|CURRENT_USER)') { $rootLoaded = $true }
    if ($R['hive'] -and -not $rootLoaded) {
        $mount = Mount-PhxHive -File $R['hive'] -Name ('PhxUndo' + (Get-PhxStringHash $R['hive']))
        if (-not $mount) { throw "Could not load hive $($R['hive'])" }
        $path = $mount + '\' + $R['subPath']
    }
    if ($R['existed']) {
        $kind = [string]$R['kind']
        $val = $R['value']
        if ($kind -eq 'Binary') { $val = ConvertTo-PhxRegData 'Binary' ([string]$val) }
        elseif ($kind -eq 'MultiString') { $val = [string[]](([string]$val) -split '\|') }
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $R['name'] -PropertyType $kind -Value $val -Force -ErrorAction Stop | Out-Null
    } else {
        if (Test-Path -LiteralPath $path) { Remove-ItemProperty -LiteralPath $path -Name $R['name'] -Force -ErrorAction SilentlyContinue }
    }
}

# Loads an NTUSER.DAT under HKEY_USERS\<Name>. Returns the provider path or $null.
function Mount-PhxHive([string]$File, [string]$Name) {
    $target = "Registry::HKEY_USERS\$Name"
    if (Test-Path -LiteralPath $target) { return $target }
    if (-not (Test-PhxIsAdmin)) { return $null }
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $null = & reg.exe load "HKU\$Name" "$File" 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $script:PhxMountedHives.Add($Name)
    $target
}

function Dismount-PhxAllHives {
    if ($script:PhxMountedHives.Count -eq 0) { return }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    foreach ($n in @($script:PhxMountedHives)) {
        for ($i = 0; $i -lt 3; $i++) {
            $null = & reg.exe unload "HKU\$n" 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 500; [GC]::Collect()
        }
        if ($LASTEXITCODE -ne 0) { Write-PhxLog -Level warn -Msg "Could not unload hive HKU\$n" }
    }
    $script:PhxMountedHives.Clear()
}

<#
 The interactive (console) user - who "current-user" means.
 When the lead (standard) user elevates through UAC with the admin's credentials,
 the engine runs AS the admin, so HKCU / $PROFILE / user env would be the admin's.
 Phoenix always targets the person at the keyboard instead.
 Returns @{ name; sid; profilePath; isSelf; source }.
#>
$script:PhxInteractiveUser = $null
function Get-PhxInteractiveUser {
    if ($script:PhxInteractiveUser) { return $script:PhxInteractiveUser }
    $selfId = [Security.Principal.WindowsIdentity]::GetCurrent()
    $selfSid = $selfId.User.Value
    $account = $null; $source = ''
    try { $account = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName; $source = 'console session' } catch { }
    if (-not $account) {
        try {
            $ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($ex) { $o = Invoke-CimMethod -InputObject $ex -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $account = "$($o.Domain)\$($o.User)"; $source = 'explorer.exe owner' } }
        } catch { }
    }
    $sid = $null
    if ($account) { try { $sid = (New-Object Security.Principal.NTAccount $account).Translate([Security.Principal.SecurityIdentifier]).Value } catch { } }
    if (-not $sid) { $sid = $selfSid; $account = $selfId.Name; $source = 'engine process (no interactive user found)' }
    $profPath = $null
    try { $profPath = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath } catch { }
    if (-not $profPath -and $sid -eq $selfSid) { $profPath = $env:USERPROFILE }
    $script:PhxInteractiveUser = @{ name = $account; sid = $sid; profilePath = $profPath; isSelf = ($sid -eq $selfSid); source = $source }
    $script:PhxInteractiveUser
}

# Registry root standing in for the interactive user's HKCU, or $null if it can't be loaded.
# Returns @{ root; hive; label }.
function Get-PhxInteractiveUserRoot {
    $u = Get-PhxInteractiveUser
    if ($u.isSelf) { return @{ root = 'Registry::HKEY_CURRENT_USER'; hive = ''; label = "interactive user $($u.name)" } }
    $file = if ($u.profilePath) { Join-Path $u.profilePath 'NTUSER.DAT' } else { '' }
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$($u.sid)") { return @{ root = "Registry::HKEY_USERS\$($u.sid)"; hive = $file; label = "interactive user $($u.name)" } }
    $m = if ($file) { Mount-PhxHive -File $file -Name ('Phx_' + $u.sid) } else { $null }
    @{ root = $m; hive = $file; label = "interactive user $($u.name)" }
}

# For user-scoped registry items: the hive roots to write to.
# Returns @( @{ label; root (provider path standing in for HKCU); hive (file or ''); available } )
function Get-PhxUserHiveTargets([string]$Scope) {
    $targets = New-Object System.Collections.Generic.List[object]
    if ($Scope -eq 'current-user') {
        $r = Get-PhxInteractiveUserRoot
        $targets.Add(@{ label = $r.label; root = $r.root; hive = $r.hive; available = [bool]$r.root })
        return , @($targets.ToArray())
    }
    $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    $m = Mount-PhxHive -File $defaultHive -Name 'PhxDefaultUser'
    $targets.Add(@{ label = 'default user'; root = $m; hive = $defaultHive; available = [bool]$m })
    if ($Scope -eq 'all-users') {
        $plRoot = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        foreach ($k in @(Get-ChildItem -LiteralPath $plRoot -ErrorAction SilentlyContinue)) {
            $sid = $k.PSChildName
            if ($sid -notlike 'S-1-5-21-*') { continue }
            $profPath = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            $user = if ($profPath) { Split-Path -Leaf $profPath } else { $sid }
            if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") {
                $targets.Add(@{ label = "user $user"; root = "Registry::HKEY_USERS\$sid"; hive = ''; available = $true })
            } else {
                $file = if ($profPath) { Join-Path $profPath 'NTUSER.DAT' } else { '' }
                $mm = if ($file) { Mount-PhxHive -File $file -Name ('Phx_' + $sid) } else { $null }
                $targets.Add(@{ label = "user $user"; root = $mm; hive = $file; available = [bool]$mm })
            }
        }
    }
    , @($targets.ToArray())
}

# HKCU:\Software\X -> (root)\Software\X
function Get-PhxUserSubPath([string]$Path) {
    $rp = ConvertTo-PhxRegPath $Path
    $prefix = 'Registry::HKEY_CURRENT_USER'
    if (-not $rp.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "User-scoped registry items must use an HKCU:\ path (got '$Path')." }
    $rp.Substring($prefix.Length).TrimStart('\')
}

# One registry write, planned or applied, across the item's scope.
function Invoke-PhxRegItem([hashtable]$Ctx, [string]$StepId, [string]$Path, [string]$Name, [string]$Type, $Value, [string]$Scope = 'machine', [string]$KeyPrefix = '') {
    if (-not $Scope) { $Scope = if ($Path -match '^(HKCU|HKEY_CURRENT_USER)') { 'current-user' } else { 'machine' } }
    $label = if ($KeyPrefix) { $KeyPrefix } else { "$Path\$Name" }
    if ($Scope -eq 'machine') {
        $cur = Get-PhxRegValue $Path $Name
        $tgt = Format-PhxRegValue (ConvertTo-PhxRegData $Type $Value)
        $curS = if ($cur.exists) { Format-PhxRegValue $cur.value } else { '(absent)' }
        $regPath = $Path; $regName = $Name; $regType = $Type; $regValue = $Value
        Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key $label -Current $curS -Target $tgt -AtTarget:(Test-PhxRegEqual $cur $Type $Value) -Do {
            Set-PhxRegValue -Path $regPath -Name $regName -Type $regType -Value $regValue
        }
        return
    }
    $sub = Get-PhxUserSubPath $Path
    foreach ($t in (Get-PhxUserHiveTargets $Scope)) {
        $k = "$label [$($t.label)]"
        if (-not $t.available) {
            Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key $k -Current '(unknown: hive not loaded, needs admin)' -Target $Value -Do {
                throw 'hive could not be loaded'
            }
            continue
        }
        $full = $t.root + '\' + $sub
        $cur = Get-PhxRegValue $full $Name
        $curS = if ($cur.exists) { Format-PhxRegValue $cur.value } else { '(absent)' }
        $regFull = $full; $regName = $Name; $regType = $Type; $regValue = $Value; $regHive = $t.hive; $regSub = $sub
        Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key $k -Current $curS -Target (Format-PhxRegValue (ConvertTo-PhxRegData $Type $Value)) -AtTarget:(Test-PhxRegEqual $cur $Type $Value) -Do {
            Set-PhxRegValue -Path $regFull -Name $regName -Type $regType -Value $regValue -Hive $regHive -SubPath $regSub
        }
    }
}

function Invoke-PhxStep_registry {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        try {
            $type = Get-PhxField $it 'type' 'DWord'
            $scope = Get-PhxField $it 'scope' ''
            Invoke-PhxRegItem -Ctx $Ctx -StepId $sid -Path $it['path'] -Name ([string]$it['name']) -Type $type -Value $it['value'] -Scope $scope -KeyPrefix ([string]$it['_key'])
        } catch {
            Write-PhxItemError $Ctx $sid ([string]$it['_key']) $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------- named settings
# Registry-only settings: name -> value -> list of @(path, name, type, data[, scope]).
$script:PhxRegSettings = @{
    'fast-startup'           = @{ off = @(, @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 'DWord', 0)); on = @(, @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 'DWord', 1)) }
    'crash-dump'             = @{ off = @(@('HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl', 'CrashDumpEnabled', 'DWord', 0), @('HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl', 'AlwaysKeepMemoryDump', 'DWord', 0)) }
    'remote-assistance'      = @{ off = @(@('HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance', 'fAllowToGetHelp', 'DWord', 0), @('HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance', 'fAllowFullControl', 'DWord', 0)) }
    'remote-desktop'         = @{ off = @(, @('HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server', 'fDenyTSConnections', 'DWord', 1)) }
    'device-install-from-wu' = @{ off = @(
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching', 'SearchOrderConfig', 'DWord', 0),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata', 'PreventDeviceMetadataFromNetwork', 'DWord', 1),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'ExcludeWUDriversInQualityUpdate', 'DWord', 1)) }
    'uac'                    = @{ 'always-notify' = @(
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableLUA', 'DWord', 1),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'ConsentPromptBehaviorAdmin', 'DWord', 2),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'ConsentPromptBehaviorUser', 'DWord', 1),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'PromptOnSecureDesktop', 'DWord', 1)) }
    'llmnr'                  = @{ off = @(, @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient', 'EnableMulticast', 'DWord', 0)) }
    'activity-history'       = @{ off = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableActivityFeed', 'DWord', 0),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'PublishUserActivities', 'DWord', 0),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'UploadUserActivities', 'DWord', 0)) }
    'search-web'             = @{ off = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'DisableWebSearch', 'DWord', 1),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWeb', 'DWord', 0),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowCloudSearch', 'DWord', 0),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 'DWord', 1),
            @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 'DWord', 1, 'current-user'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 'DWord', 0, 'current-user')) }
    'cross-device-share'     = @{ off = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableCdp', 'DWord', 0),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP', 'RomeSdkChannelUserAuthzPolicy', 'DWord', 0, 'current-user'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP', 'CdpSessionUserAuthzPolicy', 'DWord', 0, 'current-user')) }
    'game-dvr'               = @{ off = @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 'DWord', 0),
            @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 'DWord', 0, 'current-user')) }
    'network-throttling'     = @{ off = @(, @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'NetworkThrottlingIndex', 'DWord', '0xffffffff')) }
}

$script:PhxNamedSettings = @('pagefile', 'hibernate', 'time-server', 'netbios', 'task-history') + @($script:PhxRegSettings.Keys)

function Invoke-PhxStep_setting {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $items = Get-PhxEnabledItems $Step
    # A step may also be a single setting at step level: { kind: setting, setting: x, value: y }.
    if ($items.Count -eq 0 -and $Step.Contains('setting')) { $items = @(@{ setting = $Step['setting']; value = $Step['value']; _key = $Step['setting']; enabled = $true }) }
    foreach ($it in $items) {
        $name = [string]$it['setting']
        $value = [string]$it['value']
        try {
            switch ($name) {
                'pagefile' { Invoke-PhxSettingPagefile $Ctx $sid $value }
                'hibernate' { Invoke-PhxSettingHibernate $Ctx $sid $value }
                'time-server' { Invoke-PhxSettingTimeServer $Ctx $sid $value }
                'netbios' { Invoke-PhxSettingNetbios $Ctx $sid $value }
                'task-history' { Invoke-PhxSettingTaskHistory $Ctx $sid $value }
                default {
                    if (-not $script:PhxRegSettings.ContainsKey($name)) { throw "Unknown setting '$name'. Known: $($script:PhxNamedSettings -join ', ')" }
                    $def = $script:PhxRegSettings[$name]
                    if (-not $def.ContainsKey($value)) { throw "Setting '$name' does not support value '$value' (supported: $(@($def.Keys) -join ', '))" }
                    foreach ($r in $def[$value]) {
                        $scope = if ($r.Count -ge 5) { $r[4] } else { 'machine' }
                        Invoke-PhxRegItem -Ctx $Ctx -StepId $sid -Path $r[0] -Name $r[1] -Type $r[2] -Value $r[3] -Scope $scope -KeyPrefix "$name`: $($r[0])\$($r[1])"
                    }
                }
            }
        } catch {
            Write-PhxItemError $Ctx $sid "$name=$value" $_.Exception.Message
        }
    }
}

function Invoke-PhxSettingPagefile([hashtable]$Ctx, [string]$StepId, [string]$Value) {
    if ($Value -ne 'off') { throw "pagefile supports only 'off'" }
    $cs = Get-CimInstance Win32_ComputerSystem
    $pf = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
    $cur = if ($cs.AutomaticManagedPagefile) { 'system managed' } elseif ($pf.Count -gt 0) { 'custom: ' + (($pf | ForEach-Object { $_.Name }) -join ', ') } else { 'off' }
    Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key 'pagefile' -Current $cur -Target 'off' -AtTarget:($cur -eq 'off') -Msg 'takes effect after reboot' -Do {
        Add-PhxSnapshotRecord commands ([ordered]@{ label = 'pagefile'; undo = 'powershell.exe -NoProfile -Command "Set-CimInstance -InputObject (Get-CimInstance Win32_ComputerSystem) -Property @{AutomaticManagedPagefile=$true}"' })
        $csNow = Get-CimInstance Win32_ComputerSystem
        if ($csNow.AutomaticManagedPagefile) { Set-CimInstance -InputObject $csNow -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop }
        Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction Stop
        'pagefile disabled; takes effect after reboot'
    }
}

function Invoke-PhxSettingHibernate([hashtable]$Ctx, [string]$StepId, [string]$Value) {
    if ($Value -ne 'off') { throw "hibernate supports only 'off'" }
    $cur = Get-PhxRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $curS = if ($cur.exists -and [int]$cur.value -eq 0) { 'off' } elseif ($cur.exists) { 'on' } else { '(default: on)' }
    Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key 'hibernate' -Current $curS -Target 'off' -AtTarget:($curS -eq 'off') -Do {
        Add-PhxSnapshotRecord commands ([ordered]@{ label = 'hibernate'; undo = 'powercfg /hibernate on' })
        $o = & powercfg.exe /hibernate off 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg: $o" }
    }
}

function Invoke-PhxSettingTimeServer([hashtable]$Ctx, [string]$StepId, [string]$Value) {
    if (-not $Value) { throw 'time-server needs a host name' }
    $target = "$Value,0x8"
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    Invoke-PhxRegItem -Ctx $Ctx -StepId $StepId -Path $p -Name 'NtpServer' -Type 'String' -Value $target -KeyPrefix 'time-server: NtpServer'
    Invoke-PhxRegItem -Ctx $Ctx -StepId $StepId -Path $p -Name 'Type' -Type 'String' -Value 'NTP' -KeyPrefix 'time-server: Type'
    if ($Ctx.Mode -eq 'apply') {
        $null = & w32tm.exe /config "/manualpeerlist:$target" /syncfromflags:manual /update 2>&1
        if ($LASTEXITCODE -ne 0) { Write-PhxLog -Level warn -Msg 'w32tm /config failed (time service not running?); the registry values are set and apply at next service start.' }
    }
}

function Invoke-PhxSettingNetbios([hashtable]$Ctx, [string]$StepId, [string]$Value) {
    if ($Value -ne 'off') { throw "netbios supports only 'off'" }
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    $ifs = @(Get-ChildItem -LiteralPath (ConvertTo-PhxRegPath $root) -ErrorAction SilentlyContinue)
    if ($ifs.Count -eq 0) { Write-PhxChange -Step $StepId -Key 'netbios' -Current '(no interfaces)' -Target 'off' -Action skip -Msg 'no NetBT interfaces present (re-run after adding network hardware)'; $Ctx.Stats.skipped++; return }
    foreach ($i in $ifs) {
        Invoke-PhxRegItem -Ctx $Ctx -StepId $StepId -Path "$root\$($i.PSChildName)" -Name 'NetbiosOptions' -Type 'DWord' -Value 2 -KeyPrefix "netbios: $($i.PSChildName)"
    }
}

function Invoke-PhxSettingTaskHistory([hashtable]$Ctx, [string]$StepId, [string]$Value) {
    if ($Value -ne 'on') { throw "task-history supports only 'on'" }
    $log = 'Microsoft-Windows-TaskScheduler/Operational'
    $out = & wevtutil.exe gl $log 2>&1
    $cur = if (($out | Out-String) -match 'enabled:\s*true') { 'on' } elseif (($out | Out-String) -match 'enabled:\s*false') { 'off' } else { '(unknown)' }
    Invoke-PhxChange -Ctx $Ctx -Step $StepId -Key 'task-history' -Current $cur -Target 'on' -AtTarget:($cur -eq 'on') -Do {
        Add-PhxSnapshotRecord commands ([ordered]@{ label = 'task-history'; undo = "wevtutil sl $log /e:false" })
        $o = & wevtutil.exe sl $log /e:true 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wevtutil: $o" }
    }
}
