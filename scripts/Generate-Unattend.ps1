<#
.SYNOPSIS
    Generates a Phoenix autounattend.xml answer file from the tokenized template.

.DESCRIPTION
    Headless/automation entry point for the Phoenix one-step flow (wipe ->
    plug in Phoenix USB -> answer file + app picker applied). Fills
    win-install/autounattend.template.xml (credential-free, safe to commit)
    with machine identity, locale/keyboard, local accounts, timezone, edition
    and product key, and writes the filled file to win-install/staging/
    (gitignored -- the filled file carries real local-account passwords, and
    the unattend format requires them; even the "obscured" form is reversible).

    Cross-platform twin of scripts/generate_unattend.py: the same options
    schema and the same substitution algorithm, byte-identical output for the
    same inputs (see tests/unattend/test-ps1-py-parity.sh). The Svelte+Tauri
    config GUI drives either one headlessly via -OptionsJson.

    This is the GUI/automation generator. tools/New-UnattendXml.ps1 (on the
    jack/phoenix-unattend-gen branch) is the classic interactive CLI; both
    fill the same template.

.PARAMETER ComputerName
    NetBIOS computer name, 1-15 chars (letters, digits, hyphens).

.PARAMETER Username
    Primary local account. Created in Administrators and used for AutoLogon
    (single logon, like the proven template).

.PARAMETER Password
    Password for the primary account, as a SecureString. Omit it and you get
    a masked prompt (Read-Host -AsSecureString) -- no plaintext args, no
    shell history. NEVER empty or default credentials.

.PARAMETER StandardUsername
    Optional second local account (Users group). Omit for single-account.

.PARAMETER StandardPassword
    Password for the standard account, as a SecureString. Prompted when
    -StandardUsername is given but no password is supplied.

.PARAMETER TimeZone
    Windows timezone ID. Default: 'Central Standard Time'.

.PARAMETER Edition
    Image name passed to dism /Apply-Image (/Name:"..."). Default:
    'Windows 11 Pro'. Must match an image name in install.wim/esd.

.PARAMETER ProductKey
    Setup product key. Default is Microsoft's public generic Windows 11 Pro
    key (VK7JG-NPHTM-C97JM-9MPGT-3V66T) -- not a license, just lets setup run
    unattended. Supply a real key here if you have one.

.PARAMETER InputLocale
    Keyboard layout ID. Default: '0409:00000409' (US).

.PARAMETER SystemLocale
    Default: 'en-001'.

.PARAMETER UILanguage
    Default: 'en-US'.

.PARAMETER UserLocale
    Default: 'en-001'.

.PARAMETER TelemetryLevel
    'Off' (default) injects AllowTelemetry=0 reg blocks into the embedded
    Specialize.ps1; 'Basic' leaves the template untouched.

.PARAMETER GeneratedAt
    Stamp override, UTC 'yyyy-MM-ddTHH:mm:ssZ'. Defaults to now; the parity
    test fixes it so PS1 and py emit byte-identical files.

.PARAMETER OptionsJson
    JSON options file with the same schema (the Tauri GUI path). Explicitly
    bound CLI parameters win; the file fills the rest. The file may carry a
    plaintext "password" -- keep it out of the repo, same as the output.

.PARAMETER TemplatePath
    Defaults to win-install/autounattend.template.xml next to this script.

.PARAMETER OutputPath
    Defaults to win-install/staging/autounattend.xml (gitignored). Override
    only if you know what you are doing.

.PARAMETER Force
    Overwrite the output file if it already exists.

.EXAMPLE
    .\scripts\Generate-Unattend.ps1 -ComputerName NIGHTMARE -Username brando
    Prompts for the password, writes win-install/staging/autounattend.xml.

.EXAMPLE
    .\scripts\Generate-Unattend.ps1 -OptionsJson C:\Phoenix\machine.json -Force
    Headless run: everything comes from the JSON file the GUI wrote.

.NOTES
    Requires Windows PowerShell 5.1+ / PowerShell 7. No network access, no
    external modules -- everything is local string/XML work.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-]{0,14}$')]
    [string]$ComputerName,

    [Parameter()]
    [string]$Username,

    [Parameter()]
    [SecureString]$Password,

    [Parameter()]
    [string]$StandardUsername = '',

    [Parameter()]
    [SecureString]$StandardPassword,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TimeZone = 'Central Standard Time',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ $_ -notmatch '["\r\n]' })]
    [string]$Edition = 'Windows 11 Pro',

    [Parameter()]
    [ValidatePattern('^(?i)[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$')]
    [string]$ProductKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InputLocale = '0409:00000409',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SystemLocale = 'en-001',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UILanguage = 'en-US',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UserLocale = 'en-001',

    [Parameter()]
    [ValidateSet('Off', 'Basic')]
    [string]$TelemetryLevel = 'Off',

    [Parameter()]
    [string]$GeneratedAt = '',

    [Parameter()]
    [string]$OptionsJson = '',

    [Parameter()]
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..\win-install\autounattend.template.xml'),

    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\win-install\staging\autounattend.xml'),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- options merge: defaults < JSON file < explicitly bound CLI params -------
if ($OptionsJson -ne '') {
    if (-not (Test-Path -LiteralPath $OptionsJson -PathType Leaf)) {
        throw "Options JSON not found: $OptionsJson"
    }
    $fileOpts = Get-Content -LiteralPath $OptionsJson -Raw -Encoding utf8 | ConvertFrom-Json
    $known = @('computer_name','username','password','standard_username','standard_password',
               'timezone','edition','product_key','input_locale','system_locale',
               'ui_language','user_locale','telemetry','generated_at','force')
    foreach ($prop in $fileOpts.PSObject.Properties.Name) {
        if ($prop -notin $known) { throw "Unknown option in ${OptionsJson}: $prop" }
    }
    $map = @{ computer_name='ComputerName'; username='Username'; password='Password';
              standard_username='StandardUsername'; standard_password='StandardPassword';
              timezone='TimeZone'; edition='Edition'; product_key='ProductKey';
              input_locale='InputLocale'; system_locale='SystemLocale';
              ui_language='UILanguage'; user_locale='UserLocale';
              telemetry='TelemetryLevel'; generated_at='GeneratedAt'; force='Force' }
    foreach ($prop in $fileOpts.PSObject.Properties.Name) {
        $pname = $map[$prop]
        if ($PSBoundParameters.ContainsKey($pname)) { continue }  # CLI wins
        $val = $fileOpts.$prop
        switch ($pname) {
            'Password'         { $Password = ConvertTo-SecureString -String ([string]$val) -AsPlainText -Force }
            'StandardPassword' { $StandardPassword = ConvertTo-SecureString -String ([string]$val) -AsPlainText -Force }
            'Force'            { if ($val) { $Force = $true } }
            'TelemetryLevel'   { $TelemetryLevel = if ([string]$val -ieq 'basic') { 'Basic' } else { 'Off' } }
            default            { Set-Variable -Name $pname -Value ([string]$val) -Scope Script }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw "-ComputerName is required." }
if ([string]::IsNullOrWhiteSpace($Username))     { throw "-Username is required." }
if ($Username -match '[<>"\r\n]') { throw "Username must not contain <>`" or newlines." }

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-ObscuredUnattendPassword {
    # Schneegans "ObscurePasswords": base64( UTF-16LE( password + "Password" ) ).
    param([Parameter(Mandatory = $true)][string]$PlainText)
    $bytes = [Text.Encoding]::Unicode.GetBytes($PlainText + 'Password')
    return [Convert]::ToBase64String($bytes)
}

function Get-UrlEncoded {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ([Uri]::EscapeDataString($Value) -replace '%20', '+')
}

function Get-XmlEscaped {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

# --- validate inputs ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    throw "Template not found: $TemplatePath"
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output file already exists: $OutputPath (use -Force to overwrite)"
}
if ([string]::IsNullOrWhiteSpace($StandardUsername)) { $StandardUsername = '' }

if ($null -eq $Password) {
    $Password = Read-Host -AsSecureString -Prompt "Password for local admin '$Username'"
}
$adminPlain = ConvertFrom-SecureStringToPlainText -Secure $Password
if ([string]::IsNullOrEmpty($adminPlain)) {
    throw "Password for '$Username' cannot be empty."
}

$stdPlain = $null
if ($StandardUsername -ne '') {
    if ($null -eq $StandardPassword) {
        $StandardPassword = Read-Host -AsSecureString -Prompt "Password for standard account '$StandardUsername'"
    }
    $stdPlain = ConvertFrom-SecureStringToPlainText -Secure $StandardPassword
    if ([string]::IsNullOrEmpty($stdPlain)) {
        throw "Password for '$StandardUsername' cannot be empty."
    }
    if ($StandardUsername -eq $Username) {
        throw "StandardUsername '$StandardUsername' must differ from Username '$Username'."
    }
    if ($StandardUsername -match '[<>"\r\n]') { throw "StandardUsername must not contain <>`" or newlines." }
}

# --- load template -----------------------------------------------------------
$content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8

# --- rewrite the Schneegans generator comment (comment-only tokens first) -----
$commentPattern = '<!--https://schneegans\.de/windows/unattend-generator/\?.*?-->'
$commentMatch = [regex]::Match($content, $commentPattern, [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $commentMatch.Success) {
    throw "Template is missing the Schneegans generator comment; refusing to guess."
}
$comment = $commentMatch.Value
foreach ($pair in @(
    @('COMPUTER_NAME', $ComputerName), @('TIME_ZONE', $TimeZone),
    @('EDITION_NAME', $Edition), @('PRODUCT_KEY', $ProductKey),
    @('ACCOUNT_NAME', $Username), @('ACCOUNT_PASSWORD', $adminPlain))) {
    $comment = $comment.Replace('{{' + $pair[0] + '}}', (Get-UrlEncoded $pair[1]))
}
if ($StandardUsername -ne '') {
    $comment = $comment.Replace('{{STANDARD_ACCOUNT_NAME}}', (Get-UrlEncoded $StandardUsername))
    $comment = $comment.Replace('{{STANDARD_ACCOUNT_PASSWORD}}', (Get-UrlEncoded $stdPlain))
}
else {
    # Single-account file: drop the second-account params from the regen URL.
    $comment = [regex]::Replace($comment, '&Account(Name|DisplayName|Password|Group)1=[^&]*', '')
}
# Keep the round-trippable URL honest about locale choices.
$keyboard = ($InputLocale -split ':')[-1]
$comment = [regex]::Replace($comment, '([?&])UILanguage=[^&]*', "`$1UILanguage=$(Get-UrlEncoded $UILanguage)")
$comment = [regex]::Replace($comment, '([?&])Locale=[^&]*', "`$1Locale=$(Get-UrlEncoded $SystemLocale)")
$comment = [regex]::Replace($comment, '([?&])Keyboard=[^&]*', "`$1Keyboard=$(Get-UrlEncoded $keyboard)")
$content = $content.Substring(0, $commentMatch.Index) + $comment +
           $content.Substring($commentMatch.Index + $commentMatch.Length)

# Stamp the file so its origin is obvious on the USB.
# NOTE: an XML comment must not contain '--' anywhere but its terminator --
# a '--' mid-comment makes the generated file not well-formed XML. Use no
# double dashes. The text is byte-identical with generate_unattend.py
# (part of the PS1<->py parity contract).
if ([string]::IsNullOrWhiteSpace($GeneratedAt)) {
    $GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$stamp = "<!-- Generated by Phoenix answer-file generator on $GeneratedAt. " +
         "CONTAINS REAL CREDENTIALS, DO NOT COMMIT. -->"
$content = $content.Replace($comment, $comment + "`n`t" + $stamp)

# --- telemetry minimization: reg blocks appended to Specialize.ps1 -----------
if ($TelemetryLevel -eq 'Off') {
    $anchor = "`t{`n`t`treg.exe add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE`" /v BypassNRO /t REG_DWORD /d 1 /f;`n`t};"
    $i = $content.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($i -lt 0) {
        throw "Telemetry anchor (BypassNRO block) not found in template; refusing to guess."
    }
    $telemetryBlock = "`n`t{`n`t`treg.exe add `"HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection`" /v AllowTelemetry /t REG_DWORD /d 0 /f;`n`t};`n" +
                      "`t{`n`t`treg.exe add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection`" /v AllowTelemetry /t REG_DWORD /d 0 /f;`n`t};"
    $content = $content.Substring(0, $i + $anchor.Length) + $telemetryBlock +
               $content.Substring($i + $anchor.Length)
}

# --- locale / keyboard (fail closed if the template's hardcoded values change)
$localePairs = @(
    @('InputLocale',  '0409:00000409', $InputLocale),
    @('SystemLocale', 'en-001',        $SystemLocale),
    @('UILanguage',   'en-US',         $UILanguage),
    @('UserLocale',   'en-001',        $UserLocale)
)
foreach ($lp in $localePairs) {
    $needle = "<$($lp[0])>$($lp[1])</$($lp[0])>"
    if ($content.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "Locale anchor $needle not found in template; refusing to guess."
    }
    $content = $content.Replace($needle, "<$($lp[0])>$(Get-XmlEscaped $lp[2])</$($lp[0])>")
}

# --- fill body tokens ---------------------------------------------------------
$adminB64 = Get-ObscuredUnattendPassword -PlainText $adminPlain

if ($StandardUsername -ne '') {
    $stdB64 = Get-ObscuredUnattendPassword -PlainText $stdPlain
    $stdName = Get-XmlEscaped $StandardUsername
    # First line inherits the template's 5-tab indent; the rest is explicit.
    $stdBlock = "<LocalAccount wcm:action=`"add`">`n" +
                "`t`t`t`t`t`t<Name>$stdName</Name>`n" +
                "`t`t`t`t`t`t<DisplayName></DisplayName>`n" +
                "`t`t`t`t`t`t<Group>Users</Group>`n" +
                "`t`t`t`t`t`t<Password>`n" +
                "`t`t`t`t`t`t`t<Value>$stdB64</Value>`n" +
                "`t`t`t`t`t`t`t<PlainText>false</PlainText>`n" +
                "`t`t`t`t`t`t</Password>`n" +
                "`t`t`t`t`t</LocalAccount>"
    $content = $content.Replace('{{STANDARD_ACCOUNT_XML}}', $stdBlock)
}
else {
    # Remove the token's whole line so no blank indented line is left behind.
    $content = [regex]::Replace($content, '(?m)^\t*{{STANDARD_ACCOUNT_XML}}\r?\n', '')
}

$content = $content.Replace('{{COMPUTER_NAME}}', (Get-XmlEscaped $ComputerName))
$content = $content.Replace('{{PRODUCT_KEY}}', $ProductKey)
$content = $content.Replace('{{TIME_ZONE}}', (Get-XmlEscaped $TimeZone))
$content = $content.Replace('{{EDITION_NAME}}', $Edition)
$content = $content.Replace('{{ACCOUNT_NAME}}', (Get-XmlEscaped $Username))
$content = $content.Replace('{{ACCOUNT_PASSWORD_B64}}', $adminB64)

# --- safety: no token may survive ---------------------------------------------
$leftover = [regex]::Match($content, '\{\{[A-Z_]+\}\}')
if ($leftover.Success) {
    throw "Unfilled token left in output: $($leftover.Value). Aborting."
}

# --- the filled file must still be well-formed XML -----------------------------
try {
    $null = [xml]$content
}
catch {
    throw "Generated file is not well-formed XML: $($_.Exception.Message)"
}

# --- write to staging ----------------------------------------------------------
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}
# Match the template: UTF-8, no BOM, LF endings.
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, ($content -replace "`r`n", "`n"), $utf8NoBom)

Write-Host "Wrote $OutputPath"
Write-Host "  Computer : $ComputerName"
Write-Host "  Admin    : $Username (Administrators, AutoLogon x1)"
if ($StandardUsername -ne '') { Write-Host "  Standard : $StandardUsername (Users)" }
Write-Host "  Timezone : $TimeZone"
Write-Host "  Edition  : $Edition"
Write-Host "  Telemetry: $TelemetryLevel"
Write-Host ""
Write-Host "Staging dir is gitignored - copy this file to the USB as autounattend.xml." -ForegroundColor Yellow
