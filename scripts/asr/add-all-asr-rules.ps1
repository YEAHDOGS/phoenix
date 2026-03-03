# Check for elevated privilages
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator."
    exit 1
}

. ./fetch-asr-rules

Write-Host "Applying all ASR rules in BLOCK mode..." -ForegroundColor Cyan

foreach ($Rule in $OnlineRules) {
    Write-Host "✅ Adding Rule: $($Rule.GUID) : $($Rule.Description)" -ForegroundColor Green
    Add-MpPreference -AttackSurfaceReductionRules_Ids $Rule.GUID -AttackSurfaceReductionRules_Actions Enabled
}

Write-Host "`nSuccess: All rules applied and validated." -ForegroundColor Green