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

$validGuids = @()

foreach ($guid in $args) {
    # Check if the passed GUID exists in our ruleset's GUID column
    if ($OnlineRules.GUID -contains $guid) {
        # Find the specific rule object to get the description for the log
        $matchedRule = $OnlineRules | Where-Object { $_.GUID -eq $guid }

        Write-Host "Valid Rule Found: $($matchedRule.Description)" -ForegroundColor Green
        Write-Host "   Adding ID: $($guid)" -ForegroundColor Gray
        $validGuids += $guid
    }
    else {
        Write-Host "Warning: '$guid' is not a recognized ASR Rule GUID. Skipping..." -ForegroundColor Yellow
    }
}

if ($validGuids.Count -eq 0) {
    Write-Error "No valid rule GUIDs supplied. Nothing to do."
    exit 1
}

# NOTE: Add-MpPreference must receive the full GUID/action arrays in a SINGLE
# call. Calling it once per rule in a loop silently leaves only the last rule
# applied, which previously dropped every GUID but the final one.
$actions = @($validGuids | ForEach-Object { "Enabled" })

Add-MpPreference -AttackSurfaceReductionRules_Ids $validGuids -AttackSurfaceReductionRules_Actions $actions

Write-Host "`nSuccess: $($validGuids.Count) rule(s) applied." -ForegroundColor Green