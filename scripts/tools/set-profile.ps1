<#
.SYNOPSIS
    set-profile.ps1 - Syncs Phoenix shell aliases + nav functions into PowerShell profiles.

.DESCRIPTION
    Targets the current user by default. Pass -AllUsers to write into every
    local user's profiles (excluding system accounts), with a confirmation
    prompt first - writing into other people's profiles is not something to
    do silently.
#>
param (
    [switch]$AllUsers
)

# Repo root: this script lives in <repo>\scripts\tools
$RepoRoot = (Get-Item (Join-Path $PSScriptRoot "..\..")).FullName
$ToolsDir = Join-Path $RepoRoot "scripts\tools"
$GitDir   = Join-Path $RepoRoot "scripts\git"

# Define your aliases. Repo paths resolve relative to this checkout;
# machine paths fall back to env vars so it works for any username.
$Aliases = [ordered]@{
    "gpr"         = "Get-Process"
    "strings"     = (Join-Path $env:SYSINTERNALS_DIR "strings64.exe")
    "bash"        = (Join-Path $env:GIT_INSTALL_ROOT "bin\bash.exe")
    "sh"          = (Join-Path $env:GIT_INSTALL_ROOT "bin\sh.exe")
    "file"        = (Join-Path $env:GIT_INSTALL_ROOT "bin\file.exe")
    "head"        = (Join-Path $env:GIT_INSTALL_ROOT "bin\head.exe")
    "sha512sum"   = (Join-Path $env:GIT_INSTALL_ROOT "bin\sha512sum.exe")
    "sha256sum"   = (Join-Path $env:GIT_INSTALL_ROOT "bin\sha256sum.exe")
    "gpg"         = (Join-Path $env:GIT_INSTALL_ROOT "bin\gpg.exe")
    "yes"         = (Join-Path $env:GIT_INSTALL_ROOT "bin\yes.exe")
    "ldd"         = (Join-Path $env:GIT_INSTALL_ROOT "bin\ldd.exe")
    "git-fucked"  = (Join-Path $GitDir "git-fucked.ps1")
    "delete-node" = (Join-Path $ToolsDir "delete-node.ps1")
    "create-app"  = (Join-Path $ToolsDir "create-app.ps1")
    "shred"       = (Join-Path $ToolsDir "shred.ps1")
    "file-shift"  = (Join-Path $ToolsDir "file-shift.ps1")
    "claude"      = "$env:USERPROFILE\.local\bin\claude.exe"
}

$NavFunctions = [ordered]@{
    "dl"   = "Set-Location $env:USERPROFILE\Downloads"
    "proj" = "Set-Location $env:USERPROFILE\Projects"
}

# Drop aliases whose target doesn't exist so profiles don't fill with
# dead aliases on machines missing optional tools (sysinternals, git unix utils)
$Aliases = [ordered]@{}
foreach ($entry in $Aliases.GetEnumerator()) {
    $value = $entry.Value
    $isCmdlet = $value -notmatch '\.(exe|ps1)$'
    if ($isCmdlet -or (Test-Path $value)) {
        $Aliases[$entry.Key] = $value
    }
    else {
        Write-Host "  Skipping alias '$($entry.Key)' - target not found: $value" -ForegroundColor DarkYellow
    }
}

# Explicitly target all the profiles you want to sync
# $TargetPaths = @(
#     "C:\Users\THEGREMLIN\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
#     "C:\Users\Renaldo\Documents\PowerShell\Microsoft.VSCode_profile.ps1",
#     "C:\Users\Regi\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
# )

if ($AllUsers) {
    Write-Host "Scanning system for user profiles..." -ForegroundColor Cyan

    # Find all actual user directories in C:\Users (excluding system paths like Public, All Users, Default)
    $ExcludeUsers = @('Public', 'Default', 'Default User', 'All Users')
    $UserDirs = Get-ChildItem -Path "C:\Users" -Directory |
        Where-Object { $_.Name -notin $ExcludeUsers }

    $userNames = @($UserDirs | ForEach-Object { $_.Name }) -join ", "
    Write-Host "`n[!] About to modify PowerShell profiles for ALL users: $userNames" -ForegroundColor Red
    $confirm = Read-Host "Type 'SYNC' to continue"
    if ($confirm -ne "SYNC") {
        Write-Host "Aborted. Nothing was modified." -ForegroundColor Cyan
        exit 0
    }
}
else {
    # Default: only the current user - safe, no cross-profile writes
    $UserDirs = @(Get-Item $env:USERPROFILE)
}

# Dynamic array to hold all generated target profile paths
$TargetPaths = @()

foreach ($UserDir in $UserDirs) {
    $BaseDocPath = Join-Path -Path $UserDir.FullName -ChildPath "Documents\PowerShell"
    $AnotherBaseDocPath = Join-Path -Path $UserDir.FullName -ChildPath "Documents\WindowsPowerShell"

    # Generate both native PowerShell and VS Code profile paths for this user
    $TargetPaths += Join-Path -Path $BaseDocPath -ChildPath "Microsoft.PowerShell_profile.ps1"
    $TargetPaths += Join-Path -Path $BaseDocPath -ChildPath "Microsoft.VSCode_profile.ps1"
    $TargetPaths += Join-Path -Path $AnotherBaseDocPath -ChildPath "Microsoft.PowerShell_profile.ps1"
}

foreach ($ProfilePath in $TargetPaths) {
    Write-Host "`nTarget Profile: $ProfilePath" -ForegroundColor Cyan

    # 1. Extract the parent directory path
    $ParentDir = Split-Path -Path $ProfilePath -Parent

    # 2. Force create the parent directory if it doesn't exist
    if (-not (Test-Path -Path $ParentDir)) {
        Write-Host "  Directory not found. Creating: $ParentDir" -ForegroundColor Yellow
        New-Item -Path $ParentDir -ItemType Directory -Force | Out-Null
    }

    # 3. Create the profile file if it doesn't exist
    if (-not (Test-Path -Path $ProfilePath)) {
        Write-Host "  Profile file not found. Creating a new one..." -ForegroundColor Yellow
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
    }

    # 4. Append the aliases cleanly
    $CurrentContent = if (Test-Path -Path $ProfilePath) { @(Get-Content -Path $ProfilePath) } else { @() }
    foreach ($Alias in $Aliases.GetEnumerator()) {
        $AliasLine = "Set-Alias -Name `"$($Alias.Key)`" -Value `"$($Alias.Value)`""

        if ($CurrentContent -notcontains $AliasLine) {
            Add-Content -Path $ProfilePath -Value $AliasLine
            Write-Host "    Added: $($Alias.Key) -> $($Alias.Value)" -ForegroundColor Green
            $CurrentContent += $AliasLine
        }
        else {
            Write-Host "    Skipped (Already Exists): $($Alias.Key)" -ForegroundColor DarkGray
        }
    }

    foreach ($Func in $NavFunctions.GetEnumerator()) {
        $FunctionBlock = "function $($Func.Key) { $($Func.Value) }"
        if ($CurrentContent -notcontains $FunctionBlock) {
            Add-Content -Path $ProfilePath -Value $FunctionBlock
            Write-Host "    Added Function: $($Func.Key) () { $($Func.Value) }" -ForegroundColor Green
            $CurrentContent += $FunctionBlock
        }
    }
}

Write-Host "`nDone! Reload your shell profile with '. `$PROFILE' to try them out." -ForegroundColor Green
