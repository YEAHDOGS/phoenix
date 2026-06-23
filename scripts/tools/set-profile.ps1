# Define your 3 aliases
$Aliases = [ordered]@{
    "gpr"         = "Get-Process"
    "strings"     = "C:\Users\Brando\Documents\.MY-DOCUMENTS\sysinternals\strings64.exe"
    "bash"        = "C:\Users\Brando\AppData\Local\Programs\Git\bin\bash.exe"
    "sh"          = "C:\Users\Brando\AppData\Local\Programs\Git\bin\sh.exe"
    "file"        = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\file.exe"
    "head"        = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\head.exe"
    "sha512sum"   = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\sha512sum.exe"
    "sha256sum"   = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\sha256sum.exe"
    "gpg"         = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\gpg.exe"
    "yes"         = "C:\Users\Brando\AppData\Local\Programs\Git\usr\bin\yes.exe"
    "git-fucked"  = "C:\Users\Brando\Projects\get-it-goin\scripts\git\git-fucked.ps1"
    "delete-node" = "C:\Users\Brando\Projects\get-it-goin\scripts\tools\delete-node.ps1"
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