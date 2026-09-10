#Requires -RunAsAdministrator

. ./fetch-asr-rules

if (-not $OnlineRules -or $OnlineRules.Count -eq 0) {
    Write-Error "No ASR rules available to apply. Fetch failed and no stored ruleset found."
    exit 1
}

Write-Host "Applying all $($OnlineRules.Count) ASR rules in BLOCK mode..." -ForegroundColor Cyan

# NOTE: Add-MpPreference must receive the full GUID/action arrays in a SINGLE
# call. Calling it once per rule in a loop silently leaves only the last rule
# applied, which previously made this script a no-op for everything but rule #N.
$guids   = @($OnlineRules | ForEach-Object { $_.GUID })
$actions = @($OnlineRules | ForEach-Object { "Enabled" })

Add-MpPreference -AttackSurfaceReductionRules_Ids $guids -AttackSurfaceReductionRules_Actions $actions

Write-Host ""
foreach ($Rule in $OnlineRules) {
    Write-Host "  [+] $($Rule.GUID) : $($Rule.Description)" -ForegroundColor DarkGray
}

Write-Host "`nSuccess: $($guids.Count) rules applied. Run check-asr-rules.ps1 to verify." -ForegroundColor Green
