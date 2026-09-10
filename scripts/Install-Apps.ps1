<#
.SYNOPSIS
    Installs the Phoenix app selection via Chocolatey (or prints the plan).

.DESCRIPTION
    Reads config/apps.json (the app-picker manifest), selects packages, and
    installs them with Chocolatey. Twin of scripts/install_apps.sh, which
    prints the same plan on Linux (Chocolatey is Windows-only).

    -Offline prints the install plan and exits 0 without touching anything --
    the air-gap path: pre-stage the packages with
    `choco download <pkg> --internalize` on a connected machine, copy the
    folder to the target, and rerun with -ChocoSource pointing at it.

    The emitted plan format is identical to install_apps.sh so the Tauri GUI
    can parse either one.

.PARAMETER Manifest
    Path to apps.json. Defaults to config/apps.json next to this script.

.PARAMETER Packages
    Explicit package list. Overrides -UseDefaults.

.PARAMETER UseDefaults
    Install the manifest's defaultSelected packages.

.PARAMETER Offline
    Print the plan only; install nothing. Always safe to run.

.PARAMETER ChocoSource
    Passed as --source to choco install (e.g. a local pre-staged folder).

.PARAMETER LogPath
    Install log. Defaults to C:\Phoenix\Logs\app-install.log.

.EXAMPLE
    .\scripts\Install-Apps.ps1 -Offline
    Shows what would be installed, changes nothing.

.EXAMPLE
    .\scripts\Install-Apps.ps1 -UseDefaults -ChocoSource C:\Phoenix\Packages
    Air-gap install from a pre-staged package folder.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Manifest = (Join-Path $PSScriptRoot '..\config\apps.json'),

    [Parameter()]
    [string[]]$Packages,

    [switch]$UseDefaults,

    [switch]$Offline,

    [Parameter()]
    [string]$ChocoSource = '',

    [Parameter()]
    [string]$LogPath = 'C:\Phoenix\Logs\app-install.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw "App manifest not found: $Manifest"
}
$catalog = Get-Content -LiteralPath $Manifest -Raw -Encoding utf8 | ConvertFrom-Json

if ($Packages -and $Packages.Count -gt 0) {
    $wanted = @($Packages)
}
elseif ($UseDefaults) {
    $wanted = @($catalog | Where-Object { $_.defaultSelected } | ForEach-Object { $_.package })
}
else {
    # No selection given: the safe default is the manifest's defaults.
    $wanted = @($catalog | Where-Object { $_.defaultSelected } | ForEach-Object { $_.package })
}

$byId = @{}
foreach ($entry in $catalog) { $byId[$entry.package] = $entry }

$plan = @()
foreach ($id in $wanted) {
    $entry = $byId[$id]
    if ($null -eq $entry) { throw "Package '$id' is not in the manifest $Manifest" }
    $plan += [pscustomobject]@{
        Package         = $entry.package
        Category        = $entry.category
        Source          = if ($entry.source) { $entry.source } else { 'chocolatey' }
        Note            = if ($entry.note) { $entry.note } else { '' }
        DefaultSelected = [bool]$entry.defaultSelected
    }
}

# --- the plan: identical shape to install_apps.sh --plan output ------------
Write-Host "Phoenix app-install plan ($($plan.Count) packages)"
Write-Host ("{0,-28} {1,-18} {2}" -f 'PACKAGE', 'CATEGORY', 'SOURCE')
foreach ($p in $plan) {
    Write-Host ("{0,-28} {1,-18} {2}" -f $p.Package, $p.Category, $p.Source)
}
$manual = @($plan | Where-Object { $_.Source -eq 'manual' })
foreach ($m in $manual) {
    Write-Host "  MANUAL STEP: $($m.Package) -- $($m.Note)" -ForegroundColor Yellow
}

if ($Offline) {
    Write-Host ""
    Write-Host "Offline mode: plan only, nothing installed."
    exit 0
}

# --- online path: bootstrap Chocolatey if missing ---------------------------
function Write-InstallLog {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'u'), $Message) -Encoding utf8
    } catch { <# logging must never break the install #> }
}

$choco = Get-Command choco -ErrorAction SilentlyContinue
if ($null -eq $choco) {
    Write-Host "Chocolatey not found; bootstrapping..."
    Write-InstallLog "bootstrapping Chocolatey"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = "$env:TEMP\choco-install.ps1"
    Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $installer -UseBasicParsing
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($null -eq $choco) {
        Write-InstallLog "ERROR: Chocolatey bootstrap failed"
        throw "Chocolatey bootstrap failed; see $LogPath"
    }
}

# --- idempotent installs; failures are logged, never fatal (never block OOBE)
$failed = @()
foreach ($p in $plan) {
    if ($p.Source -eq 'manual') {
        Write-InstallLog "SKIP (manual): $($p.Package)"
        continue
    }
    $already = (& choco list --local-only --exact $p.Package --limit-output 2>$null) -match "^$([regex]::Escape($p.Package))\|"
    if ($already) {
        Write-Host "  skip (installed): $($p.Package)"
        Write-InstallLog "SKIP (installed): $($p.Package)"
        continue
    }
    Write-Host "  install: $($p.Package)"
    $chocoArgs = @('install', $p.Package, '-y', '--no-progress', '--limit-output')
    if ($ChocoSource -ne '') { $chocoArgs += "--source=$ChocoSource" }
    & choco @chocoArgs 2>&1 | ForEach-Object { Write-InstallLog "$($p.Package): $_" }
    if ($LASTEXITCODE -ne 0) {
        $failed += $p.Package
        Write-Host "  FAILED: $($p.Package) (logged)" -ForegroundColor Red
        Write-InstallLog "FAILED: $($p.Package)"
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed packages (see $LogPath): $($failed -join ', ')" -ForegroundColor Yellow
}
Write-Host "Done."
exit 0
