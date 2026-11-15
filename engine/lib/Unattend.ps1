# Phoenix engine: answer files, via the Schneegans unattend-generator.
#
# Commands: unattend-schema, unattend-defaults, unattend.
# The generator is the MIT library behind schneegans.de, vendored at
# third_party/unattend-generator and wrapped by unattend/ (phoenix-unattend.exe).
# See docs/ARCHITECTURE.md, "Answer file: Schneegans generator, wrapped".

# Marker so the handoff script is added once, even if a saved DTO already has it.
$script:PhxHandoffMarker = '# phoenix-handoff v1'

function Find-PhxUnattendExe {
    $candidates = @(
        $env:PHOENIX_UNATTEND_EXE
        (Join-Path (Get-PhxKitRoot) 'unattend\bin\phoenix-unattend.exe')
        (Join-Path (Get-PhxKitRoot) 'unattend\phoenix-unattend.exe')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }
    throw "phoenix-unattend.exe not found (looked in: $($candidates -join '; ')). Build it with: powershell -File unattend\build.ps1"
}

# Runs phoenix-unattend.exe; returns @{ code; stdout; stderr }. Uses Process
# directly because Windows PowerShell 5.1 mangles native stderr into ErrorRecords.
function Invoke-PhxUnattendExe([string[]]$Arguments) {
    $exe = Find-PhxUnattendExe
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    @{ code = $p.ExitCode; stdout = $out; stderr = $errTask.Result }
}

function Invoke-PhxUnattendJson([string[]]$Arguments) {
    $r = Invoke-PhxUnattendExe $Arguments
    if ($r.code -ne 0) {
        $msg = $r.stderr.Trim()
        try {
            $e = $msg | ConvertFrom-Json
            $msg = if ($e.path) { "$($e.error) (at $($e.path))" } else { $e.error }
        } catch { }
        throw "Answer-file generator failed: $msg"
    }
    $r.stdout | ConvertFrom-Json
}

function Invoke-PhxUnattendSchema([hashtable]$A) { Invoke-PhxUnattendJson @('schema') }

function Invoke-PhxUnattendDefaults([hashtable]$A) { Invoke-PhxUnattendJson @('defaults') }

# --- DTO helpers (hashtables from ConvertTo-PhxHashtable) --------------------

function Get-PhxDtoKey($Obj, [string]$Name) {
    if ($null -eq $Obj -or $Obj -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($k in @($Obj.Keys)) { if ($k -ieq $Name) { return $k } }
    return $null
}

function Test-PhxDtoSet($Obj, [string]$Name) { $null -ne (Get-PhxDtoKey $Obj $Name) }

function Get-PhxDtoValue($Obj, [string]$Name) {
    $k = Get-PhxDtoKey $Obj $Name
    if ($null -eq $k) { return $null }
    $Obj[$k]
}

function Set-PhxDtoValue($Obj, [string]$Name, $Value) {
    $k = Get-PhxDtoKey $Obj $Name
    if ($null -eq $k) { $k = $Name }
    $Obj[$k] = $Value
}

# Same semantics as the wrapper's DtoMerge: overlay wins; objects whose $type
# differs replace wholesale; arrays and scalars replace.
function Merge-PhxDto($Base, $Overlay) {
    if ($Overlay -is [System.Collections.IDictionary] -and $Base -is [System.Collections.IDictionary]) {
        $bt = Get-PhxDtoValue $Base '$type'
        $ot = Get-PhxDtoValue $Overlay '$type'
        if ($ot -and ($bt -ne $ot)) { return $Overlay }
        $result = @{}
        foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
        foreach ($k in $Overlay.Keys) {
            $existingKey = Get-PhxDtoKey $result $k
            if ($null -ne $existingKey) {
                $merged = Merge-PhxDto $result[$existingKey] $Overlay[$k]
                $result.Remove($existingKey)
                $result[$k] = $merged
            } else {
                $result[$k] = $Overlay[$k]
            }
        }
        return $result
    }
    return $Overlay
}

# FirstLogon handoff. Runs inside the generator's FirstLogon.ps1. It must NOT
# run the admin phase synchronously: the generator deletes unattend.xml (which
# holds the account passwords) in a FirstLogon step that comes after custom
# scripts, and the admin phase ends by powering off. So it starts a detached
# PowerShell that waits for FirstLogon.ps1 to finish, then runs the phase.
function Get-PhxHandoffScript {
    @"
$($script:PhxHandoffMarker)
# Finds the Phoenix USB (\phoenix\phoenix.id), installs the kit to
# C:\ProgramData\Phoenix\kit and starts phase 'admin' once Windows Setup's
# own FirstLogon steps are done. Never fails setup: everything is logged.
`$ErrorActionPreference = 'Continue';
`$data = 'C:\ProgramData\Phoenix';
`$logs = Join-Path `$data 'logs';
New-Item -ItemType Directory -Force -Path `$logs | Out-Null;
`$log = Join-Path `$logs 'firstlogon.log';
function Write-HandoffLog([string]`$m) { Add-Content -LiteralPath `$log -Value ('{0:s} {1}' -f (Get-Date), `$m); };
try {
  `$usb = Get-PSDrive -PSProvider FileSystem | Where-Object { `$_.Root -and (Test-Path -LiteralPath (Join-Path `$_.Root 'phoenix\phoenix.id')) } | Select-Object -First 1;
  if (-not `$usb) { Write-HandoffLog 'Phoenix USB not found (no \phoenix\phoenix.id on any drive). Nothing to do.'; return; };
  `$src = Join-Path `$usb.Root 'phoenix';
  `$kit = Join-Path `$data 'kit';
  Write-HandoffLog "Phoenix USB at `$(`$usb.Root). Copying kit to `$kit.";
  robocopy.exe `$src `$kit /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null;
  if (`$LASTEXITCODE -ge 8) { Write-HandoffLog "robocopy failed with exit code `$LASTEXITCODE."; return; };
  `$argsPath = Join-Path `$data 'firstlogon-args.json';
  `$cfg = Join-Path `$kit 'phoenix.config.json';
  ConvertTo-Json -InputObject @{ phase = 'admin'; unattended = `$true; configPath = `$cfg } | Set-Content -LiteralPath `$argsPath -Encoding UTF8;
  `$engine = Join-Path `$kit 'engine\phoenix.ps1';
  `$runLog = Join-Path `$logs 'firstlogon-admin.ndjson';
  `$runner = "Wait-Process -Id `$PID -ErrorAction SilentlyContinue; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '`$engine' apply -ArgsPath '`$argsPath' -LogPath '`$runLog'";
  Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', `$runner) -WindowStyle Normal;
  Write-HandoffLog "Phase 'admin' scheduled to start when FirstLogon finishes. Log: `$runLog";
} catch {
  Write-HandoffLog "Handoff error: `$(`$_.Exception.Message)";
};
"@
}

function Test-PhxHasHandoff($Scripts) {
    foreach ($s in @($Scripts)) {
        $c = Get-PhxDtoValue $s 'Content'
        if ($c -and $c.Contains($script:PhxHandoffMarker)) { return $true }
    }
    return $false
}

# Builds the final DTO: Phoenix defaults <- config.unattend <- Phoenix additions.
function Get-PhxUnattendDto([hashtable]$Config, [System.Collections.Generic.List[string]]$Warnings) {
    $defaults = ConvertTo-PhxHashtable (Invoke-PhxUnattendDefaults @{})
    $user = $Config['unattend']
    $dto = if ($user -is [System.Collections.IDictionary]) { Merge-PhxDto $defaults $user } else { $defaults }
    $m = $Config['machine']
    if (-not $m) { $m = @{} }

    # Machine fields, unless the user's DTO sets them explicitly.
    if ($m['computerName'] -and -not (Test-PhxDtoSet $user 'ComputerNameSettings')) {
        Set-PhxDtoValue $dto 'ComputerNameSettings' @{ '$type' = 'CustomComputerNameSettings'; 'Name' = [string]$m['computerName'] }
    }
    if ($m['timeZone'] -and -not (Test-PhxDtoSet $user 'TimeZoneSettings')) {
        Set-PhxDtoValue $dto 'TimeZoneSettings' @{ '$type' = 'ExplicitTimeZoneSettings'; 'TimeZone' = [string]$m['timeZone'] }
    }
    if (-not (Test-PhxDtoSet $user 'LanguageSettings')) {
        $lang = Get-PhxDtoValue $dto 'LanguageSettings'
        if ((Get-PhxDtoValue $lang '$type') -eq 'UnattendedLanguageSettings') {
            if ($m['uiLanguage']) { Set-PhxDtoValue $lang 'ImageLanguage' ([string]$m['uiLanguage']) }
            $lk = Get-PhxDtoValue $lang 'LocaleAndKeyboard'
            if ($m['userLocale']) { Set-PhxDtoValue $lk 'Locale' ([string]$m['userLocale']) }
            if ($m['inputLocale']) {
                # Windows input locale '0409:00000409' -> keyboard identifier '00000409'.
                $kb = ([string]$m['inputLocale']).Split(':')[-1]
                Set-PhxDtoValue $lk 'Keyboard' $kb
            }
            if ($m['systemLocale'] -and $m['systemLocale'] -ne $m['userLocale']) {
                $Warnings.Add("machine.systemLocale '$($m['systemLocale'])' has no separate setting in the generator; userLocale '$($m['userLocale'])' is used for both.")
            }
        }
    }
    if (-not (Test-PhxDtoSet $user 'PESettings')) {
        $pe = Get-PhxDtoValue $dto 'PESettings'
        if ((Get-PhxDtoValue $pe '$type') -eq 'GeneratePESettings') {
            if ($m['edition']) {
                Set-PhxDtoValue $pe 'InstallFromSettings' @{ '$type' = 'NameInstallFromSettings'; 'Name' = [string]$m['edition'] }
            }
            if ($null -ne $m['diskNumber']) {
                $part = Get-PhxDtoValue $pe 'PartitionSettings'
                if ((Get-PhxDtoValue $part '$type') -eq 'UnattendedPartitionSettings') {
                    Set-PhxDtoValue $part 'TargetDiskSettings' @{ '$type' = 'FixedTargetDiskSettings'; 'Index' = [int]$m['diskNumber'] }
                }
            }
        }
    }
    if ($m['productKey'] -and -not (Test-PhxDtoSet $user 'ActivationKey')) {
        Set-PhxDtoValue $dto 'ActivationKey' @{ 'Value' = [string]$m['productKey'] }
    }

    # Accounts from the profile: admin (Administrators, auto-logon once), lead + users (Users).
    $fromProfile = -not ($Config['unattendAccountsFromProfile'] -eq $false -and (Test-PhxDtoSet $user 'AccountSettings'))
    $acc = $Config['accounts']
    if ($fromProfile -and $acc) {
        $list = New-Object System.Collections.ArrayList
        $adminName = if ($acc['admin']) { [string]$acc['admin']['name'] } else { '' }
        if (-not $adminName) { throw 'config.accounts.admin.name is required.' }
        [void]$list.Add(@{ Name = $adminName; DisplayName = ''; Password = ''; Group = 'Administrators' })
        if ($acc['lead'] -and $acc['lead']['name']) {
            [void]$list.Add(@{ Name = [string]$acc['lead']['name']; DisplayName = ''; Password = ''; Group = 'Users' })
        }
        foreach ($u in @($acc['users'])) {
            if ($u -and $u['name']) { [void]$list.Add(@{ Name = [string]$u['name']; DisplayName = ''; Password = ''; Group = 'Users' }) }
        }
        $existing = Get-PhxDtoValue $dto 'AccountSettings'
        $obscure = Get-PhxDtoValue $existing 'ObscurePasswords'
        if ($null -eq $obscure) { $obscure = $true }
        Set-PhxDtoValue $dto 'AccountSettings' @{
            '$type'             = 'UnattendedAccountSettings'
            'Accounts'          = @($list.ToArray())
            'AutoLogonSettings' = @{ '$type' = 'OwnAutoLogonSettings' }
            'ObscurePasswords'  = [bool]$obscure
        }
    }

    # FirstLogon handoff, always (once).
    $ss = Get-PhxDtoValue $dto 'ScriptSettings'
    if (-not $ss) { $ss = @{ Scripts = @(); RestartExplorer = $false }; Set-PhxDtoValue $dto 'ScriptSettings' $ss }
    $scripts = @(Get-PhxDtoValue $ss 'Scripts' | Where-Object { $_ })
    if (-not (Test-PhxHasHandoff $scripts)) {
        $scripts += @{ Content = (Get-PhxHandoffScript); Phase = 'FirstLogon'; Type = 'Ps1' }
    }
    Set-PhxDtoValue $ss 'Scripts' @($scripts)

    $auto = Get-PhxDtoValue (Get-PhxDtoValue $dto 'AccountSettings') 'AutoLogonSettings'
    if ((Get-PhxDtoValue $auto '$type') -eq 'NoneAutoLogonSettings') {
        $Warnings.Add('Auto-logon is off: the FirstLogon handoff only runs when someone logs on, and Windows keeps unattend.xml until then.')
    }
    $dto
}

# Secrets in either Phoenix shape { admin, lead, users: { name: pw } } or the
# wrapper's { accounts: { name: pw }, wifi }. Returns the wrapper's shape.
function ConvertTo-PhxUnattendSecrets([hashtable]$Config, $Secrets) {
    $out = @{ accounts = @{} }
    if (-not $Secrets) { return $out }
    if ($Secrets['accounts'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Secrets['accounts'].Keys) { $out.accounts[$k] = [string]$Secrets['accounts'][$k] }
    }
    $acc = $Config['accounts']
    if ($acc) {
        if ($Secrets['admin'] -and $acc['admin']) { $out.accounts[[string]$acc['admin']['name']] = [string]$Secrets['admin'] }
        if ($Secrets['lead'] -and $acc['lead']) { $out.accounts[[string]$acc['lead']['name']] = [string]$Secrets['lead'] }
    }
    if ($Secrets['users'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Secrets['users'].Keys) { $out.accounts[$k] = [string]$Secrets['users'][$k] }
    }
    if ($Secrets['wifi']) { $out['wifi'] = [string]$Secrets['wifi'] }
    $out
}

function Invoke-PhxUnattend([hashtable]$A) {
    if (-not $A['outPath']) { throw 'unattend: outPath is required.' }
    # Read (and delete) the secrets first, so they never outlive this call.
    $secrets = Read-PhxSecrets $A['secretsPath']
    $config = Get-PhxConfig $A['configPath']
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    $dto = Get-PhxUnattendDto $config $warnings
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('phoenix-unattend-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $dtoPath = Join-Path $tmpDir 'dto.json'
    $secPath = Join-Path $tmpDir 'secrets.json'
    try {
        Write-PhxJson $dtoPath $dto 40
        Write-PhxJson $secPath (ConvertTo-PhxUnattendSecrets $config $secrets)
        Write-PhxLog "Generating answer file with the Schneegans generator."
        $outFull = [IO.Path]::GetFullPath($A['outPath'])
        $r = Invoke-PhxUnattendJson @('generate', '--in', $dtoPath, '--secrets', $secPath, '--out', $outFull)
        foreach ($w in @($r.warnings)) { if ($w) { $warnings.Add([string]$w) } }

        # Belt and braces: the result must be XML and carry the handoff.
        [xml]$xml = Get-Content -LiteralPath $outFull -Raw
        if (-not ($xml.OuterXml.Contains('phoenix.id'))) { throw 'Generated answer file is missing the Phoenix FirstLogon handoff.' }

        [ordered]@{
            outPath  = $outFull
            sha256   = (Get-PhxSha $outFull 'SHA256')
            bytes    = (Get-Item -LiteralPath $outFull).Length
            accounts = @($r.accounts | ForEach-Object { $_.name })
            warnings = @($warnings)
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
