# Check for elevated privilages
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator."
    exit 1
}

$ValidActions = @('d', 'r', 'disable', 'remove')

# Args check - Need at least an action and one GUID
if ($args.Count -lt 2 -or $args[0] -notin $ValidActions) {
    Write-Host "`n--- 🛠️ ASR Rule Remover Usage ---" -ForegroundColor Cyan
    Write-Host "Usage:" -NoNewline
    Write-Host "  .\remove-asr-rule.ps1 <action> <guid1> <guid2> ..." -ForegroundColor White
    
    Write-Host
    Write-Host "Actions:" -ForegroundColor Yellow
    Write-Host "  d, disable " -NoNewline; Write-Host "- Sets rule to Disabled (0) but keeps it in the list."
    Write-Host "  r, remove  " -NoNewline; Write-Host "- Completely deletes the rule from Defender."
    
    Write-Host
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host "  .\remove-asr-rule.ps1 r 56a863a9-875e-4185-98a7-b882c64b5ce5"
    Write-Host "-------------------------------`n"
    
    exit 1
}

$RemovalType = $args[0]

# Get Active ASR Rules from this machine
. ./get-active-asr-rules.ps1

foreach ($guid in ($args | Select-Object -Skip 1)) {
    $MatchedRule = $ActiveRules | Where-Object { $_.GUID -eq $guid }

    if ($MatchedRule) {
        Write-Host "❌ Matching GUID Found: $($MatchedRule.GUID) Current Status: $($MatchedRule.Status)" -ForegroundColor Red
        if($RemovalType -in @('d', 'disable')) {
            Add-MpPreference -AttackSurfaceReductionRules_Ids $guid -AttackSurfaceReductionRules_Actions Disabled
            Write-Host "  Disabled Rule $($MatchedRule.GUID)" -ForegroundColor Red
        } else {
            Remove-MpPreference -AttackSurfaceReductionRules_Ids $guid
            Write-Host "  Removed Rule $($MatchedRule.GUID)" -ForegroundColor Red
        }
    } 
    else {
        Write-Host "❌ Warning: '$guid' does not match any active rules. Skipping..." -ForegroundColor Yellow
    }
}