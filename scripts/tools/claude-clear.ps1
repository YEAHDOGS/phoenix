# Clean-ClaudeCode.ps1
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

$deletedCount = 0

foreach ($path in $targetPaths) {
    if (Test-Path -Path $path) {
        Write-Host "Found: $path" -ForegroundColor Yellow
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Host " -> Deleted successfully." -ForegroundColor Green
            $deletedCount++
        } catch {
            Write-Host " -> Failed to delete: $_" -ForegroundColor Red
        }
    }
}

if ($deletedCount -eq 0) {
    Write-Host "No global Claude Code files found. Your system is clean." -ForegroundColor Gray
} else {
    Write-Host "Cleanup complete. Removed $deletedCount core item(s)." -ForegroundColor Cyan
}