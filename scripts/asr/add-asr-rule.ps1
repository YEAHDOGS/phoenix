#Requires -RunAsAdministrator

# Args check
if ($args.Count -lt 2 -or $args[0] -notin $ValidActions) {
    Write-Host "`n--- 🛠️ ASR Rule Add Usage ---" -ForegroundColor Cyan
    Write-Host "Usage:" -NoNewline
    Write-Host "  .\add-asr-rule.ps1 <guid1> <guid2> ..." -ForegroundColor White
    
    Write-Host
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host "  .\add-asr-rule.ps1 75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84 01443614-cd74-433a-b99e-2ecdc07bfc25"
    Write-Host "-------------------------------`n"
    
    exit 1
}

# Fetch online ASR Rules from Microsoft
. ./fetch-asr-rules.ps1

foreach ($guid in $args) {
    # Check if the passed GUID exists in our ruleset's GUID column
    if ($OnlineRules.GUID -contains $guid) {
        # Find the specific rule object to get the description for the log
        $matchedRule = $OnlineRules | Where-Object { $_.GUID -eq $guid }
        
        Write-Host "✅ Valid Rule Found: $($matchedRule.Description)" -ForegroundColor Green
        Write-Host "   Adding ID: $($guid)" -ForegroundColor Gray

        # Apply the rule (Set to 1 for 'Block' or 'Enabled')
        Add-MpPreference -AttackSurfaceReductionRules_Ids $guid -AttackSurfaceReductionRules_Actions Enabled
    }
    else {
        Write-Host "❌ Warning: '$guid' is not a recognized ASR Rule GUID. Skipping..." -ForegroundColor Yellow
    }
}