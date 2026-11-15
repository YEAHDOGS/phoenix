# Phoenix engine: `scan` - read-only machine inventory. Works without admin; notes what was limited.

function Invoke-PhxScan([hashtable]$A) {
    $notes = New-Object System.Collections.Generic.List[string]
    $isAdmin = Test-PhxIsAdmin
    $safe = {
        param([scriptblock]$Get, [string]$What)
        try { & $Get } catch { $notes.Add("$What unavailable: $($_.Exception.Message)"); $null }
    }

    $cs = & $safe { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } 'computer system'
    $bios = & $safe { Get-CimInstance Win32_BIOS -ErrorAction Stop } 'BIOS'
    $os = & $safe { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } 'OS'
    $enc = & $safe { Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop } 'enclosure'
    $portableTypes = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    $isPortable = [bool](@($enc.ChassisTypes) | Where-Object { $portableTypes -contains [int]$_ })

    $cpus = @(& $safe { Get-CimInstance Win32_Processor -ErrorAction Stop } 'CPU' | ForEach-Object { [ordered]@{ name = $_.Name.Trim(); cores = $_.NumberOfCores; threads = $_.NumberOfLogicalProcessors } })
    $gpus = @(& $safe { Get-CimInstance Win32_VideoController -ErrorAction Stop } 'GPU' | ForEach-Object { [ordered]@{ name = $_.Name; pnpDeviceId = $_.PNPDeviceID; driverVersion = $_.DriverVersion } })
    $disks = @(& $safe { Get-CimInstance Win32_DiskDrive -ErrorAction Stop } 'disks' | ForEach-Object {
            [ordered]@{ index = $_.Index; model = $_.Model; interface = $_.InterfaceType; mediaType = $_.MediaType; sizeBytes = [int64]$_.Size; serial = ([string]$_.SerialNumber).Trim() }
        })

    $nics = @(& $safe { Get-NetAdapter -IncludeHidden -ErrorAction Stop } 'network adapters' | ForEach-Object {
            $desc = [string]$_.InterfaceDescription
            [ordered]@{
                name = $_.Name; description = $desc; status = [string]$_.Status; mac = $_.MacAddress
                physical = [bool]$_.HardwareInterface; hidden = [bool]$_.Hidden
                wireless = ($desc -match 'Wi-?Fi|Wireless|802\.11|WLAN') -or ([string]$_.PhysicalMediaType -match '802\.11')
                pnpDeviceId = $_.PnPDeviceID
            }
        })

    $devs = @(& $safe { Get-PnpDevice -ErrorAction Stop } 'devices')
    $devices = @($devs | ForEach-Object {
            [ordered]@{
                name = $_.FriendlyName; class = $_.Class; instanceId = $_.InstanceId
                present = [bool]$_.Present; status = [string]$_.Status
                disabled = ([int]$_.ConfigManagerErrorCode -eq 22)
                manufacturer = $_.Manufacturer
            }
        })

    $services = @(& $safe { Get-CimInstance Win32_Service -ErrorAction Stop } 'services' | ForEach-Object {
            [ordered]@{ name = $_.Name; displayName = $_.DisplayName; startMode = $_.StartMode; state = $_.State; delayed = [bool]$_.DelayedAutoStart }
        })

    $features = @(& $safe { Get-PhxOptionalFeatures } 'optional features' | ForEach-Object { [ordered]@{ name = $_.name; caption = $_.caption; state = $_.state } })

    $appxRaw = $null
    if ($isAdmin) { $appxRaw = & $safe { Get-AppxPackage -AllUsers -ErrorAction Stop } 'appx (all users)' }
    if ($null -eq $appxRaw) { $appxRaw = @(Get-AppxPackage -ErrorAction SilentlyContinue); if (-not $isAdmin) { $notes.Add('appx: current user only (run elevated for all users)') } }
    $appx = @($appxRaw | ForEach-Object {
            [ordered]@{ name = $_.Name; version = [string]$_.Version; publisherId = $_.PublisherId; familyName = $_.PackageFamilyName; nonRemovable = [bool]$_.NonRemovable; isFramework = [bool]$_.IsFramework; signatureKind = [string]$_.SignatureKind }
        })

    $autoruns = @(Get-PhxAutorunEntries | ForEach-Object { [ordered]@{ name = $_.name; location = $_.location; command = $_.value } })
    $tasksAll = @(& $safe { Get-ScheduledTask -ErrorAction Stop } 'scheduled tasks')
    $tasksReady = @($tasksAll | Where-Object { [string]$_.State -ne 'Disabled' }).Count

    $secureBoot = 'unknown'
    try { $secureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'on' } else { 'off' } } catch { if (-not $isAdmin) { $notes.Add('Secure Boot state needs admin') } }
    $tpm = $null
    if ($isAdmin) { try { $t = Get-Tpm -ErrorAction Stop; $tpm = [ordered]@{ present = $t.TpmPresent; ready = $t.TpmReady } } catch { } } else { $notes.Add('TPM state needs admin') }
    if (-not $isAdmin) { $notes.Add('BitLocker state needs admin') }
    $bitlocker = $null
    if ($isAdmin) { try { $b = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; $bitlocker = [ordered]@{ status = [string]$b.VolumeStatus; protection = [string]$b.ProtectionStatus } } catch { } }
    $pagefile = $null
    try { $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop); $pagefile = [ordered]@{ automatic = [bool]$cs.AutomaticManagedPagefile; files = @($pf | ForEach-Object { $_.Name }) } } catch { }

    $ramBytes = if ($cs) { [int64]$cs.TotalPhysicalMemory } else { 0 }
    [ordered]@{
        scannedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        isAdmin      = $isAdmin
        computerName = $env:COMPUTERNAME
        manufacturer = $(if ($cs) { ([string]$cs.Manufacturer).Trim() } else { $null })
        model        = $(if ($cs) { ([string]$cs.Model).Trim() } else { $null })
        portable     = $isPortable
        bios         = $(if ($bios) { [ordered]@{ vendor = $bios.Manufacturer; version = $bios.SMBIOSBIOSVersion; serial = $bios.SerialNumber; date = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { $null }) } } else { $null })
        os           = $(if ($os) { [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; installDate = $(if ($os.InstallDate) { $os.InstallDate.ToString('s') } else { $null }) } } else { $null })
        cpu          = $cpus
        ramBytes     = $ramBytes
        gpus         = $gpus
        disks        = $disks
        nics         = $nics
        wifiPresent  = [bool]($nics | Where-Object { $_.wireless -and $_.physical })
        secureBoot   = $secureBoot
        tpm          = $tpm
        bitlocker    = $bitlocker
        pagefile     = $pagefile
        devices      = $devices
        hidden       = @($devices | Where-Object { -not $_.present }).Count
        services     = $services
        features     = $features
        appx         = $appx
        autoruns     = $autoruns
        autorunsCount = $autoruns.Count
        tasks        = [ordered]@{ total = $tasksAll.Count; enabled = $tasksReady }
        counts       = [ordered]@{
            devices = $devices.Count; hiddenDevices = @($devices | Where-Object { -not $_.present }).Count
            services = $services.Count; servicesRunning = @($services | Where-Object { $_.state -eq 'Running' }).Count
            featuresEnabled = @($features | Where-Object { $_.state -eq 'Enabled' }).Count
            appx = $appx.Count; autoruns = $autoruns.Count
        }
        notes        = @($notes.ToArray())
    }
}
