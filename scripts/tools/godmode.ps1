# This script adds the GodMode Windows app to the desktop

# Define the special folder name
$folderName = "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"

# Get the Desktop path
$desktopPath = Join-Path -Path ([System.Environment]::GetFolderPath("Desktop")) -ChildPath $folderName

# Check if it exists and create it
if (-not (Test-Path -Path $desktopPath)) {
    New-Item -Path $desktopPath -ItemType Directory -Force
    Write-Host "Success! The 'God Mode' folder has been created on your Desktop." -ForegroundColor Cyan
}
else {
    Write-Host "The folder already exists at: $desktopPath" -ForegroundColor Yellow
}