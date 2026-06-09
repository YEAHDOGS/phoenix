Write-Host "`n--- Microsoft ASR Rule Configuration Report ---" -ForegroundColor Blue

# Get Active ASR Rules from this machine
. ./get-active-asr-rules.ps1

# Fetch available ASR Rules from Microsoft
. ./fetch-asr-rules.ps1

foreach ($Rule in $ActiveRules) {
    $MatchedRule = $OnlineRules | Where-Object { $_.GUID -eq $Rule.GUID }

    if ($MatchedRule) {
        # If found, assign the description from the master list
        $Rule.Description = $MatchedRule.Description
    } 
    else {
        # If the GUID exists in Defender but not in Microsoft's documentation
        $Rule.Description = "---INVALID ENTRY (Guid not found in Microsoft Documentation)"
    }
}

$ActiveRules | Format-Table -AutoSize

Write-Host "`n--- $($OnlineRules.Count) Fetched ASR Rules ---" -ForegroundColor Blue
Write-Host "`--- $($ActiveRules.Count) ASR Rules found on this machine ---" -ForegroundColor Blue

if ($ActiveRules.Count -eq 0) {
    Write-Host "`n[Warning] No ASR rules are currently active on this machine. This may indicate that ASR is not configured or enabled." -ForegroundColor Red
}

if ($OnlineRules.Count -ne $ActiveRules.Count) {
    Write-Host "`n[Warning] The number of ASR rules on this machine does not match the number of rules fetched from Microsoft. This may indicate missing or extra rules." -ForegroundColor Yellow
}

if ($OnlineRules.Count -eq $ActiveRules.Count) {
    Write-Host "`n[Success] The number of ASR rules active on this machine matches the number of rules fetched from Microsoft." -ForegroundColor Green
}