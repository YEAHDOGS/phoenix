# Phoenix engine: shared helpers. Owned by the engine core; other lib files may call these.

# C:\ProgramData\Phoenix - state, logs, snapshots, installed kit (machine scope).
function Get-PhxDataRoot {
    $root = Join-Path $env:ProgramData 'Phoenix'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $root
}

# %LOCALAPPDATA%\Phoenix\cache - loadout downloads on the build PC.
function Get-PhxCacheRoot {
    $root = Join-Path $env:LOCALAPPDATA 'Phoenix\cache'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $root
}

# The kit root: the folder holding engine\, packs\, loadout\. In the repo that
# is the repo root; on the USB it is <USB>\phoenix; installed, C:\ProgramData\Phoenix\kit.
function Get-PhxKitRoot { $PhxRepoRoot }

function Get-PhxPacksRoot { Join-Path (Get-PhxKitRoot) 'packs' }

# Resolution order: explicit path, %APPDATA%\Phoenix, kit's phoenix.config.json
# (USB / installed kit), then the repo example.
function Resolve-PhxConfigPath([string]$Path) {
    $candidates = @(
        $Path
        (Join-Path $env:APPDATA 'Phoenix\phoenix.config.json')
        (Join-Path (Get-PhxKitRoot) 'phoenix.config.json')
        (Join-Path (Get-PhxKitRoot) 'config\phoenix.example.json')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }
    throw "No Phoenix config found (looked in: $($candidates -join '; '))"
}

function Read-PhxJson([string]$Path) {
    ConvertTo-PhxHashtable (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-PhxJson([string]$Path, $Object, [int]$Depth = 12) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth $Depth), [Text.UTF8Encoding]::new($false))
}

function Get-PhxConfig([string]$Path) {
    $p = Resolve-PhxConfigPath $Path
    $cfg = Read-PhxJson $p
    $cfg['_path'] = $p
    $cfg
}

function Assert-PhxAdmin([string]$What = 'This command') {
    if (-not (Test-PhxIsAdmin)) { throw "NEEDS_ADMIN: $What must run elevated." }
}

# Reads and deletes a secrets file ({ "admin": "pw", "lead": "pw", "users": { "name": "pw" } }).
function Read-PhxSecrets([string]$Path) {
    if (-not $Path) { return @{} }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Secrets file not found: $Path" }
    try { return (Read-PhxJson $Path) }
    finally { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Get-PhxSha([string]$Path, [ValidateSet('SHA256', 'SHA512')][string]$Algorithm = 'SHA512') {
    (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLower()
}
