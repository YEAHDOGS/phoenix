# Check for elevated privilages
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator."
    exit 1
}

. ./fetch-asr-rules

Write-Host "Disabling all ASR rules..." -ForegroundColor Cyan

foreach ($Rule in $OnlineRules) {
    Write-Host "❌ Disabling Rule: $($Rule.GUID) : Status: $($Rule.Status) : Description : $($Rule.Description)" -ForegroundColor Red
    Add-MpPreference -AttackSurfaceReductionRules_Ids $Rule.GUID -AttackSurfaceReductionRules_Actions Disabled
}

Write-Host "`nSuccess: All rules disabled." -ForegroundColor Green