# Check for elevated privelages
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator."
    exit 1
}

# Args check
if ($args.Count -lt 1) {
    Write-Error "No arguments provided, add some GUIDs!"
    exit 1
}

# Fetch online ASR Rules from Microsoft
. ./fetch-asr-rules.ps1

foreach ($guid in $args) {
    # Check if the passed GUID exists in our ruleset's GUID column
    if ($ruleset.GUID -contains $guid) {
        # Find the specific rule object to get the description for the log
        $matchedRule = $ruleset | Where-Object { $_.GUID -eq $guid }
        
        Write-Host "✅ Valid Rule Found: $($matchedRule.Description)" -ForegroundColor Green
        Write-Host "   Adding ID: $($guid)" -ForegroundColor Gray

        # Apply the rule (Set to 1 for 'Block' or 'Enabled')
        Add-MpPreference -AttackSurfaceReductionRules_Ids $guid -AttackSurfaceReductionRules_Actions Enabled
    }
    else {
        Write-Host "❌ Warning: '$guid' is not a recognized ASR Rule GUID. Skipping..." -ForegroundColor Yellow
    }
}