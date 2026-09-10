#Requires -RunAsAdministrator

. ./fetch-asr-rules

if (-not $OnlineRules -or $OnlineRules.Count -eq 0) {
    Write-Error "No ASR rules available to disable. Fetch failed and no stored ruleset found."
    exit 1
}

Write-Host "Disabling all $($OnlineRules.Count) ASR rules..." -ForegroundColor Cyan

# NOTE: Add-MpPreference must receive the full GUID/action arrays in a SINGLE
# call. Calling it once per rule in a loop silently leaves only the last rule
# applied, which previously made this script a no-op for everything but rule #N.
$guids   = @($OnlineRules | ForEach-Object { $_.GUID })
$actions = @($OnlineRules | ForEach-Object { "Disabled" })

Add-MpPreference -AttackSurfaceReductionRules_Ids $guids -AttackSurfaceReductionRules_Actions $actions

Write-Host "`nSuccess: $($guids.Count) rules disabled. Run check-asr-rules.ps1 to verify." -ForegroundColor Green
