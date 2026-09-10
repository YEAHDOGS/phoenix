param (
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Path,

    [Parameter(Position=1)]
    [int]$Passes = 1,

    # Default parallel threads to 16. Adjust based on your CPU.
    [Parameter(Position=2)]
    [int]$ThrottleLimit = 16,

    # Where handle64.exe and sdelete64.exe live. Defaults to $env:SYSINTERNALS_DIR
    # so this works on any machine, not just one hardcoded user folder.
    [Parameter(Mandatory=$false)]
    [string]$SysinternalsDir = $env:SYSINTERNALS_DIR,

    # Skip the destructive confirmation prompt (for scripted use).
    [switch]$Force
)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "                    SHREDDER                      " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Check if the user forgot to provide a target
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Host "Usage:" -ForegroundColor Gray
    Write-Host "  shred <path-to-target> [optional-passes] [optional-threads]" -ForegroundColor White
    Write-Host "`nExamples:" -ForegroundColor Gray
    Write-Host "  shred ./git-folder        <- Shreds directory with 16 parallel threads" -ForegroundColor White
    Write-Host "  shred secrets.docx 3      <- Wipes a file using 3 passes" -ForegroundColor White
    Write-Host "  shred ./large-dir 1 32    <- Max speed: 32 concurrent threads" -ForegroundColor White
    Write-Host "`nSysinternals tools: set the SYSINTERNALS_DIR env var, or pass -SysinternalsDir" -ForegroundColor Gray
    Write-Host "* Note: Must run PowerShell as Administrator to break file locks." -ForegroundColor DarkYellow
    Write-Host "==================================================" -ForegroundColor Cyan
    exit
}

if ([string]::IsNullOrWhiteSpace($SysinternalsDir)) {
    Write-Error "Sysinternals tools not found. Set the SYSINTERNALS_DIR environment variable (folder containing handle64.exe and sdelete64.exe) or pass -SysinternalsDir."
    exit 1
}

$HandleBin = Join-Path $SysinternalsDir "handle64.exe"
$SdeleteBin = Join-Path $SysinternalsDir "sdelete64.exe"

# Verify tools exist
if (-not (Test-Path $HandleBin) -or -not (Test-Path $SdeleteBin)) {
    Write-Error "Could not find handle64.exe or sdelete64.exe in $SysinternalsDir"
    exit 1
}

# FIXED: Ensure relative paths resolve against the active terminal location ($PWD) instead of the script path
if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $AbsPath = Join-Path $PWD $Path
} else {
    $AbsPath = $Path
}
$AbsPath = [System.IO.Path]::GetFullPath($AbsPath).TrimEnd('\')

if (-not (Test-Path $AbsPath)) {
    Write-Error "Target path '$AbsPath' does not exist."
    exit 1
}

# Refuse to shred obvious system roots - one typo should never nuke a machine
$dangerousRoots = @(
    [System.IO.Path]::GetPathRoot($AbsPath),
    $env:SystemRoot,
    $env:USERPROFILE,
    [System.IO.Path]::GetPathRoot($env:SystemRoot)
) | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique

if ($AbsPath -in $dangerousRoots) {
    Write-Error "Refusing to shred '$AbsPath' - looks like a system root or your own profile."
    exit 1
}

Write-Host "[!] Target Acquired: $AbsPath" -ForegroundColor Yellow
Write-Host "[!] This will PERMANENTLY wipe $Passes pass(es). Data is unrecoverable." -ForegroundColor Red

if (-not $Force) {
    $confirm = Read-Host "Type the target's leaf name to confirm ('$([System.IO.Path]::GetFileName($AbsPath))')"
    if ($confirm -ne [System.IO.Path]::GetFileName($AbsPath)) {
        Write-Host "Aborted. Nothing was shredded." -ForegroundColor Cyan
        exit 0
    }
}

# --- Part 1: Break System File Locks ---
Write-Host "[*] Checking for and breaking active file locks..." -ForegroundColor Cyan
$lockList = & $HandleBin -nobanner "$AbsPath" 2>$null
foreach ($line in $lockList) {
    if ($line -match 'pid:\s+(\d+).*hex:\s+([0-9A-Fa-f]+)') {
        $pid = $Matches[1]
        $hex = $Matches[2]
        & $HandleBin -c $hex -p $pid -y > $null 2>&1
    }
}
Start-Sleep -Milliseconds 200

# --- Part 2: Execution Logic ---
if (-not (Test-Path $AbsPath -PathType Container)) {
    Write-Host "[*] Handing file over to SDelete..." -ForegroundColor Cyan
    & $SdeleteBin -q -p $Passes "$AbsPath"
    exit
}

# Gather structural items (@() so a single-file dir still yields an array)
Write-Host "[*] Gathering file system manifest..." -ForegroundColor Cyan
$allFiles = @(Get-ChildItem -Path $AbsPath -Recurse -File -Force -ErrorAction SilentlyContinue)
$allDirs  = @(Get-ChildItem -Path $AbsPath -Recurse -Directory -Force -ErrorAction SilentlyContinue)

$totalCount = $allFiles.Count
Write-Host "[*] Found $totalCount files to shred." -ForegroundColor Cyan

if ($totalCount -eq 0) {
    Write-Host "[*] Directory is empty. Dropping parent folder container..." -ForegroundColor Cyan
    & $SdeleteBin -q -s -r -p $Passes "$AbsPath"
    exit
}

Write-Host "[*] Initializing multi-threaded engine ($ThrottleLimit concurrent threads)..." -ForegroundColor Cyan

$completedCount = 0

# Run parallel shreds, then stream paths into the UI progress engine
$allFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $SBin = $using:SdeleteBin
    $PCount = $using:Passes
    $filePath = $_.FullName

    # Run quietly to save console rendering cycles
    & $SBin -q -p $PCount "$filePath" > $null 2>&1

    # Send path down pipeline
    $filePath
} | ForEach-Object {
    $completedCount++
    $percent = [Math]::Min(100, [Math]::Round(($completedCount / $totalCount) * 100))

    # Clamp path lengths so the UI stays locked on one line
    $displayPath = $_
    if ($displayPath.Length -gt 60) {
        $displayPath = "..." + $displayPath.Substring($displayPath.Length - 57)
    }

    # Draw the smooth progress overlay
    Write-Progress -Activity "Parallel Shredding Engine Running" `
                   -Status "Wiping: $displayPath" `
                   -PercentComplete $percent `
                   -CurrentOperation "$percent% Complete ($completedCount/$totalCount Files)"
}

# Clean up remaining structural directories from bottom to top
Write-Host "`n[*] Purging left-over directory structures..." -ForegroundColor Cyan
$allDirs | Sort-Object Length -Descending | ForEach-Object {
    Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
}

# Eliminate the main root directory shell
Remove-Item $AbsPath -Force -Recurse -ErrorAction SilentlyContinue

Write-Host "[✓] Target successfully annihilated." -ForegroundColor Green
