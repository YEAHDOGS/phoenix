<#
.SYNOPSIS
    Validation tests for the Phoenix answer-file generator (no Pester needed).

.DESCRIPTION
    Runs on Windows PowerShell 5.1+ / PowerShell 7. Checks that
    win-install/autounattend.template.xml is well-formed, credential-free,
    and token-complete, that the Schneegans password obfuscation in
    New-UnattendXml.ps1 reproduces the proven hashes, and that the generator
    end-to-end emits a well-formed, token-free answer file. Exits 0 on
    success, 1 on any failure.

.EXAMPLE
    .\tools\Test-UnattendXml.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passed = 0
$script:failed = 0
$script:failures = @()

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "PASS $Name"
    }
    else {
        $script:failed++
        $script:failures += $Name
        Write-Host "FAIL $Name $(if ($Detail) { "-- $Detail" })" -ForegroundColor Red
    }
}

$repoRoot     = Split-Path $PSScriptRoot -Parent
$templatePath = Join-Path $repoRoot 'win-install\autounattend.template.xml'
$genPath      = Join-Path $PSScriptRoot 'New-UnattendXml.ps1'
$unattendNs   = 'urn:schemas-microsoft-com:unattend'

Assert-True (Test-Path $templatePath -PathType Leaf) 'template file exists'
Assert-True (Test-Path $genPath -PathType Leaf) 'generator script exists'

# --- template: well-formed, passes, components ------------------------------
try {
    [xml]$xml = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
    Assert-True $true 'template is well-formed XML'
}
catch {
    Assert-True $false 'template is well-formed XML' $_.Exception.Message
    $xml = $null
}

if ($xml) {
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('u', $unattendNs)

    $passes = @($xml.SelectNodes('//u:settings', $ns) | ForEach-Object { $_.pass })
    foreach ($p in 'offlineServicing', 'windowsPE', 'generalize', 'specialize',
                   'auditSystem', 'auditUser', 'oobeSystem') {
        Assert-True ($passes -contains $p) "pass '$p' present"
    }

    Assert-True ($null -ne $xml.SelectSingleNode(
        "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']", $ns)) `
        'Microsoft-Windows-Setup in windowsPE'
    Assert-True ($null -ne $xml.SelectSingleNode(
        "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:UserAccounts", $ns)) `
        'UserAccounts in oobeSystem'
}

# --- template: tokens present, credentials absent ---------------------------
$raw = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
$requiredTokens = '{{COMPUTER_NAME}}', '{{PRODUCT_KEY}}', '{{TIME_ZONE}}',
    '{{EDITION_NAME}}', '{{ACCOUNT_NAME}}', '{{ACCOUNT_PASSWORD_B64}}',
    '{{STANDARD_ACCOUNT_XML}}', '{{ACCOUNT_PASSWORD}}',
    '{{STANDARD_ACCOUNT_NAME}}', '{{STANDARD_ACCOUNT_PASSWORD}}',
    '{{DEV_MODE_XML}}'
foreach ($t in $requiredTokens) {
    Assert-True ($raw.Contains($t)) "token $t present"
}

$forbidden = @(
    'BigMan',
    '123456789abcdefghi',
    'abcdefghi123456789',
    'MQAyADMANAA1ADYANwA4ADkAYQBiAGMAZABlAGYAZwBoAGkAUABhAHMAcwB3AG8AcgBkAA==',
    'YQBiAGMAZABlAGYAZwBoAGkAMQAyADMANAA1ADYANwA4ADkAUABhAHMAcwB3AG8AcgBkAA==',
    '>Main<',
    'Nightmare'
)
foreach ($f in $forbidden) {
    Assert-True (-not $raw.Contains($f)) "no dummy credential '$($f.Substring(0, [Math]::Min(24, $f.Length)))'"
}

# --- generator's obfuscation reproduces the proven hashes --------------------
$parseErrors = $null; $parseTokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $genPath, [ref]$parseTokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'generator parses with no syntax errors'

$fnAst = $ast.Find(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq 'Get-ObscuredUnattendPassword' }, $true)
Assert-True ($null -ne $fnAst) 'generator exposes Get-ObscuredUnattendPassword'
if ($fnAst) {
    Invoke-Expression $fnAst.Extent.Text
    Assert-True ((Get-ObscuredUnattendPassword '123456789abcdefghi') -eq
        'MQAyADMANAA1ADYANwA4ADkAYQBiAGMAZABlAGYAZwBoAGkAUABhAHMAcwB3AG8AcgBkAA==') `
        'obfuscation matches proven admin hash'
    Assert-True ((Get-ObscuredUnattendPassword 'abcdefghi123456789') -eq
        'YQBiAGMAZABlAGYAZwBoAGkAMQAyADMANAA1ADYANwA4ADkAUABhAHMAcwB3AG8AcgBkAA==') `
        'obfuscation matches proven standard-user hash'
}

# --- end-to-end: run the real generator into a temp dir ----------------------
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('phoenix-unattend-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpDir -Force
$outFile = Join-Path $tmpDir 'autounattend.xml'
try {
    $sec1 = ConvertTo-SecureString 'S3cret!Test' -AsPlainText -Force
    $sec2 = ConvertTo-SecureString 'G2pass!Test' -AsPlainText -Force

    & $genPath -ComputerName 'TEST-PC' -Username 'testadmin' -Password $sec1 `
        -StandardUsername 'testuser' -StandardPassword $sec2 `
        -OutputPath $outFile -Force
    Assert-True (Test-Path $outFile -PathType Leaf) 'generator wrote output file'

    $filled = Get-Content -LiteralPath $outFile -Raw -Encoding utf8
    Assert-True ($filled -notmatch '\{\{[A-Z_]+\}\}') 'no unfilled tokens remain'

    try {
        [xml]$fx = $filled
        Assert-True $true 'filled file is well-formed XML'
        $fns = New-Object Xml.XmlNamespaceManager($fx.NameTable)
        $fns.AddNamespace('u', $unattendNs)
        $cn = $fx.SelectSingleNode(
            "//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:ComputerName", $fns)
        Assert-True ($null -ne $cn -and $cn.InnerText -eq 'TEST-PC') 'ComputerName lands in specialize'
        $names = @($fx.SelectNodes('//u:LocalAccount/u:Name', $fns) | ForEach-Object { $_.InnerText })
        Assert-True (($names -join ',') -eq 'testadmin,testuser') 'both accounts present' ($names -join ',')
        $al = $fx.SelectSingleNode(
            "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:AutoLogon/u:Username", $fns)
        Assert-True ($null -ne $al -and $al.InnerText -eq 'testadmin') 'AutoLogon uses primary account'
        $tz = $fx.SelectSingleNode(
            "//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:TimeZone", $fns)
        Assert-True ($null -ne $tz -and $tz.InnerText -eq 'Central Standard Time') 'default timezone applied'
    }
    catch {
        Assert-True $false 'filled file is well-formed XML' $_.Exception.Message
    }

    Assert-True ($filled -match 'ComputerName=TEST-PC') 'Schneegans comment rewritten (ComputerName)'
    Assert-True ($filled -match 'AccountName0=testadmin') 'Schneegans comment rewritten (AccountName0)'

    # Single-account run: no standard user -> no AccountName1 in comment, no blank block.
    $outFile2 = Join-Path $tmpDir 'autounattend-single.xml'
    & $genPath -ComputerName 'SOLO-PC' -Username 'solo' -Password $sec1 `
        -OutputPath $outFile2 -Force
    $filled2 = Get-Content -LiteralPath $outFile2 -Raw -Encoding utf8
    Assert-True ($filled2 -notmatch 'AccountName1=') 'single-account: no AccountName1 in comment'
    Assert-True ($filled2 -notmatch '\{\{[A-Z_]+\}\}') 'single-account: no unfilled tokens'

    # Refuses to overwrite without -Force.
    $threw = $false
    try { & $genPath -ComputerName 'X' -Username 'y' -Password $sec1 -OutputPath $outFile }
    catch { $threw = $true }
    Assert-True $threw 'refuses to overwrite without -Force'

    # Invalid required param fails cleanly (no prompt, no partial write).
    $threw2 = $false
    try { & $genPath -ComputerName 'not a valid name!' -Username 'y' -Password $sec1 `
        -OutputPath (Join-Path $tmpDir 'x.xml') -Force }
    catch { $threw2 = $true }
    Assert-True $threw2 'invalid -ComputerName fails cleanly'
    Assert-True (-not (Test-Path (Join-Path $tmpDir 'x.xml'))) 'failed run writes no file'
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- staging dir is gitignored (best effort: needs git) ----------------------
if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $repoRoot
    try {
        git check-ignore -q 'win-install/staging/autounattend.xml'
        Assert-True ($LASTEXITCODE -eq 0) 'win-install/staging/ is gitignored'
    }
    finally { Pop-Location }
}
else {
    Write-Host 'SKIP win-install/staging/ is gitignored (git not on PATH)'
}

# --- summary -----------------------------------------------------------------
Write-Host ''
Write-Host "$($script:passed) passed, $($script:failed) failed."
if ($script:failed -gt 0) {
    Write-Host "Failures: $($script:failures -join '; ')" -ForegroundColor Red
    exit 1
}
