# $u = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0").Updates; Write-Host "Total Updates Found: $($u.Count)" -ForegroundColor Cyan; ($u | Select-Object Title, Description, LastDeploymentChangeTime, @{Name = "Type"; Expression = { if ($_.DriverClass) { "Hardware" } else { "Software" } } }, @{Name = "Classification"; Expression = { ($_.Categories | Where-Object { $_.Type -eq 'UpdateClassification' } | Select-Object -ExpandProperty Name) -join ', ' } }, @{Name = "DriverClass"; Expression = { $_.DriverClass } }, @{Name = "DriverModel"; Expression = { $_.DriverModel } }, @{Name = "Manufacturer"; Expression = { $_.DriverManufacturer } }, @{Name = "Provider"; Expression = { $_.DriverProvider } }, IsMandatory, @{Name = "IsTrusted"; Expression = { $_.IsTrusted } }, @{Name = "NeedsReboot"; Expression = { $_.InstallationBehavior.RebootBehavior -eq 1 } }, @{Name = "Size(MB)"; Expression = { "{0:N2}" -f ($_.MaxDownloadSize / 1MB) } }, @{Name = "DeploymentID"; Expression = { $_.DeploymentAction } }, @{Name = "UpdateID"; Expression = { $_.Identity.UpdateID } }, @{Name = "Identity.RevisionNumber"; Expression = { $_.Identity.RevisionNumber } }, EulaUrl, UninstallationNotes | Sort-Object Title | Format-List); Write-Host "Total Updates Found: $($u.Count)" -ForegroundColor Cyan

# Initialize Session
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()

Clear-Host
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "   WINDOWS UPDATE SCANNER   " -ForegroundColor White -BackGroundColor DarkMagenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Perform Search
Write-Host "[*] Scanning for applicable updates..." -ForegroundColor Yellow
$u = $searcher.Search("IsInstalled=0 and IsHidden=0").Updates

if ($u.Count -eq 0) {
    Write-Host "[+] Your system is up to date! No updates found." -ForegroundColor Green
    return
}

Write-Host "[!] Found $($u.Count) updates available." -ForegroundColor Cyan
Write-Host ""

# Display formatted results
$u | Select-Object `
@{Name = "TITLE"; Expression = { $_.Title } },
@{Name = "TYPE"; Expression = { if ($_.DriverClass) { "Hardware/Driver" } else { "Software" } } },
@{Name = "CLASSIFICATION"; Expression = { ($_.Categories | Where-Object { $_.Type -eq 'UpdateClassification' } | Select-Object -ExpandProperty Name) -join ', ' } },
@{Name = "SIZE (MB)"; Expression = { "{0:N2}" -f ($_.MaxDownloadSize / 1MB) } },
@{Name = "REBOOT REQ."; Expression = { if ($_.InstallationBehavior.RebootBehavior -ge 1) { "Yes" } else { "No" } } },
@{Name = "UPDATE ID"; Expression = { $_.Identity.UpdateID } },
@{Name = "DESCRIPTION"; Expression = { $_.Description } },
@{Name = "RELEASE DATE"; Expression = { $_.LastDeploymentChangeTime.ToString("yyyy-MM-dd") } } | 
Sort-Object TITLE | 
Format-List

Write-Host "========================================" -ForegroundColor Magenta
Write-Host "Total Updates Found: $($u.Count)" -ForegroundColor Cyan
Write-Host "Copy an Update ID and use it with the install script." -ForegroundColor Gray