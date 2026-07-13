# ==============================================================================
# Git is a pile of nuclear ass that has been shit fucked into dll purgatory
# ==============================================================================

# 1. Define paths
$ToolboxRoot   = "C:\toolbox\git"
$TargetBin     = "$ToolboxRoot\bin"
$TargetLibexec = "$ToolboxRoot\libexec\git-core"
$TargetTmp     = "$ToolboxRoot\tmp"
$TargetUsrBin  = "$ToolboxRoot\usr\bin"
$BinSrc        = "C:\git-sdk-64\mingw64\bin"

# Clear out previous incomplete structures cleanly
if (Test-Path $ToolboxRoot) {
    Remove-Item $ToolboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. Create target folder layouts (Including the required structures)
New-Item -ItemType Directory -Force $TargetBin | Out-Null
New-Item -ItemType Directory -Force $TargetLibexec | Out-Null
New-Item -ItemType Directory -Force $TargetTmp | Out-Null
New-Item -ItemType Directory -Force (Split-Path $TargetUsrBin) | Out-Null

# Create a fast directory junction link so /usr/bin resolves to our flat bin directory
New-Item -ItemType Junction -Path $TargetUsrBin -Value $TargetBin | Out-Null

Write-Host "[*] Transporting core POSIX utilities..." -ForegroundColor Cyan

# 3. Base POSIX Shell Environment & Core Dev Utilities
$MsysAssets = @(
    "bash.exe", "sh.exe", "msys-2.0.dll",
    "file.exe", "head.exe", "sha512sum.exe", "sha256sum.exe", "gpg.exe", "yes.exe", "ldd.exe", "cat.exe",
    "msys-magic-1.dll", "msys-lzma-5.dll", "msys-zstd-1.dll", "msys-bz2-1.dll", "msys-intl-8.dll", "msys-iconv-2.dll",
    "msys-assuan-9.dll", "msys-gpg-error-0.dll", "msys-npth-0.dll", "msys-gcrypt-20.dll"
)

foreach ($asset in $MsysAssets) {
    if (Test-Path "C:\git-sdk-64\usr\bin\$asset") {
        Copy-Item "C:\git-sdk-64\usr\bin\$asset" "$TargetBin\" -Force
    }
}

# ==============================================================================
# 4. Comprehensive Core MinGW Dynamic Libraries & Zstd Translation Mapping
# ==============================================================================
Write-Host "[*] Transporting dynamic network engines..." -ForegroundColor Cyan

$GitLibDLLs = @(
    "libintl-8.dll", "libiconv-2.dll", "libpcre2-8-0.dll", "zlib1.dll", 
    "libcurl-4.dll", "libcrypto-3-x64.dll", "libssl-3-x64.dll", "libssh2-1.dll",
    "libnghttp2-14.dll", "libidn2-0.dll", "libpsl-5.dll", "libunistring-5.dll",
    "libgcc_s_seh-1.dll", "libwinpthread-1.dll", "libbrotlidec.dll", "libbrotlicommon.dll",
    "libbrotlienc.dll", "libssh-4.dll", "libgssapi_krb5-2.dll", "libkrb5-3.dll", 
    "libk5crypto-3.dll", "libcom_err-2.dll", "libzstd-1.dll", "librtmp-1.dll"
)

foreach ($lib in $GitLibDLLs) {
    $SrcPath = "$BinSrc\$lib"
    if (Test-Path $SrcPath) {
        Copy-Item $SrcPath "$TargetBin\" -Force
        Copy-Item $SrcPath "$TargetLibexec\" -Force
    }
}

# Forge the missing libzstd.dll link if it only exists as libzstd-1.dll
if (Test-Path "$BinSrc\libzstd.dll") {
    Copy-Item "$BinSrc\libzstd.dll" "$TargetBin\" -Force
    Copy-Item "$BinSrc\libzstd.dll" "$TargetLibexec\" -Force
} elseif (Test-Path "$TargetBin\libzstd-1.dll") {
    Write-Host "[*] Forging required libzstd.dll link for libcurl..." -ForegroundColor Yellow
    Copy-Item "$TargetBin\libzstd-1.dll" "$TargetBin\libzstd.dll" -Force
    Copy-Item "$TargetLibexec\libzstd-1.dll" "$TargetLibexec\libzstd.dll" -Force
}

# 5. Drop the signature database file directly into the execution bin
if (Test-Path "C:\git-sdk-64\usr\share\misc\magic.mgc") {
    Copy-Item "C:\git-sdk-64\usr\share\misc\magic.mgc" "$TargetBin\" -Force
}

# 6. Map the core git execution engine
if (Test-Path "$BinSrc\git.exe") {
    Copy-Item "$BinSrc\git.exe" "$TargetBin\" -Force
}

# 7. Map the network helpers straight into the expected libexec location
$NetworkHelpers = @("git-remote-http.exe", "git-remote-https.exe", "git-http-fetch.exe", "git-http-push.exe")
foreach ($helper in $NetworkHelpers) {
    $ProdSrcPath = "C:\git-sdk-64\mingw64\libexec\git-core\$helper"
    if (Test-Path $ProdSrcPath) {
        Copy-Item $ProdSrcPath "$TargetLibexec\" -Force
    }
}

# ==============================================================================
# 8. Deploy Secure Git Credential Manager Assembly Payload & Configuration
# ==============================================================================
Write-Host "[*] Instantiating secure managed authentication vault components..." -ForegroundColor Cyan

if (Test-Path "$BinSrc\git-credential-manager.exe") {
    Copy-Item "$BinSrc\git-credential-manager.exe" "$TargetBin\" -Force
}

# Pull the mandatory execution config files containing assembly binding redirects
if (Test-Path "$BinSrc\git-credential-manager*.config") {
    Copy-Item "$BinSrc\git-credential-manager*.config" "$TargetBin\" -Force
}

# Target core assemblies, UI rendering frames, and identity subroutines strictly required by manifest
$GcmAssemblies = @(
    "gcmcore.dll", "GitHub.dll", "Microsoft.AzureRepos.dll", "Atlassian.Bitbucket.dll", "GitLab.dll",
    "Avalonia.Base.dll", "Avalonia.Controls.dll", "Avalonia.Win32.dll", "Avalonia.Skia.dll",
    "Avalonia.Markup.dll", "Avalonia.Markup.Xaml.dll", "Avalonia.Themes.Fluent.dll",
    "System.CommandLine.dll", "System.Memory.dll", "System.Text.Json.dll", "netstandard.dll",
    "Microsoft.Identity.Client.dll", "Microsoft.Identity.Client.Extensions.Msal.dll", "Microsoft.Identity.Client.Broker.dll"
)

foreach ($dll in $GcmAssemblies) {
    if (Test-Path "$BinSrc\$dll") {
        Copy-Item "$BinSrc\$dll" "$TargetBin\" -Force
    }
}

# ==============================================================================
# 9. Global Env Context Binding Initialization
# ==============================================================================
Write-Host "[*] Binding secure credentials to native OS manager runtime..." -ForegroundColor Cyan

# Hook Git up globally to look for the system manager helper
& "$TargetBin\git.exe" config --global credential.helper "manager"

Write-Host "`n[✓] Structural environment deployed natively to C:\toolbox\git\" -ForegroundColor Green