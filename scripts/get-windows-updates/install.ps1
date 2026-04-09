# $ID = "INSERT-UPDATE-ID-HERE"; $u = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0").Updates | Where-Object { $_.Identity.UpdateID -eq $ID }; $c = New-Object -ComObject Microsoft.Update.UpdateColl; $c.Add($u) | Out-Null; Write-Host "Downloading: $($u.Title)" -ForegroundColor Yellow; $d = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateDownloader(); $d.Updates = $c; $d.Download() | Out-Null; Write-Host "Installing..." -ForegroundColor Green; $i = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller(); $i.Updates = $c; $r = $i.Install(); Write-Host "Result Code: $($r.ResultCode) (2=Success, 3=Reboot Required)" -ForegroundColor Cyan

param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$UpdateID
)

# Initialize the Update Session
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()

Write-Host "Searching for Update ID: $UpdateID..." -ForegroundColor Cyan

# Search for the specific uninstalled update
$u = $searcher.Search("IsInstalled=0").Updates | Where-Object { $_.Identity.UpdateID -eq $UpdateID }

if ($null -eq $u) {
    Write-Host "Error: Could not find an applicable, uninstalled update with ID $UpdateID." -ForegroundColor Red
    exit
}

# Create a collection and add the update
$c = New-Object -ComObject Microsoft.Update.UpdateColl
$c.Add($u) | Out-Null

# Download Phase
Write-Host "Downloading: $($u.Title)" -ForegroundColor Yellow
$downloader = $session.CreateUpdateDownloader()
$downloader.Updates = $c
$downloader.Download() | Out-Null

# Install Phase
Write-Host "Installing..." -ForegroundColor Green
$installer = $session.CreateUpdateInstaller()
$installer.Updates = $c
$result = $installer.Install()

# Output Result
# ResultCode: 2 = Success, 3 = Success (Reboot Required)
$statusColor = if ($result.ResultCode -eq 2 -or $result.ResultCode -eq 3) { "Cyan" } else { "Red" }
Write-Host "Result Code: $($result.ResultCode) (2=Success, 3=Reboot Required)" -ForegroundColor $statusColor