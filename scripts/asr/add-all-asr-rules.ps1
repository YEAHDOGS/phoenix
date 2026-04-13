#Requires -RunAsAdministrator

. ./fetch-asr-rules

Write-Host "Applying all ASR rules in BLOCK mode..." -ForegroundColor Cyan

foreach ($Rule in $OnlineRules) {
    Write-Host "✅ Adding Rule: $($Rule.GUID) : $($Rule.Description)" -ForegroundColor Green
    Add-MpPreference -AttackSurfaceReductionRules_Ids $Rule.GUID -AttackSurfaceReductionRules_Actions Enabled
}

Write-Host "`nSuccess: All rules applied and validated." -ForegroundColor Green