# Elevate Check
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# 2. Define the Rule IDs explicitly as a String Array [string[]]
[string[]]$RuleIDs = @(
    "56a863a9-875e-4185-98a7-b882c64b5ce5", # Vulnerable signed drivers
    "7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c", # Adobe Reader child processes
    "d4f940ab-401b-4efc-aadc-ad5f3c50688a", # Office child processes
    "9e6c4e1f-7d60-472d-ba1a-a39ef669e4b2", # Credential stealing LSASS
    "be9ba2d9-53ea-4cdc-84e5-9b1eeee46550", # Executable content from email
    "01443614-cd74-433a-b99e-2ecdc07bfc25", # Prevalence/age check
    "5beb7efe-fd9a-4556-801d-275e5ffc04cc", # Obfuscated scripts
    "d3e037e1-3eb8-44c8-a917-57927947596d", # JS/VBS launching downloads
    "3b576869-a4ec-4529-8536-b80a7769e899", # Office creating exec content
    "75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84", # Office injecting code
    "26190899-1602-49e8-8b27-eb1d0a1ce869", # Office comms child processes
    "e6db77e5-3df2-4cf1-b95a-636979351e5b", # WMI persistence
    "d1e49aac-8f56-4280-b9ba-993a6d77406c", # PSExec/WMI process creation
    "33ddedf1-c6e0-47cb-833e-de6133960387", # Safe Mode reboot block
    "b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4", # Unsigned processes from USB
    "c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb", # Copied system tools
    "a8f5898e-1dc8-49a9-9878-85004b8a61e6", # Webshell creation
    "92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b", # Win32 API from Office macros
    "c1db55ab-c21a-4637-bb3f-a12568109d35"  # Ransomware protection
)

# 3. Create a matching array of integers (1 = Block)
[int[]]$Actions = @(1) * $RuleIDs.Count

# 4. Use Splatting to ensure parameters are passed correctly
$ASRParams = @{
    AttackSurfaceReductionRules_Ids     = $RuleIDs
    AttackSurfaceReductionRules_Actions = $Actions
}

Write-Host "Applying all ASR rules in BLOCK mode..." -ForegroundColor Cyan

try {
    # This command updates the entire set at once
    Set-MpPreference @ASRParams
    Write-Host "✅ Success: All rules applied and validated." -ForegroundColor Green
}
catch {
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
}