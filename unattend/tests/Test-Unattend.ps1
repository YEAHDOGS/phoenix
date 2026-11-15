<#
.SYNOPSIS
    Tests phoenix-unattend.exe and the engine's unattend commands. Read-only:
    everything is written to a temp folder; no system state is touched.

.DESCRIPTION
    Run on Windows PowerShell 5.1 (the engine's target) or PowerShell 7:
        powershell -NoProfile -ExecutionPolicy Bypass -File unattend\tests\Test-Unattend.ps1
    Requires unattend\bin\phoenix-unattend.exe (unattend\build.ps1).
    Exit code = number of failed checks.
#>
[CmdletBinding()]
param([string]$WorkDir)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent (Split-Path -Parent $here)
$exe = Join-Path $repo 'unattend\bin\phoenix-unattend.exe'
$engine = Join-Path $repo 'engine\phoenix.ps1'
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('phoenix-unattend-test-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
$script:failed = 0
$script:passed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r -eq $false) { throw 'returned false' }
        $script:passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Runs the exe; returns @{ code; out; err }.
function Invoke-Exe([string[]]$A) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($A | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $p = [Diagnostics.Process]::Start($psi)
    $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    @{ code = $p.ExitCode; out = $o; err = $e.Result }
}

# Runs an engine command; returns the result event.
function Invoke-Engine([string]$Command, [hashtable]$ArgsObj) {
    $argsPath = Join-Path $WorkDir ("args-" + [guid]::NewGuid().ToString('N') + '.json')
    ConvertTo-Json -InputObject $ArgsObj -Depth 10 | Set-Content -LiteralPath $argsPath -Encoding UTF8
    $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine $Command -ArgsPath $argsPath
    $results = @($lines | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.t -eq 'result' })
    if ($results.Count -ne 1) { throw "expected exactly one result event, got $($results.Count)" }
    $results[0]
}

function Read-Xml([string]$Path) { [xml](Get-Content -LiteralPath $Path -Raw) }
function XPath($Xml, [string]$Q) { @(Select-Xml -Xml $Xml -XPath $Q -Namespace $ns | ForEach-Object { $_.Node }) }

function New-Secrets([string]$Json) {
    $p = Join-Path $WorkDir ("secrets-" + [guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $p -Value $Json -Encoding ASCII
    $p
}

Write-Host "phoenix-unattend tests (PowerShell $($PSVersionTable.PSVersion), work dir $WorkDir)"
if (-not (Test-Path $exe)) { Write-Host "  FAIL  $exe missing; run unattend\build.ps1" -ForegroundColor Red; exit 1 }

# --- exe ---------------------------------------------------------------------
$schemaPath = Join-Path $WorkDir 'schema.json'
Check 'schema runs' {
    $r = Invoke-Exe @('schema'); if ($r.code -ne 0) { throw $r.err }
    [IO.File]::WriteAllText($schemaPath, $r.out)
}
$schema = Get-Content -Raw $schemaPath | ConvertFrom-Json
Check 'every Configuration param is in exactly one group, none in "other"' {
    $params = @($schema.types.Configuration.params | ForEach-Object { $_.name })
    $grouped = @($schema.groups | ForEach-Object { $_.params } | ForEach-Object { $_ })
    $missing = @($params | Where-Object { $grouped -notcontains $_ })
    $dupes = @($grouped | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($missing.Count) { throw "ungrouped: $($missing -join ', ')" }
    if ($dupes.Count) { throw "in several groups: $($dupes -join ', ')" }
    if (@($schema.groups | Where-Object { $_.id -eq 'other' }).Count) { throw 'an "other" group exists: new upstream params need a home in SchemaBuilder.Groups' }
    $params.Count -gt 60
}
Check 'every referenced type is described' {
    $prims = 'string', 'bool', 'int', 'number', 'color', 'bytes'
    $names = @($schema.types.PSObject.Properties | ForEach-Object { $_.Name })
    $bad = @()
    foreach ($t in $schema.types.PSObject.Properties) {
        foreach ($p in @($t.Value.params)) {
            if (-not $p) { continue }
            foreach ($ref in @($p.type, $p.keyType)) {
                if ($ref -and $prims -notcontains $ref -and $names -notcontains $ref) { $bad += "$($t.Name).$($p.name) -> $ref" }
            }
        }
        foreach ($i in @($t.Value.implementations)) { if ($i -and $names -notcontains $i) { $bad += "$($t.Name) impl $i" } }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
}
Check 'keyed lookups are populated' {
    foreach ($k in 'ImageLanguage', 'UserLocale', 'KeyboardIdentifier', 'GeoLocation', 'TimeOffset', 'Bloatware', 'WindowsEdition') {
        if (@($schema.types.$k.options).Count -lt 5) { throw "$k has too few options" }
    }
}

$defaultsPath = Join-Path $WorkDir 'defaults.json'
Check 'defaults runs and binds' {
    $r = Invoke-Exe @('defaults'); if ($r.code -ne 0) { throw $r.err }
    [IO.File]::WriteAllText($defaultsPath, $r.out)
}
Check 'defaults generate valid XML (with test passwords)' {
    $sec = New-Secrets '{"accounts":{"BigMan":"test-only-1","Main":"test-only-1"}}'
    $out = Join-Path $WorkDir 'defaults.xml'
    $r = Invoke-Exe @('generate', '--in', $defaultsPath, '--secrets', $sec, '--out', $out)
    if ($r.code -ne 0) { throw $r.err }
    $x = Read-Xml $out
    @(XPath $x '//u:LocalAccount').Count -eq 2
}
Check 'missing passwords are refused' {
    $r = Invoke-Exe @('generate', '--in', $defaultsPath, '--out', (Join-Path $WorkDir 'nopw.xml'))
    ($r.code -eq 1) -and ($r.err -like '*No password for*')
}
Check 'a partial DTO works' {
    $p = Join-Path $WorkDir 'partial.json'
    Set-Content -LiteralPath $p -Value '{ "DisableUac": true, "ComputerNameSettings": { "$type": "CustomComputerNameSettings", "Name": "PARTIAL-PC" } }'
    $out = Join-Path $WorkDir 'partial.xml'
    $r = Invoke-Exe @('generate', '--in', $p, '--out', $out)
    if ($r.code -ne 0) { throw $r.err }
    @(XPath (Read-Xml $out) '//u:ComputerName')[0].InnerText -eq 'PARTIAL-PC'
}
Check 'a bad $type gives a clean error with a path' {
    $p = Join-Path $WorkDir 'bad.json'
    Set-Content -LiteralPath $p -Value '{ "ComputerNameSettings": { "$type": "NoSuchSettings" } }'
    $r = Invoke-Exe @('generate', '--in', $p, '--out', (Join-Path $WorkDir 'bad.xml'))
    $e = $r.err | ConvertFrom-Json
    ($r.code -eq 1) -and ($e.path -eq '$.ComputerNameSettings.$type') -and ($e.error -like '*CustomComputerNameSettings*')
}
Check 'an unknown keyed id gives a clean error' {
    $p = Join-Path $WorkDir 'badkey.json'
    Set-Content -LiteralPath $p -Value '{ "TimeZoneSettings": { "$type": "ExplicitTimeZoneSettings", "TimeZone": "Mars Standard Time" } }'
    $r = Invoke-Exe @('generate', '--in', $p, '--out', (Join-Path $WorkDir 'badkey.xml'))
    ($r.code -eq 1) -and ($r.err -like '*Mars Standard Time*')
}
Check 'library validation errors surface (account name = computer name)' {
    $p = Join-Path $WorkDir 'collide.json'
    # The library's own defaults have interactive accounts, so give it one to collide with.
    Set-Content -LiteralPath $p -Value '{ "ComputerNameSettings": { "$type": "CustomComputerNameSettings", "Name": "BigMan" }, "AccountSettings": { "$type": "UnattendedAccountSettings", "Accounts": [ { "Name": "BigMan", "DisplayName": "", "Password": "x", "Group": "Administrators" } ], "AutoLogonSettings": { "$type": "OwnAutoLogonSettings" }, "ObscurePasswords": true } }'
    $r = Invoke-Exe @('generate', '--in', $p, '--out', (Join-Path $WorkDir 'collide.xml'), '--allow-empty-passwords')
    ($r.code -eq 1) -and ($r.err -like '*must not be the same as the computer name*')
}
Check 'defaults DTO round-trips (schema defaults bind)' {
    $p = Join-Path $WorkDir 'lib-defaults.json'
    ConvertTo-Json -InputObject $schema.defaults -Depth 40 | Set-Content -LiteralPath $p
    $r = Invoke-Exe @('generate', '--in', $p, '--out', (Join-Path $WorkDir 'lib-defaults.xml'))
    $r.code -eq 0
}

# --- engine ------------------------------------------------------------------
Check 'engine unattend-schema' {
    $r = Invoke-Engine 'unattend-schema' @{}
    $r.ok -and $r.data.root -eq 'Configuration'
}
Check 'engine unattend-defaults' {
    $r = Invoke-Engine 'unattend-defaults' @{}
    $r.ok -and $r.data.AccountSettings.'$type' -eq 'UnattendedAccountSettings'
}

$cfgSrc = Join-Path $repo 'config\phoenix.example.json'
$cfg = if (Test-Path $cfgSrc) { Get-Content -Raw $cfgSrc | ConvertFrom-Json } else {
    [pscustomobject]@{ schema = 1; machine = [pscustomobject]@{ computerName = 'THE-MACHINE'; timeZone = 'Central Standard Time'; edition = 'Windows 11 Pro'; diskNumber = 0 }
        accounts = [pscustomobject]@{ admin = @{ name = 'BigMan' }; lead = @{ name = 'Main' }; users = @() } }
}
$cfg.accounts.users = @(@{ name = 'Kid' }, @{ name = 'Guest2' })
$cfgPath = Join-Path $WorkDir 'phoenix.config.json'
$cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

$xmlPath = Join-Path $WorkDir 'phoenix.xml'
$sec = New-Secrets '{"admin":"test-only-1","lead":"test-only-1","users":{"Kid":"test-only-1","Guest2":"test-only-1"}}'
$result = $null
Check 'engine unattend generates from the profile' {
    $script:result = Invoke-Engine 'unattend' @{ configPath = $cfgPath; secretsPath = $sec; outPath = $xmlPath }
    if (-not $script:result.ok) { throw $script:result.data.error }
    $true
}
Check 'secrets file was deleted' { -not (Test-Path -LiteralPath $sec) }
$x = Read-Xml $xmlPath
Check 'admin is in Administrators and auto-logs on once' {
    $admin = @(XPath $x '//u:LocalAccount') | Where-Object { $_.Name -eq $cfg.accounts.admin.name }
    ($admin.Group -eq 'Administrators') -and (@(XPath $x '//u:AutoLogon/u:Username')[0].InnerText -eq $cfg.accounts.admin.name) -and (@(XPath $x '//u:AutoLogon/u:LogonCount')[0].InnerText -eq '1')
}
Check 'lead and extra users are in Users' {
    $users = @(@(XPath $x '//u:LocalAccount') | Where-Object { $_.Group -eq 'Users' } | ForEach-Object { $_.Name })
    ($users -contains $cfg.accounts.lead.name) -and ($users -contains 'Kid') -and ($users -contains 'Guest2')
}
Check 'computer name and time zone come from the profile' {
    (@(XPath $x '//u:ComputerName')[0].InnerText -eq $cfg.machine.computerName) -and (@(XPath $x '//u:TimeZone')[0].InnerText -eq $cfg.machine.timeZone)
}
Check 'FirstLogon handoff is embedded, parses, and runs before unattend.xml is deleted' {
    $files = $x.unattend.Extensions.File
    $handoff = $files | Where-Object { $_.'#text' -like '*phoenix-handoff*' }
    if (-not $handoff) { throw 'no handoff script' }
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput($handoff.'#text', [ref]$null, [ref]$errs)
    if ($errs.Count) { throw "parse errors: $($errs[0].Message)" }
    $fl = ($files | Where-Object { $_.path -like '*\FirstLogon.ps1' }).'#text'
    $call = $fl.IndexOf((Split-Path -Leaf $handoff.path))
    $delete = $fl.IndexOf('Panther\unattend.xml')
    ($call -ge 0) -and ($delete -gt $call) -and ($handoff.'#text' -like '*Wait-Process*')
}
Check 'no plaintext test password in the XML' { -not ((Get-Content -Raw $xmlPath).Contains('test-only-1')) }
Check 'user DTO overrides are respected (explicit ComputerNameSettings wins)' {
    $cfg2 = Get-Content -Raw $cfgPath | ConvertFrom-Json
    $cfg2 | Add-Member -NotePropertyName unattend -NotePropertyValue ([pscustomobject]@{ ComputerNameSettings = [pscustomobject]@{ '$type' = 'RandomComputerNameSettings' }; DisableUac = $true })
    $p2 = Join-Path $WorkDir 'cfg2.json'; $cfg2 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $p2 -Encoding UTF8
    $out2 = Join-Path $WorkDir 'phoenix2.xml'
    $s2 = New-Secrets '{"admin":"test-only-1","lead":"test-only-1","users":{"Kid":"test-only-1","Guest2":"test-only-1"}}'
    $r = Invoke-Engine 'unattend' @{ configPath = $p2; secretsPath = $s2; outPath = $out2 }
    if (-not $r.ok) { throw $r.data.error }
    $x2 = Read-Xml $out2
    # RandomComputerNameSettings omits <ComputerName>; the profile's name must not have been forced in.
    (@(XPath $x2 '//u:ComputerName').Count -eq 0) -and ($x2.OuterXml.Contains('phoenix.id'))
}
Check 'missing passwords fail through the engine' {
    $s3 = New-Secrets '{"admin":"test-only-1"}'
    $r = Invoke-Engine 'unattend' @{ configPath = $cfgPath; secretsPath = $s3; outPath = (Join-Path $WorkDir 'nopw2.xml') }
    (-not $r.ok) -and ($r.data.error -like '*No password for*')
}

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed" -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
exit $script:failed
