<#
.SYNOPSIS
    Phoenix $OEM$ hook: default-user registry tweaks (HKU\DefaultUser mounted).

.DESCRIPTION
    Invoked by autounattend.xml (specialize pass, Order 4) as
    C:\Windows\Setup\Scripts\DefaultUser.ps1, immediately after the answer
    file loads the default profile hive at HKU\DefaultUser (Order 3) and
    before it unloads it (Order 5).

    Every new account created on this machine inherits these settings:
      - Explorer: show file extensions, "This PC" as the home view.
      - Taskbar: no Widgets feed, no Copilot button, search as icon.
      - Privacy: advertising ID off, tailored experiences off, Start
        suggestions off.
      - Gaming: Game Bar tips/recording prompts off (silent gamer default).

    Only the default-user hive is touched. No machine-wide registry changes, no network,
    no credentials. All values are plain DWORDs in documented Windows keys,
    so the whole thing is reverted by flipping them back or deleting the
    profile.

    PHOENIX-OEM
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$logFile = "C:\Phoenix\Logs\DefaultUser.log"

function Write-PhoenixLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'o') [$Level] $Message"
    try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

function Set-DefaultUserDword {
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    $path = "HKUDef:\$SubKey"
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        New-ItemProperty -Path $path -Name $Name -Value $Value `
            -PropertyType DWord -Force | Out-Null
        Write-PhoenixLog "Set HKU\DefaultUser\$SubKey\$Name = $Value"
    } catch {
        Write-PhoenixLog "Failed HKU\DefaultUser\$SubKey\$Name : $($_.Exception.Message)" "ERROR"
    }
}

Write-PhoenixLog "Phoenix DefaultUser started."

# The hive must be mounted by the answer file (reg.exe load, Order 3).
$mounted = $false
try {
    $mounted = Test-Path -LiteralPath "Registry::HKEY_USERS\DefaultUser"
} catch { $mounted = $false }

if (-not $mounted) {
    Write-PhoenixLog "HKU\DefaultUser is NOT mounted -- the answer file's reg.exe load step did not run. Skipping all tweaks." "ERROR"
    Write-PhoenixLog "Phoenix DefaultUser finished (no-op)."
    exit 0
}

try {
    if (-not (Get-PSDrive -Name HKUDef -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKUDef -PSProvider Registry -Root "HKEY_USERS\DefaultUser" | Out-Null
    }
} catch {
    Write-PhoenixLog "Could not map HKUDef PSDrive: $($_.Exception.Message)" "ERROR"
    Write-PhoenixLog "Phoenix DefaultUser finished (no-op)."
    exit 0
}

# --- Explorer -------------------------------------------------------------
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt"        -Value 0
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo"           -Value 1  # This PC
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Value 0

# --- Taskbar ---------------------------------------------------------------
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa"          -Value 0  # no Widgets
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -Value 0  # no Copilot
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Search"            -Name "SearchboxTaskbarMode" -Value 1  # icon only

# --- Privacy ---------------------------------------------------------------
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\Privacy"        -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SystemPaneSuggestionsEnabled" -Value 0

# --- Gaming ----------------------------------------------------------------
Set-DefaultUserDword -SubKey "Software\Microsoft\GameBar" -Name "ShowStartupPanel" -Value 0
Set-DefaultUserDword -SubKey "Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0

Write-PhoenixLog "Phoenix DefaultUser finished."
exit 0
