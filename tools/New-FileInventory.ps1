<#
.SYNOPSIS
    Phoenix utility: JSON inventory of a directory tree (PowerShell twin).

.DESCRIPTION
    Exact contract twin of tools/New-FileInventory.sh for the Windows side.
    Give it a directory (or a single file); it walks the whole tree and writes
    a JSON array with one object per entry:

      { "path": "C:\\data", "type": "file|directory|symlink|other",
        "size_bytes": 1234, "modified_utc": "2026-09-09T20:30:00Z",
        "created_utc": "2026-09-01T12:00:00Z" }

    Same key order, same ISO-8601 UTC timestamps, same path sorting as the
    .sh twin, so inventories are comparable across Windows and Linux.
    On Windows, CreationTimeUtc is real (NTFS tracks birth time), so
    created_utc is populated -- unlike the Linux twin where it is null.

    Best-effort walk: unreadable items are skipped via -ErrorAction
    SilentlyContinue rather than aborting the whole inventory.

.EXAMPLE
    .\tools\New-FileInventory.ps1 -Path 'D:\laptop-backup'
    .\tools\New-FileInventory.ps1 -Path 'D:\laptop-backup' -OutFile '.\inv.json'

    Exit codes: 0 = inventory written | 1 = usage/validation error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

function Die([string]$Message) {
    Write-Error "[New-FileInventory] FATAL: $Message"
    exit 1
}

if (-not (Test-Path -LiteralPath $Path)) { Die "not found: $Path" }

$item = Get-Item -LiteralPath $Path
$all = @($item)
if ($item -is [System.IO.DirectoryInfo]) {
    $all += Get-ChildItem -LiteralPath $Path -Recurse -Force `
        -ErrorAction SilentlyContinue
}

$entries = foreach ($i in $all) {
    $isLink = ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isLink) { $type = 'symlink' }
    elseif ($i -is [System.IO.DirectoryInfo]) { $type = 'directory' }
    elseif ($i -is [System.IO.FileInfo]) { $type = 'file' }
    else { $type = 'other' }

    [ordered]@{
        path         = $i.FullName
        type         = $type
        size_bytes   = if ($type -eq 'file') { $i.Length } else { $null }
        modified_utc = $i.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        created_utc  = $i.CreationTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

$sorted = @($entries | Sort-Object path)

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $base = if ($item.Name) { $item.Name } else { 'root' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $OutFile = Join-Path (Get-Location) "$base-inventory-$stamp.json"
}

$json = $sorted | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($OutFile, $json + "`n",
    [System.Text.Encoding]::UTF8)

"[New-FileInventory] wrote $OutFile ($($sorted.Count) entries)"
