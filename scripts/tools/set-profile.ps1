# Define your 3 aliases
$Aliases = [ordered]@{
    "gpr"         = "Get-Process"
    "strings"     = "C:\Users\Brando\Documents\.MY-DOCUMENTS\sysinternals\strings64.exe"
    "bash"        = "C:\toolbox\git\bin\bash.exe"
    "sh"          = "C:\toolbox\git\bin\sh.exe"
    "file"        = "C:\toolbox\git\bin\file.exe -m C:\toolbox\git\bin\magic.mgc"
    "head"        = "C:\toolbox\git\bin\head.exe"
    "sha512sum"   = "C:\toolbox\git\bin\sha512sum.exe"
    "sha256sum"   = "C:\toolbox\git\bin\sha256sum.exe"
    "gpg"         = "C:\toolbox\git\bin\gpg.exe"
    "yes"         = "C:\toolbox\git\bin\yes.exe"
    "ldd"         = "C:\toolbox\git\bin\ldd.exe"
    "git-fucked"  = "C:\Users\Brando\Projects\phoenix\scripts\git\git-fucked.ps1"
    "delete-node" = "C:\Users\Brando\Projects\phoenix\scripts\tools\delete-node.ps1"
    "create-app"  = "C:\Users\Brando\Projects\phoenix\scripts\tools\create-app.ps1"
    "shred"       = "C:\Users\Brando\Projects\phoenix\scripts\tools\shred.ps1"
    "file-shift"  = "C:\Users\Brando\Projects\phoenix\scripts\tools\file-shift.ps1"
}

$NavFunctions = [ordered]@{
    "dl"   = "Set-Location C:\Users\Brando\Downloads"
    "proj" = "Set-Location C:\Users\Brando\Projects"
}

# Explicitly target all the profiles you want to sync
# $TargetPaths = @(
#     "C:\Users\THEGREMLIN\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
#     "C:\Users\Renaldo\Documents\PowerShell\Microsoft.VSCode_profile.ps1",
#     "C:\Users\Regi\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
# )

Write-Host "Scanning system for user profiles..." -ForegroundColor Cyan

# Find all actual user directories in C:\Users (excluding system paths like Public, All Users, Default)
$ExcludeUsers = @('Public', 'Default', 'Default User', 'All Users')
$UserDirs = Get-ChildItem -Path "C:\Users" -Directory | 
Where-Object { $_.Name -notin $ExcludeUsers }

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
    foreach ($Alias in $Aliases.GetEnumerator()) {
        $AliasLine = "Set-Alias -Name `"$($Alias.Key)`" -Value `"$($Alias.Value)`""
        
        # Get content or default to empty array if file is brand new/empty
        $CurrentContent = if (Test-Path -Path $ProfilePath) { Get-Content -Path $ProfilePath } else { @() }
        
        if ($CurrentContent -notcontains $AliasLine) {
            Add-Content -Path $ProfilePath -Value $AliasLine
            Write-Host "    Added: $($Alias.Key) -> $($Alias.Value)" -ForegroundColor Green
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
        }
    }
}

Write-Host "`nDone! Reload your shell profile with '. `$PROFILE' to try them out." -ForegroundColor Green