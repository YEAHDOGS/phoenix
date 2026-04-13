#Requires -RunAsAdministrator

. ./fetch-asr-rules

Write-Host "Disabling all ASR rules..." -ForegroundColor Cyan

foreach ($Rule in $OnlineRules) {
    Write-Host "❌ Disabling Rule: $($Rule.GUID) : Status: $($Rule.Status) : Description : $($Rule.Description)" -ForegroundColor Red
    Add-MpPreference -AttackSurfaceReductionRules_Ids $Rule.GUID -AttackSurfaceReductionRules_Actions Disabled
}

Write-Host "`nSuccess: All rules disabled." -ForegroundColor Green