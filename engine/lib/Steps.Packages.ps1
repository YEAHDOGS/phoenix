# Phoenix engine: `devices`, `features` and `appx` step kinds.

# Devices Phoenix refuses to disable/remove unless the item sets "force": true.
# Disabling any of these can leave the machine unbootable, or break WMI/SMBIOS
# queries that Phoenix's own scan depends on.
$script:PhxProtectedDeviceIds = @(
    'ACPI\PNP0000*',          # Programmable interrupt controller
    'ACPI\PNP0A03*', 'ACPI\PNP0A08*', # PCI / PCIe root buses
    'ACPI_HAL\*', 'ROOT\ACPI_HAL\*',
    'ACPI\ACPI0007*', 'ACPI\GenuineIntel*', 'ACPI\AuthenticAMD*', # processors
    'ROOT\MSSMBIOS*',
    'ROOT\VOLMGR\*', 'ROOT\BASICDISPLAY\*', 'ROOT\BASICRENDER\*', 'ROOT\UMBUS\*'
)
$script:PhxProtectedDeviceNames = @(
    'Programmable interrupt controller', 'Microsoft System Management BIOS Driver', 'ACPI x64-based PC',
    'PCI Express Root Complex', 'PCI Express Root Port*', 'PCI bus', 'Volume Manager', 'Microsoft ACPI-Compliant System',
    'System CMOS/real time clock', 'High precision event timer', 'Composite Bus Enumerator', 'Plug and Play Software Device Enumerator',
    'Microsoft Basic Display Driver', 'Microsoft Basic Render Driver', 'Trusted Platform Module*'
)
# Device classes that may never be targeted by a class-only match without force.
$script:PhxProtectedDeviceClasses = @('System', 'Computer', 'Processor', 'DiskDrive', 'SCSIAdapter', 'HDC', 'Volume', 'VolumeSnapshot', 'SecurityDevices', 'Firmware', 'Keyboard', 'Mouse', 'HIDClass')

function Test-PhxDeviceProtected($Dev, $Match) {
    foreach ($p in $script:PhxProtectedDeviceIds) { if ($Dev.InstanceId -like $p) { return "protected device id ($p)" } }
    foreach ($n in $script:PhxProtectedDeviceNames) { if ($Dev.FriendlyName -like $n) { return "protected device ($n)" } }
    if ($Match.Contains('class') -and -not $Match.Contains('friendlyName') -and -not $Match.Contains('instanceId') -and $script:PhxProtectedDeviceClasses -contains [string]$Match['class']) {
        return "class-only match on protected class '$($Match['class'])'"
    }
    return $null
}

$script:PhxDeviceCache = $null
function Get-PhxAllDevices {
    if ($null -eq $script:PhxDeviceCache) { $script:PhxDeviceCache = @(Get-PnpDevice -ErrorAction SilentlyContinue) }
    $script:PhxDeviceCache
}

function Get-PhxDeviceState($Dev) {
    if (-not $Dev.Present) { return 'not present' }
    if ([int]$Dev.ConfigManagerErrorCode -eq 22) { return 'disabled' }
    return 'enabled'
}

function Invoke-PhxStep_devices {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $script:PhxDeviceCache = $null
    $all = Get-PhxAllDevices
    foreach ($it in (Get-PhxEnabledItems $Step)) {
        $key = [string]$it['_key']
        try {
            $m = $it['match']
            if (-not ($m -is [System.Collections.IDictionary]) -or $m.Count -eq 0) { throw 'item needs a "match" object (friendlyName, instanceId and/or class)' }
            $action = [string](Get-PhxField $it 'action' 'disable')
            if ('disable', 'remove' -notcontains $action) { throw "action must be disable or remove (got '$action')" }
            $includeHidden = [bool](Get-PhxField $it 'includeHidden' $true)
            $hits = @($all | Where-Object {
                    ($includeHidden -or $_.Present) -and
                    (-not $m.Contains('friendlyName') -or $_.FriendlyName -like [string]$m['friendlyName']) -and
                    (-not $m.Contains('instanceId') -or $_.InstanceId -like [string]$m['instanceId']) -and
                    (-not $m.Contains('class') -or $_.Class -like [string]$m['class'])
                })
            if ($hits.Count -eq 0) {
                Write-PhxChange -Step $sid -Key $key -Current '(no match)' -Target $action -Action skip -Msg 'no matching device on this machine'
                $Ctx.Stats.skipped++
                continue
            }
            $force = [bool](Get-PhxField $it 'force' $false)
            foreach ($d in $hits) {
                $label = "$($d.FriendlyName) [$($d.InstanceId)]"
                $state = Get-PhxDeviceState $d
                $why = Test-PhxDeviceProtected $d $m
                if ($why -and -not $force) {
                    Write-PhxChange -Step $sid -Key $label -Current $state -Target $action -Action skip -Msg "PROTECTED: $why"
                    $Ctx.Stats.skipped++
                    continue
                }
                $devId = $d.InstanceId; $devState = $state; $devName = $d.FriendlyName
                if ($action -eq 'disable') {
                    if ($state -eq 'not present') {
                        Write-PhxChange -Step $sid -Key $label -Current $state -Target 'disabled' -Action skip -Msg 'not present (use action remove to delete the stale entry)'
                        $Ctx.Stats.skipped++
                        continue
                    }
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $label -Current $state -Target 'disabled' -Action disable -AtTarget:($state -eq 'disabled') -Do {
                        Add-PhxSnapshotRecord devices ([ordered]@{ instanceId = $devId; name = $devName; action = 'disable'; wasEnabled = ($devState -eq 'enabled') })
                        $o = & pnputil.exe /disable-device "$devId" 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "pnputil /disable-device: $(($o | Out-String).Trim())" }
                    }
                } else {
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $label -Current $state -Target 'removed' -Action remove -Do {
                        Add-PhxSnapshotRecord nonRestorable ([ordered]@{ key = "device:$devId"; hint = "removed device '$devName'; present hardware comes back with 'pnputil /scan-devices'" })
                        $o = & pnputil.exe /remove-device "$devId" 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "pnputil /remove-device: $(($o | Out-String).Trim())" }
                    }
                }
            }
        } catch {
            Write-PhxItemError $Ctx $sid $key $_.Exception.Message
        }
    }
}

# Optional features Phoenix always keeps (overridable only with an explicit item action remove + force).
$script:PhxKeepFeatures = @('Windows-Defender-Default-Definitions', 'NetFx4-AdvSrvs', 'NetFx4Extended-ASPNET45')

function Get-PhxOptionalFeatures {
    # Win32_OptionalFeature reads without admin; InstallState 1 = enabled, 2 = disabled, 3 = absent.
    , @(Get-CimInstance Win32_OptionalFeature -ErrorAction Stop | ForEach-Object {
            @{ name = $_.Name; caption = $_.Caption; state = switch ([int]$_.InstallState) { 1 { 'Enabled' } 2 { 'Disabled' } 3 { 'Absent' } default { 'Unknown' } } }
        })
}

function Invoke-PhxStep_features {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $feats = Get-PhxOptionalFeatures
    $items = Get-PhxEnabledItems $Step
    $keep = @($script:PhxKeepFeatures) + @(Get-PhxField $Step 'keep' @()) + @($items | Where-Object { $_['action'] -eq 'keep' -and $_['type'] -ne 'capability' } | ForEach-Object { [string]$_['name'] })
    $explicitRemove = @($items | Where-Object { (Get-PhxField $_ 'action' 'remove') -eq 'remove' -and $_['type'] -ne 'capability' })

    $targets = New-Object System.Collections.Generic.List[object]
    if ([bool](Get-PhxField $Step 'removeAll' $false)) {
        foreach ($f in $feats) { if ($f.state -eq 'Enabled') { $targets.Add(@{ feature = $f; force = $false }) } }
    }
    foreach ($it in $explicitRemove) {
        $hits = @($feats | Where-Object { $_.name -like [string]$it['name'] })
        if ($hits.Count -eq 0) { Write-PhxChange -Step $sid -Key ([string]$it['name']) -Current '(not present)' -Target 'Disabled' -Action skip -Msg 'no such feature'; $Ctx.Stats.skipped++; continue }
        foreach ($h in $hits) { if (-not ($targets | Where-Object { $_.feature.name -eq $h.name })) { $targets.Add(@{ feature = $h; force = [bool](Get-PhxField $it 'force' $false) }) } }
    }
    foreach ($t in $targets) {
        $f = $t.feature
        $kept = $keep | Where-Object { $f.name -like $_ } | Select-Object -First 1
        if ($kept -and -not ($t.force -and $script:PhxKeepFeatures -notcontains $f.name)) {
            Write-PhxChange -Step $sid -Key $f.name -Current $f.state -Target $f.state -Action skip -Msg "kept ($kept)"
            $Ctx.Stats.skipped++
            continue
        }
        $fname = $f.name
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $fname -Current $f.state -Target 'Disabled' -Action disable -AtTarget:($f.state -ne 'Enabled') -Msg ([string]$f.caption) -Do {
            Add-PhxSnapshotRecord nonRestorable ([ordered]@{ key = "feature:$fname"; hint = "re-enable with Enable-WindowsOptionalFeature -Online -FeatureName $fname" })
            $r = Disable-WindowsOptionalFeature -Online -FeatureName $fname -NoRestart -ErrorAction Stop
            if ($r.RestartNeeded) { 'disabled; restart needed' }
        }
    }

    # Windows capabilities (step-level capabilities: true): only items with type capability are touched.
    $capItems = @($items | Where-Object { $_['type'] -eq 'capability' })
    if ([bool](Get-PhxField $Step 'capabilities' $false) -and $capItems.Count -gt 0) {
        $caps = $null
        if ($Ctx.IsAdmin) { try { $caps = @(Get-WindowsCapability -Online -ErrorAction Stop) } catch { $caps = $null } }
        foreach ($it in $capItems) {
            $pat = [string]$it['name']
            $act = [string](Get-PhxField $it 'action' 'remove')
            if ($act -eq 'keep') { continue }
            if ($null -eq $caps) {
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "capability:$pat" -Current '(unknown: needs admin)' -Target 'NotPresent' -Action remove -Do { throw 'capabilities cannot be enumerated' }
                continue
            }
            $hits = @($caps | Where-Object { $_.Name -like $pat })
            if ($hits.Count -eq 0) { Write-PhxChange -Step $sid -Key "capability:$pat" -Current '(not present)' -Target 'NotPresent' -Action skip; $Ctx.Stats.skipped++; continue }
            foreach ($c in $hits) {
                $cname = $c.Name
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "capability:$cname" -Current ([string]$c.State) -Target 'NotPresent' -Action remove -AtTarget:([string]$c.State -ne 'Installed') -Do {
                    Add-PhxSnapshotRecord nonRestorable ([ordered]@{ key = "capability:$cname"; hint = "reinstall with Add-WindowsCapability -Online -Name $cname (needs source media or network)" })
                    Remove-WindowsCapability -Online -Name $cname -ErrorAction Stop | Out-Null
                }
            }
        }
    }
}

# Packages that keep the shell, Settings, Defender UI and app runtimes alive.
$script:PhxProtectedAppx = @(
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'MicrosoftWindows.Client.CBS',
    'MicrosoftWindows.Client.Core', 'Microsoft.Windows.Search', 'windows.immersivecontrolpanel', 'Microsoft.SecHealthUI',
    'Microsoft.UI.Xaml*', 'Microsoft.VCLibs*', 'Microsoft.NET.Native*', 'Microsoft.WindowsAppRuntime*',
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.Windows.OOBENetworkConnectionFlow', 'Microsoft.LockApp',
    'Microsoft.Win32WebViewHost', 'Microsoft.Windows.ShellComponents', 'MicrosoftWindows.UndockedDevKit', 'Microsoft.WindowsAppSDK*'
)

function Test-PhxAppxMatch($Pkg, [string]$Pattern) {
    ($Pkg.Name -like $Pattern) -or ($Pkg.PackageFamilyName -like $Pattern) -or ($Pkg.PackageFullName -like $Pattern)
}

function Invoke-PhxStep_appx {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $items = Get-PhxEnabledItems $Step
    $keep = @($items | Where-Object { $_['action'] -eq 'keep' } | ForEach-Object { [string]$_['pattern'] })
    $installed = $null; $scopeNote = ''
    if ($Ctx.IsAdmin) {
        try { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $installed = $null }
    }
    if ($null -eq $installed) { $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue); $scopeNote = ' (current user only: run elevated for all users)' }
    $prov = @()
    if ($Ctx.IsAdmin) { try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { } }

    foreach ($it in @($items | Where-Object { (Get-PhxField $_ 'action' 'remove') -eq 'remove' })) {
        $pat = [string]$it['pattern']
        try {
            $force = [bool](Get-PhxField $it 'force' $false)
            $withProv = [bool](Get-PhxField $it 'provisioned' $true)
            $hits = @($installed | Where-Object { Test-PhxAppxMatch $_ $pat } | Sort-Object Name -Unique)
            $provHits = @($prov | Where-Object { $_.DisplayName -like $pat -or $_.PackageName -like $pat })
            if ($hits.Count -eq 0 -and $provHits.Count -eq 0) {
                Write-PhxChange -Step $sid -Key $pat -Current ('(not installed)' + $scopeNote) -Target 'removed' -Action skip
                $Ctx.Stats.skipped++
                continue
            }
            foreach ($p in $hits) {
                $pname = $p.Name
                $guard = $script:PhxProtectedAppx | Where-Object { $pname -like $_ } | Select-Object -First 1
                $kept = $keep | Where-Object { Test-PhxAppxMatch $p $_ } | Select-Object -First 1
                if (($guard -and -not $force) -or $kept) {
                    $why = if ($kept) { "kept ($kept)" } else { "PROTECTED ($guard): needed by the shell/Settings/Defender" }
                    Write-PhxChange -Step $sid -Key $pname -Current 'installed' -Target 'installed' -Action skip -Msg $why
                    $Ctx.Stats.skipped++
                    continue
                }
                if ($p.NonRemovable) {
                    Write-PhxChange -Step $sid -Key $pname -Current 'installed (non-removable)' -Target 'removed' -Action skip -Msg 'Windows marks this package non-removable'
                    $Ctx.Stats.skipped++
                    continue
                }
                $pfull = $p.PackageFullName
                Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $pname -Current ('installed ' + $p.Version + $scopeNote) -Target 'removed' -Action remove -Do {
                    Add-PhxSnapshotRecord nonRestorable ([ordered]@{ key = "appx:$pname"; hint = 'reinstall from the Store or the package source' })
                    Get-AppxPackage -AllUsers -Name $pname -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction Stop
                }
            }
            if ($withProv) {
                foreach ($pp in $provHits) {
                    $ppn = $pp.PackageName; $ppd = $pp.DisplayName
                    $guard = $script:PhxProtectedAppx | Where-Object { $ppd -like $_ } | Select-Object -First 1
                    if (($guard -and -not $force) -or ($keep | Where-Object { $ppd -like $_ })) { continue }
                    Invoke-PhxChange -Ctx $Ctx -Step $sid -Key "provisioned:$ppd" -Current 'provisioned' -Target 'removed' -Action remove -Do {
                        Remove-AppxProvisionedPackage -Online -PackageName $ppn -ErrorAction Stop | Out-Null
                    }
                }
            }
        } catch {
            Write-PhxItemError $Ctx $sid $pat $_.Exception.Message
        }
    }
}
