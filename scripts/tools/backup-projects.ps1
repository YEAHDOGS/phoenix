param (
    # One or more folders to back up. Paste paths here to skip the menu:
    #   backup-projects -Sources "C:\Users\Me\Projects","D:\Work" -Destination "E:\Backups"
    # Leave blank to pick from an arrow-key menu.
    [Parameter(Position=0)]
    [string[]]$Sources,

    # Folder on the mounted drive where the .zip files are written.
    # Leave blank to use $DefaultDestination from the CONFIG block below.
    [Parameter(Position=1)]
    [string]$Destination,

    # Extra folder names to skip, in addition to $DefaultExclude.
    [string[]]$Exclude = @(),

    # Print what would be zipped without creating anything.
    [switch]$DryRun,

    # After each zip is written, run the archiver's integrity test on it. Roughly doubles the time.
    [switch]$Verify,

    # Compression threads for 7-Zip. 0 = all cores.
    [int]$Threads = 0
)

# ==============================================================================
#  CONFIG - edit these paths to suit your machine
# ==============================================================================

# Where backups live. The default destination is built from this as
#   <BackupRoot>\<year>\<machine name>   e.g. D:\BIGSHIP\backup\2026\DESKTOP-ABC
$BackupRoot = "D:\BIGSHIP\backup"
$DefaultDestination = Join-Path (Join-Path $BackupRoot (Get-Date -Format "yyyy")) $env:COMPUTERNAME

# Folders offered in the arrow-key menu. Relative names are resolved under $HOME;
# full paths (e.g. "D:\Work") are used as-is. Folders that don't exist are hidden.
$MenuFolders = @(
    'Projects'
    'Videos'
    'Documents'
    'Pictures'
    'Music'
    'Games'
)

# Folder names always skipped, at any depth. -Exclude adds to this list.
$DefaultExclude = @('node_modules')

# Zip compression level: 1 fastest ... 5 normal ... 7 good ... 9 ultra (slow on big trees).
$CompressionLevel = 7

# Each folder becomes <Destination>\<FolderName>_<DateStamp>.zip
$DateStamp = Get-Date -Format "yyyy-MM-dd"

# 7-Zip location. If it isn't found, the script falls back to Windows' built-in tar.exe,
# which is slower, single-threaded, and ignores $Threads.
$SevenZipPath = "C:\Program Files\7-Zip\7z.exe"

# ==============================================================================

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "                  FOLDER BACKUP                   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$menuCandidates = $MenuFolders |
    ForEach-Object { if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $HOME $_ } } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container }

function Clean-Path([string]$p) {
    if ($null -eq $p) { return "" }
    return $p.Trim().Trim('"').Trim("'").TrimEnd('\', '/')
}

# --- Arrow-key multi-select menu ---------------------------------------------
# Up/Down move, Space toggles, A toggles all, Enter confirms, Esc cancels.
# The last row lets you paste any other folder path.
function Select-Folders([string[]]$Options) {
    if ([Console]::IsInputRedirected -or $Host.Name -notmatch 'ConsoleHost') {
        Write-Host "No interactive console. Pass folders with -Sources instead." -ForegroundColor Red
        exit 1
    }

    $items   = [System.Collections.Generic.List[string]]::new($Options)
    $checked = [System.Collections.Generic.List[bool]]::new()
    foreach ($o in $Options) { $checked.Add($true) }
    $otherLabel = "Other... (paste a folder path)"
    $cursor = 0
    $rows = 0   # lines drawn last time, so we can redraw in place

    Write-Host "`nSelect folders to back up:" -ForegroundColor White
    Write-Host "  Up/Down move   Space toggle   A all/none   Enter confirm   Esc cancel`n" -ForegroundColor Gray

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $top = [Console]::CursorTop
            for ($i = 0; $i -le $items.Count; $i++) {
                $isOther = ($i -eq $items.Count)
                $label = if ($isOther) { $otherLabel } else { $items[$i] }
                $box   = if ($isOther) { "   " } elseif ($checked[$i]) { "[x]" } else { "[ ]" }
                $arrow = if ($i -eq $cursor) { ">" } else { " " }
                $line  = " $arrow $box $label".PadRight([Console]::WindowWidth - 1)
                $color = if ($i -eq $cursor) { "Cyan" } elseif (-not $isOther -and $checked[$i]) { "Green" } else { "Gray" }
                Write-Host $line -ForegroundColor $color
            }
            $rows = $items.Count + 1

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $cursor = ($cursor - 1 + $rows) % $rows }
                'DownArrow' { $cursor = ($cursor + 1) % $rows }
                'Spacebar'  { if ($cursor -lt $items.Count) { $checked[$cursor] = -not $checked[$cursor] } }
                'A'         { $all = -not ($checked -contains $false); for ($i = 0; $i -lt $checked.Count; $i++) { $checked[$i] = -not $all } }
                'Escape'    { [Console]::CursorVisible = $true; Write-Host "`nCancelled." -ForegroundColor Yellow; exit }
                'Enter' {
                    if ($cursor -eq $items.Count) {
                        # "Other" row: ask for a path, add it as a checked item, then redraw.
                        [Console]::CursorVisible = $true
                        $p = Clean-Path (Read-Host " Folder path")
                        [Console]::CursorVisible = $false
                        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) {
                            if ($items -notcontains $p) { $items.Add($p); $checked.Add($true) }
                            $cursor = $items.Count   # stay on "Other" so you can paste another
                        } elseif ($p) {
                            Write-Host " Not a folder: $p" -ForegroundColor Red
                            Start-Sleep -Milliseconds 900
                            [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                            Write-Host "".PadRight([Console]::WindowWidth - 1)
                        }
                        # Clear the Read-Host line so the menu redraws cleanly.
                        [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                        Write-Host "".PadRight([Console]::WindowWidth - 1)
                        [Console]::SetCursorPosition(0, $top)
                        continue
                    }
                    $selected = @()
                    for ($i = 0; $i -lt $items.Count; $i++) { if ($checked[$i]) { $selected += $items[$i] } }
                    if ($selected.Count -eq 0) { continue }   # nothing picked, keep menu open
                    return $selected
                }
            }
            [Console]::SetCursorPosition(0, $top)
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- Pick the archiver --------------------------------------------------------
$use7z = Test-Path -LiteralPath $SevenZipPath -PathType Leaf
if (-not $use7z) {
    $found = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($found) { $SevenZipPath = $found.Source; $use7z = $true }
}
if (-not $use7z -and -not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Neither 7-Zip nor tar.exe was found. Install 7-Zip or set `$SevenZipPath at the top of this script." -ForegroundColor Red
    exit 1
}
$archiver = if ($use7z) { "7-Zip ($SevenZipPath)" } else { "tar.exe (7-Zip not found; slower)" }

# --- Resolve sources ----------------------------------------------------------
if (-not $Sources -or $Sources.Count -eq 0) {
    $Sources = Select-Folders -Options $menuCandidates
}
$Sources = @($Sources | ForEach-Object { Clean-Path $_ } | Where-Object { $_ } | Select-Object -Unique)

$missing = $Sources | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) }
if ($missing) {
    $missing | ForEach-Object { Write-Host "Source folder not found: $_" -ForegroundColor Red }
    exit 1
}

# --- Resolve destination ------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = $DefaultDestination
}
$Destination = Clean-Path $Destination

# The destination drive must actually be mounted before we create anything on it.
$destRoot = [System.IO.Path]::GetPathRoot($Destination)
if (-not (Test-Path -LiteralPath $destRoot)) {
    Write-Host "Drive $destRoot is not mounted (wanted $Destination)." -ForegroundColor Red
    Write-Host "`nMounted drives:" -ForegroundColor Gray
    Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used } |
        ForEach-Object { Write-Host ("  {0}  ({1:N1} GB free)" -f $_.Root, ($_.Free / 1GB)) -ForegroundColor White }
    Write-Host "`nPlug in the drive, or pass -Destination, or change `$BackupRoot at the top of this script." -ForegroundColor Gray
    exit 1
}

# Each source becomes Destination\<folder name>_<date>.zip. Two sources with the same name would collide.
$jobs = foreach ($src in $Sources) {
    $leaf = Split-Path $src -Leaf
    [pscustomobject]@{ Source = $src; Name = $leaf; Zip = Join-Path $Destination "$leaf`_$DateStamp.zip" }
}
$dupes = $jobs | Group-Object Zip | Where-Object Count -gt 1
if ($dupes) {
    $dupes | ForEach-Object { Write-Host "Two sources would both produce $($_.Name). Rename one or pick a different set." -ForegroundColor Red }
    exit 1
}
foreach ($j in $jobs) {
    if ($Destination -ieq $j.Source -or $Destination.StartsWith($j.Source + '\', 'OrdinalIgnoreCase')) {
        Write-Host "Destination $Destination is inside source $($j.Source); the zip would try to include itself." -ForegroundColor Red
        exit 1
    }
}

# --- Summary ------------------------------------------------------------------
$excludeDirs = @($DefaultExclude) + @($Exclude) | Select-Object -Unique
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Host ""
foreach ($j in $jobs) { Write-Host ("  {0}  ->  {1}" -f $j.Source, $j.Zip) -ForegroundColor White }
Write-Host "`nArchiver:    $archiver" -ForegroundColor White
Write-Host "Compression: level $CompressionLevel$(if ($use7z) { ", threads $(if ($Threads -gt 0) { $Threads } else { 'all' })" })" -ForegroundColor White
Write-Host "Excluding:   $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host "Existing zips with the same name are replaced.$(if ($Verify) { ' Each zip is integrity-tested afterwards.' })" -ForegroundColor Gray
if ($DryRun) { Write-Host "`nDRY RUN - nothing written." -ForegroundColor DarkYellow; exit 0 }
Write-Host ""

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

# --- Zip each source ----------------------------------------------------------
$results = @()
$total = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($j in $jobs) {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " $($j.Name)  ->  $(Split-Path $j.Zip -Leaf)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # Write to a temp name first so a crash mid-way never leaves a half-written file with the final name.
    $partial = "$($j.Zip).partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($use7z) {
        # a = add, -tzip = zip format, -ssw = include files open for writing, -bsp1 = progress to stdout
        # -xr!name excludes that folder name at any depth.
        $zArgs = @("a", "-tzip", "-mx=$CompressionLevel", "-mmt=$(if ($Threads -gt 0) { $Threads } else { 'on' })", "-ssw", "-bso0", "-bsp1") +
                 ($excludeDirs | ForEach-Object { "-xr!$_" }) + @($partial, $j.Source)
        & $SevenZipPath @zArgs
        $code = $LASTEXITCODE
        # 7-Zip: 0 ok, 1 warning (e.g. a locked file was skipped), 2+ fatal
        $status = switch ($code) { 0 { "ok" } 1 { "ok (some files skipped)" } default { "FAILED ($code)" } }
    } else {
        # -a picks format from the extension, so name the partial with .zip inside the temp name.
        $partial = "$($j.Zip).partial.zip"
        $tArgs = @("-a", "-c", "-f", $partial, "--options", "zip:compression-level=$CompressionLevel") +
                 ($excludeDirs | ForEach-Object { "--exclude"; $_ }) + @("-C", (Split-Path $j.Source -Parent), $j.Name)
        & tar.exe @tArgs
        $code = $LASTEXITCODE
        $status = if ($code -eq 0) { "ok" } else { "FAILED ($code)" }
    }
    $sw.Stop()

    $sizeMB = 0
    if ($status -notlike "FAILED*") {
        if ($Verify) {
            Write-Host " verifying..." -ForegroundColor Gray
            if ($use7z) { & $SevenZipPath t -bso0 -bsp1 $partial | Out-Null } else { & tar.exe -tf $partial | Out-Null }
            if ($LASTEXITCODE -ne 0) { $status = "FAILED (verify)" }
        }
    }
    if ($status -notlike "FAILED*") {
        Move-Item -LiteralPath $partial -Destination $j.Zip -Force
        $sizeMB = [math]::Round((Get-Item -LiteralPath $j.Zip).Length / 1MB, 1)
    } else {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    $results += [pscustomobject]@{ Folder = $j.Name; Status = $status; SizeMB = $sizeMB; Seconds = [int]$sw.Elapsed.TotalSeconds; Zip = $j.Zip }
}
$total.Stop()

# --- Final report -------------------------------------------------------------
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " SUMMARY  ($([int]$total.Elapsed.TotalSeconds)s total)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
foreach ($r in $results) {
    $color = if ($r.Status -like "FAILED*") { "Red" } elseif ($r.Status -like "*skipped*") { "DarkYellow" } else { "Green" }
    Write-Host ("  {0,-12} {1,-24} {2,10:N1} MB {3,6}s   {4}" -f $r.Folder, $r.Status, $r.SizeMB, $r.Seconds, $r.Zip) -ForegroundColor $color
}

$failed = @($results | Where-Object Status -like "FAILED*").Count
exit $(if ($failed) { 1 } else { 0 })
