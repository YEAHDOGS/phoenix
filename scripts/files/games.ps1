# Define the source and destination paths
$sourcePath = "C:\Program Files (x86)\Steam\steamapps\common"
$destinationFolder = "$env:USERPROFILE\Games"
$shortcutPath = Join-Path $destinationFolder "Steam Common.lnk"

# Check if the destination folder exists; if not, create it
if (-not (Test-Path $destinationFolder)) {
    New-Item -ItemType Directory -Path $destinationFolder | Out-Null
    Write-Host "Created destination folder: $destinationFolder" -ForegroundColor Cyan
}

# Create the shortcut using COM object
try {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $sourcePath
    $shortcut.Save()

    Write-Host "Shortcut successfully created at: $shortcutPath" -ForegroundColor Green
}
catch {
    Write-Error "Failed to create shortcut: $_"
}