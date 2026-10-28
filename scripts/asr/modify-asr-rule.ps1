#Requires -RunAsAdministrator

# Maps each accepted action to the Defender mode it sets ('Remove' deletes the rule)
$ActionModes = @{
    'd' = 'Disabled'; 'disable' = 'Disabled'
    'r' = 'Remove';   'remove'  = 'Remove'; 'delete' = 'Remove'
    'a' = 'AuditMode'; 'audit'  = 'AuditMode'
    'b' = 'Enabled';  'block'   = 'Enabled'
}

# Args check - Need at least an action and one GUID
if ($args.Count -lt 2 -or -not $ActionModes.ContainsKey("$($args[0])".ToLower())) {
    Write-Host "`n--- 🛠️ ASR Rule Manager Usage ---" -ForegroundColor Cyan
    Write-Host "Usage:" -NoNewline
    Write-Host "  .\modify-asr-rule.ps1 <action> <guid1> <guid2> ..." -ForegroundColor White

    Write-Host
    Write-Host "Actions:" -ForegroundColor Yellow
    Write-Host "  d, disable        " -NoNewline; Write-Host "- Sets rule to Disabled (0) but keeps it in the list."
    Write-Host "  r, remove, delete " -NoNewline; Write-Host "- Completely deletes the rule from Defender."
    Write-Host "  a, audit          " -NoNewline; Write-Host "- Sets rule to Audit Mode (2) - logs only, does not block."
    Write-Host "  b, block          " -NoNewline; Write-Host "- Sets rule to Block Mode (1) - actively blocks."

    Write-Host
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\modify-asr-rule.ps1 r 56a863a9-875e-4185-98a7-b882c64b5ce5"
    Write-Host "  .\modify-asr-rule.ps1 a 56a863a9-875e-4185-98a7-b882c64b5ce5"
    Write-Host "-------------------------------`n"

    exit 1
}

$Mode = $ActionModes["$($args[0])".ToLower()]

# Get Active ASR Rules from this machine
. ./get-active-asr-rules.ps1

$updateGuids = @()

foreach ($guid in ($args | Select-Object -Skip 1)) {
    $MatchedRule = $ActiveRules | Where-Object { $_.GUID -eq $guid }

    if ($MatchedRule) {
        Write-Host "Matching GUID Found: $($MatchedRule.GUID) Current Status: $($MatchedRule.Status)" -ForegroundColor Red
        if ($Mode -eq 'Remove') {
            Remove-MpPreference -AttackSurfaceReductionRules_Ids $guid
            Write-Host "  Removed Rule $($MatchedRule.GUID)" -ForegroundColor Red
        }
        else {
            $updateGuids += $guid
        }
    }
    else {
        Write-Host "Warning: '$guid' does not match any active rules. Skipping..." -ForegroundColor Yellow
    }
}

if ($updateGuids.Count -gt 0) {
    # NOTE: Add-MpPreference must receive the full GUID/action arrays in a
    # SINGLE call. One call per rule silently drops all but the last.
    $actions = @($updateGuids | ForEach-Object { $Mode })
    Add-MpPreference -AttackSurfaceReductionRules_Ids $updateGuids -AttackSurfaceReductionRules_Actions $actions
    $label = @{ 'Disabled' = 'Disabled'; 'AuditMode' = 'Set to Audit Mode'; 'Enabled' = 'Set to Block Mode' }[$Mode]
    foreach ($g in $updateGuids) {
        Write-Host "  $label - Rule $g" -ForegroundColor Red
    }
}
