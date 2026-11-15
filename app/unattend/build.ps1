<#
.SYNOPSIS
    Builds phoenix-unattend.exe (self-contained, single file) into app\unattend\bin.

.DESCRIPTION
    Uses an existing .NET 10 SDK if one is on PATH or in the user-scope install
    dir; otherwise installs it there WITHOUT admin via Microsoft's signed
    dotnet-install.ps1 (%LOCALAPPDATA%\Microsoft\dotnet). Works on Windows
    PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File app\unattend\build.ps1
#>
[CmdletBinding()]
param(
    [string]$Channel = '10.0',
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$userDotnetDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

function Test-Sdk([string]$Dotnet) {
    if (-not $Dotnet -or -not (Test-Path -LiteralPath $Dotnet)) { return $false }
    $sdks = & $Dotnet --list-sdks 2>$null
    [bool]($sdks | Where-Object { $_ -like "$($Channel.Split('.')[0]).*" })
}

$dotnet = $null
foreach ($c in @((Join-Path $userDotnetDir 'dotnet.exe'), (Get-Command dotnet -ErrorAction SilentlyContinue | ForEach-Object Source))) {
    if (Test-Sdk $c) { $dotnet = $c; break }
}

if (-not $dotnet) {
    Write-Host "Installing .NET $Channel SDK to $userDotnetDir (no admin needed)..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw "dotnet-install.ps1 signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))."
    }
    & $installer -Channel $Channel -InstallDir $userDotnetDir -NoPath
    $dotnet = Join-Path $userDotnetDir 'dotnet.exe'
    if (-not (Test-Sdk $dotnet)) { throw ".NET $Channel SDK install failed." }
}

Write-Host "Using $dotnet" -ForegroundColor DarkGray
$out = Join-Path $here 'bin'
& $dotnet publish (Join-Path $here 'PhoenixUnattend.csproj') -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)." }

$exe = Join-Path $out 'phoenix-unattend.exe'
& $exe version | Out-Host
Write-Host "Built $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)" -ForegroundColor Green
