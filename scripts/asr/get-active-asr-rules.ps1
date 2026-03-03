Write-Host "Getting currently active ASR Rules for this machine..." -ForegroundColor Cyan

# Define Status Codes
$StatusCodes = @{
    0 = "Disabled"
    1 = "BLOCK MODE (Working)"
    2 = "Audit Mode (Logging Only)"
    6 = "Warn Mode (User can bypass)"
}

# Fetch current Defender preferences
$MpPrefs = Get-MpPreference
$ActiveIds = $MpPrefs.AttackSurfaceReductionRules_Ids
$ActiveActions = $MpPrefs.AttackSurfaceReductionRules_Actions

$ActiveRules = for ($i = 0; $i -lt $ActiveIds.Count; $i++) {
    $Action = [int]$ActiveActions[$i]
    [PSCustomObject]@{
        Number = $($i + 1)
        GUID = $ActiveIds[$i]
        Action = $Action
        Status = $StatusCodes[$Action]
        Description = 0
    }
}

Write-Host "Found $($ActiveRules.Count) currently active ASR Rules" -ForegroundColor Green