$path = "$env:SystemRoot\System32\drivers\etc\hosts"

if (Test-Path $path) {
    # Get-Content reads the file
    Get-Content $path
}
else {
    Write-Host "Hosts file not found." -ForegroundColor Red
}