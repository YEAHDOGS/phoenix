<#
.SYNOPSIS
    New-PhoenixConfig.ps1 -- write phoenix-config.json (the Phoenix USB key file)

.DESCRIPTION
    PowerShell twin of tools/New-PhoenixConfig.sh -- EXACT parity contract
    (enforced by tests/tools/test-phoenix-config.sh). The config GUI (Tauri)
    is the flagship writer; this is the zero-dependency CLI fallback that runs
    on the working Windows machine.

    Writes exactly the schema the boot side reads headless
    (docs/BOOT-ARCHITECTURE.md §5, schemaVersion 1):
      schemaVersion, machine.{computerName,timezone},
      credentials.{username,password},
      os.{family,edition,productKey,answerFile.{disableWPBT,partitionLayout}},
      apps[].{id,source}, nuke.{protectedDisks[]}

    SECURITY (read before you run this):
      unattend requires the install-time password in a REVERSIBLE form
      (base64-obfuscated = effectively plaintext). The USB is a KEY -- anyone
      holding it can read the password. This tool:
        - NEVER prints the password to the console or logs (--DryRun redacts it)
        - refuses password-on-piped-stdin (echo P | ...) -- use -Password or a console
        - REFUSES to write inside a git work tree without -Force (so a real
          config never gets committed by accident -- .gitignore covers it too)
      Rotate the install-time password at first logon (EMERGENCY-RUNBOOK),
      keep the stick on your person, never leave it in the machine.

.PARAMETER ComputerName
    REQUIRED. 1-15 chars, A-Z 0-9 - (NetBIOS rule).

.PARAMETER Username
    REQUIRED. Local account the answer file creates.

.PARAMETER Password
    Install-time password. If omitted and stdin is a real console, prompts
    securely (Read-Host -AsSecureString); refuses piped stdin.

.PARAMETER Timezone
    Default: "Central Standard Time".

.PARAMETER Family
    windows|linux|macos. Default: windows.

.PARAMETER Edition
    Default: Professional.

.PARAMETER ProductKey
    XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, or omit for digital license (emits null).

.PARAMETER KeepWPBT
    Leave WPBT enabled. Default behavior disables it.

.PARAMETER PartitionLayout
    gpt-uefi|mbr-bios. Default: gpt-uefi.

.PARAMETER App
    Repeatable, "source:id" -- e.g. -App choco:googlechrome.

.PARAMETER ProtectDisk
    Repeatable. Disk serial (or \\.\PhysicalDriveN path) that the NUKE path
    must never offer as a candidate (nuke.protectedDisks). Use for the
    backup vault, the Castle drive, anything irreplaceable.

.PARAMETER Out
    Output path. Default: .\phoenix-config.json.

.PARAMETER DryRun
    Print the config (password REDACTED), write nothing.

.PARAMETER Force
    Allow writing inside a git work tree (test fixtures only).

.EXAMPLE
    .\tools\New-PhoenixConfig.ps1 -ComputerName BRANDON-PC -Username brandon `
        -Password $secret -Out E:\phoenix-config.json

.EXAMPLE
    .\tools\New-PhoenixConfig.ps1 -ComputerName BRANDON-PC -Username brandon `
        -App choco:googlechrome -App choco:steam -DryRun
#>
[CmdletBinding()]
param(
    [string]$ComputerName,
    [string]$Username,
    [string]$Password,
    [string]$Timezone = "Central Standard Time",
    [ValidateSet("windows","linux","macos")][string]$Family = "windows",
    [string]$Edition = "Professional",
    [string]$ProductKey,
    [switch]$KeepWPBT,
    [ValidateSet("gpt-uefi","mbr-bios")][string]$PartitionLayout = "gpt-uefi",
    [string[]]$App,
    [string[]]$ProtectDisk,
    [string]$Out = ".\phoenix-config.json",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Tag = "[New-PhoenixConfig]"

function Fail([string]$Message) { Write-Error "$Tag FATAL: $Message" }

#--- required fields -------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ComputerName)) { Fail "--ComputerName is required" }
if ([string]::IsNullOrWhiteSpace($Username))     { Fail "--Username is required" }

#--- password: -Password or interactive console; NEVER from a pipe ----------------
if ([string]::IsNullOrEmpty($Password)) {
    if ([Console]::IsInputRedirected) {
        Fail "no -Password given and stdin is redirected. Refusing password-on-piped-stdin: ``echo `$pass | ...`` leaks into shell history. Pass -Password explicitly."
    }
    $secure = Read-Host "Install-time password for $Username" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    if ([string]::IsNullOrEmpty($Password)) { Fail "password may not be empty" }
}

#--- validation -------------------------------------------------------------------
if ($ComputerName -notmatch '^[A-Za-z0-9-]{1,15}$') {
    Fail "-ComputerName '$ComputerName' invalid: 1-15 chars, A-Z 0-9 and - only (NetBIOS rule)"
}
if (-not [string]::IsNullOrEmpty($ProductKey) -and $ProductKey -notmatch '^([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}$') {
    Fail "-ProductKey invalid: expected XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (omit for digital license)"
}
if ([string]::IsNullOrWhiteSpace($Timezone)) { Fail "-Timezone may not be empty" }

$appList = @()
foreach ($a in $App) {
    if ($a -notmatch ':') { Fail "-App '$a' invalid: expected source:id (e.g. choco:googlechrome)" }
    $src, $id = $a -split ':', 2
    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($id)) {
        Fail "-App '$a' invalid: source and id may not be empty"
    }
    $appList += @{ id = $id; source = $src }
}

#--- protected disks: identifiers must be non-empty, whitespace-free -----------
$protectList = @()
foreach ($p in $ProtectDisk) {
    if ([string]::IsNullOrWhiteSpace($p)) { Fail "-ProtectDisk may not be empty" }
    if ($p -match '\s') {
        Fail "-ProtectDisk '$p' invalid: no whitespace (use the exact serial or device path)"
    }
    $protectList += "$p"
}

#--- build config object (schema v1, same shape as the .sh twin) ------------------
$config = [ordered]@{
    schemaVersion = 1
    machine       = [ordered]@{ computerName = $ComputerName; timezone = $Timezone }
    credentials   = [ordered]@{ username = $Username; password = $Password }
    os            = [ordered]@{
        family    = $Family
        edition   = $Edition
        productKey = if ([string]::IsNullOrEmpty($ProductKey)) { $null } else { $ProductKey }
        answerFile = [ordered]@{
            disableWPBT      = (-not $KeepWPBT.IsPresent)
            partitionLayout  = $PartitionLayout
        }
    }
    apps = $appList
    nuke = [ordered]@{ protectedDisks = $protectList }
}

function Write-ConfigJson([hashtable]$Cfg, [bool]$Redact) {
    if ($Redact) {
        # Redact by serializing a redacted COPY -- the password value itself
        # (JSON-escaped or otherwise) never touches the output string.
        $redacted = [ordered]@{
            schemaVersion = $Cfg.schemaVersion
            machine       = $Cfg.machine
            credentials   = [ordered]@{ username = $Cfg.credentials.username; password = "***REDACTED***" }
            os            = $Cfg.os
            apps          = $Cfg.apps
            nuke          = $Cfg.nuke
        }
        return ($redacted | ConvertTo-Json -Depth 5)
    }
    return ($Cfg | ConvertTo-Json -Depth 5)
}

if ($DryRun) {
    Write-Output (Write-ConfigJson $config $true)
    return
}

#--- git-tree guard: a real config must never be committed -------------------------
if (-not $Force) {
    $outDir = Split-Path -Parent (Resolve-Path $Out -ErrorAction SilentlyContinue)
    if (-not $outDir) { $outDir = (Get-Location).Path }
    $probe = $outDir
    while ($probe) {
        if (Test-Path (Join-Path $probe ".git")) {
            Fail "refusing to write '$Out': it is inside a git work tree (a real phoenix-config.json must never be committed -- BOOT-ARCHITECTURE.md §5). Use -Force only for test fixtures, never for a real password."
        }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
}

$json = Write-ConfigJson $config $false
Set-Content -LiteralPath $Out -Value $json -Encoding UTF8

Write-Host "$Tag wrote $Out"
Write-Host "$Tag SECURITY: this file holds the install-time password in reversible form."
Write-Host "$Tag The USB is a KEY -- keep it on your person, never leave it in the"
Write-Host "$Tag machine, and ROTATE the password at first logon (EMERGENCY-RUNBOOK)."
