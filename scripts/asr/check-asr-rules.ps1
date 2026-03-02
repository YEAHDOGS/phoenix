Write-Host "`n--- Microsoft ASR Rule Configuration Report ---" -ForegroundColor Blue

# Get Active ASR Rules from this machine
. ./get-active-asr-rules.ps1

# Fetch available ASR Rules from Microsoft
. ./fetch-asr-rules.ps1

foreach ($Rule in $ActiveRules) {
    $MatchedRule = $ruleset | Where-Object { $_.GUID -eq $Rule.GUID }

    if ($MatchedRule) {
        # If found, assign the description from the master list
        $Rule.Description = $MatchedRule.Description
    } 
    else {
        # If the GUID exists in Defender but not in Microsoft's documentation
        $Rule.Description = "---INVALID ENTRY (Guid not found in Microsoft Documentation)"
    }
}

Write-Host "`n--- $($ActiveRules.Count) Active ASR Rules found on this machine ---" -ForegroundColor Blue
$ActiveRules | Format-Table -AutoSize