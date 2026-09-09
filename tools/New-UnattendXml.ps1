<#
.SYNOPSIS
    Generates a Windows unattended answer file (autounattend.xml) from the
    Phoenix tokenized template.

.DESCRIPTION
    Fills win-install/autounattend.template.xml with the machine identity,
    local accounts, timezone, edition and product key you supply, and writes
    the result to win-install/staging/autounattend.xml.

    This generator is the ONLY source of credentials in Phoenix. The template
    is credential-free and safe to commit; the filled file carries real
    local-account passwords (the unattend format requires them - even the
    "obscured" form is reversible) and is gitignored via win-install/staging/.

    The Schneegans generator URL embedded in the template header is rewritten
    to reflect the chosen options, so the filled file stays regenerable by
    hand at https://schneegans.de/windows/unattend-generator/.

.PARAMETER ComputerName
    NetBIOS computer name, 1-15 chars (letters, digits, hyphens).

.PARAMETER Username
    Name of the primary local account. Created in Administrators and used
    for AutoLogon (single logon, like the proven template).

.PARAMETER Password
    Password for the primary account, as a SecureString. If omitted you are
    prompted with Read-Host -AsSecureString, which keeps it out of shell
    history. Passing plaintext on the command line is not possible - a
    [SecureString] parameter rejects it - use the prompt.

.PARAMETER StandardUsername
    Optional second local account (Users group), e.g. a daily-driver
    non-admin account. Omit to generate a single-account file.

.PARAMETER StandardPassword
    Password for the standard account, as a SecureString. Prompted for when
    -StandardUsername is given but no password is supplied.

.PARAMETER TimeZone
    Windows timezone ID. Default: 'Central Standard Time'.

.PARAMETER Edition
    Image name passed to dism /Apply-Image (/Name:"..."). Default:
    'Windows 11 Pro'. Must match an image name in install.wim/esd.

.PARAMETER ProductKey
    Setup product key. Default is Microsoft's public generic Windows 11 Pro
    key (VK7JG-NPHTM-C97JM-9MPGT-3V66T) - not a license, just lets setup run
    unattended. Supply a real key here if you have one.

.PARAMETER TemplatePath
    Defaults to win-install/autounattend.template.xml next to this script.

.PARAMETER OutputPath
    Defaults to win-install/staging/autounattend.xml (gitignored). Override
    only if you know what you are doing.

.PARAMETER Force
    Overwrite the output file if it already exists.

.EXAMPLE
    .\tools\New-UnattendXml.ps1 -ComputerName NIGHTMARE -Username brando
    Prompts for the password, writes win-install/staging/autounattend.xml.

.EXAMPLE
    $pw = Read-Host -AsSecureString -Prompt 'Admin password'
    .\tools\New-UnattendXml.ps1 -ComputerName NIGHTMARE -Username brando `
        -Password $pw -StandardUsername guest -Force

.NOTES
    Requires Windows PowerShell 5.1+ / PowerShell 7. The emitted file is a
    drop-in replacement for win-install/autounattend.xml on the install USB.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-]{0,14}$')]
    [string]$ComputerName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
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
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..\win-install\autounattend.template.xml'),

    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\win-install\staging\autounattend.xml'),

    [Parameter()]
    [switch]$EnableDeveloperMode,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-ObscuredUnattendPassword {
    <#
    .SYNOPSIS
        Reproduces the Schneegans "ObscurePasswords" encoding:
        base64( UTF-16LE( password + "Password" ) ).
        Verified against the proven template's hashes.
    #>
    param([Parameter(Mandatory = $true)][string]$PlainText)
    $bytes = [Text.Encoding]::Unicode.GetBytes($PlainText + 'Password')
    return [Convert]::ToBase64String($bytes)
}

function Get-UrlEncoded {
    param([Parameter(Mandatory = $true)][string]$Value)
    # Match Schneegans style: spaces as '+', like the proven file's comment.
    return ([Uri]::EscapeDataString($Value) -replace '%20', '+')
}

function Get-XmlEscaped {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

# --- validate inputs -------------------------------------------------------
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
}

# --- load template ----------------------------------------------------------
$content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8

# --- rewrite the Schneegans generator comment to match chosen options --------
$commentPattern = '<!--https://schneegans\.de/windows/unattend-generator/\?.*?-->'
$commentMatch = [regex]::Match($content, $commentPattern, [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $commentMatch.Success) {
    throw "Template is missing the Schneegans generator comment; refusing to guess."
}
$comment = $commentMatch.Value
$comment = $comment.Replace('{{COMPUTER_NAME}}', (Get-UrlEncoded $ComputerName))
$comment = $comment.Replace('{{TIME_ZONE}}', (Get-UrlEncoded $TimeZone))
$comment = $comment.Replace('{{EDITION_NAME}}', (Get-UrlEncoded $Edition))
$comment = $comment.Replace('{{PRODUCT_KEY}}', (Get-UrlEncoded $ProductKey))
$comment = $comment.Replace('{{ACCOUNT_NAME}}', (Get-UrlEncoded $Username))
$comment = $comment.Replace('{{ACCOUNT_PASSWORD}}', (Get-UrlEncoded $adminPlain))
if ($StandardUsername -ne '') {
    $comment = $comment.Replace('{{STANDARD_ACCOUNT_NAME}}', (Get-UrlEncoded $StandardUsername))
    $comment = $comment.Replace('{{STANDARD_ACCOUNT_PASSWORD}}', (Get-UrlEncoded $stdPlain))
}
else {
    # Single-account file: drop the second-account params from the regen URL.
    $comment = [regex]::Replace($comment, '&Account(Name|DisplayName|Password|Group)1=[^&]*', '')
}
$content = $content.Substring(0, $commentMatch.Index) + $comment +
           $content.Substring($commentMatch.Index + $commentMatch.Length)

# Stamp the file so its origin is obvious on the USB.
$stamp = "<!-- Generated by Phoenix tools/New-UnattendXml.ps1 on $((Get-Date).ToString('u'))" +
         " -- CONTAINS REAL CREDENTIALS, DO NOT COMMIT -->"
$content = $content.Replace($comment, $comment + "`n`t" + $stamp)

# --- fill body tokens -------------------------------------------------------
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

# --- optional Developer Mode section (specialize, RunSynchronous order 6) ----
if ($EnableDeveloperMode) {
    # First line inherits the template's 4-tab indent; the rest is explicit.
    $devModeBlock = "<RunSynchronousCommand wcm:action=`"add`">`n" +
                    "`t`t`t`t`t<Order>6</Order>`n" +
                    "`t`t`t`t`t<Path>reg.exe add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock`" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f</Path>`n" +
                    "`t`t`t`t`t<Description>Enable Windows Developer Mode (sideloading, symlinks without elevation)</Description>`n" +
                    "`t`t`t`t</RunSynchronousCommand>"
    $content = $content.Replace('{{DEV_MODE_XML}}', $devModeBlock)
}
else {
    # Remove the token's whole line so no blank indented line is left behind.
    $content = [regex]::Replace($content, '(?m)^\t*{{DEV_MODE_XML}}\r?\n', '')
}

# --- safety: no token may survive -------------------------------------------
$leftover = [regex]::Match($content, '\{\{[A-Z_]+\}\}')
if ($leftover.Success) {
    throw "Unfilled token left in output: $($leftover.Value). Aborting."
}

# --- the filled file must still be well-formed XML ---------------------------
try {
    $null = [xml]$content
}
catch {
    throw "Generated file is not well-formed XML: $($_.Exception.Message)"
}

# --- write to staging --------------------------------------------------------
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
Write-Host "  Dev mode : $(if ($EnableDeveloperMode) { 'ENABLED (specialize, order 6)' } else { 'off' })"
Write-Host "  Timezone : $TimeZone"
Write-Host "  Edition  : $Edition"
Write-Host ""
Write-Host "Staging dir is gitignored - copy this file to the USB as autounattend.xml." -ForegroundColor Yellow
