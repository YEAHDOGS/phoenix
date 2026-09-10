<#
.SYNOPSIS
    claude-clear.ps1 - Nukes all global Claude Code installs/configs on this machine.

.DESCRIPTION
    DESTRUCTIVE. Permanently deletes Claude Code binaries, configs, and auth
    state (including ~/.claude.json, which holds login tokens). Always prompts
    for confirmation unless -Force is passed.
#>
param (
    [switch]$Force
)
$ErrorActionPreference = "Continue"

Write-Host "Starting cleanup of Claude Code core files..." -ForegroundColor Cyan

# Array of all known Claude Code directories and files
$targetPaths = @(
    "$env:USERPROFILE\.claude",
    "$env:USERPROFILE\.claude.json",
    "$env:USERPROFILE\.local\share\claude",
    "$env:USERPROFILE\.local\bin\claude.exe",
    "$env:APPDATA\Claude Code",
    "$env:LOCALAPPDATA\Claude Code",
    "$env:APPDATA\claude",
    "$env:LOCALAPPDATA\claude"
)

$existing = @($targetPaths | Where-Object { Test-Path -Path $_ })

if ($existing.Count -eq 0) {
    Write-Host "No global Claude Code files found. Your system is clean." -ForegroundColor Gray
    exit 0
}

Write-Host "`n[!] This will PERMANENTLY DELETE the following ($($existing.Count) item(s)):" -ForegroundColor Red
foreach ($path in $existing) {
    Write-Host "    - $path" -ForegroundColor Yellow
}
Write-Host "    (includes auth state: ~/.claude.json holds login tokens)" -ForegroundColor DarkYellow

if (-not $Force) {
    $confirm = Read-Host "`nType 'DELETE' to confirm this wipe"
    if ($confirm -ne "DELETE") {
        Write-Host "Aborted. Nothing was deleted." -ForegroundColor Cyan
        exit 0
    }
}

$deletedCount = 0

foreach ($path in $existing) {
    try {
        Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
        Write-Host " -> Deleted: $path" -ForegroundColor Green
        $deletedCount++
    } catch {
        Write-Host " -> Failed to delete: $path ($_)" -ForegroundColor Red
    }
}

Write-Host "`nCleanup complete. Removed $deletedCount core item(s)." -ForegroundColor Cyan
