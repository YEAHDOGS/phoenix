param (
    [switch]$TableView  # Allows running the script with -TableView or -t if aliased
)

#Requires -RunAsAdministrator

# Import, initialize
. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "DISM_Features"

Write-Host "Gathering Windows features via DISM..." -ForegroundColor Cyan

# ///////////////////////////////////////////////////////////////////////////

# Fetch raw optional features
$OptionalFeatures = Get-WindowsOptionalFeature -Online | Sort-Object FeatureName

# Gather recent system servicing events to look for installation timestamps
$ServicingEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
    Id      = 41 # Service installation/update codes
} -ErrorAction SilentlyContinue

# Process and concatenate everything into a single custom object array
$Features = foreach ($Feature in $OptionalFeatures) {
    
    # 1. Fallback default path
    $FeatureLocation = "C:\Windows\WinSxS"

    # 2. Query the Windows Registry to find the exact Component package name for this feature
    # DISM features map directly to Foundation packages or OptionalPackages keys
    $RegPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackageDetect"
    
    if (Test-Path $RegPath) {
        # Find any registry keys matching the specific Feature Name
        $MatchingPackage = Get-ChildItem -Path $RegPath -ErrorAction SilentlyContinue | 
        Where-Object { $_.PSChildName -like "*$($Feature.FeatureName)*" } | 
        Select-Object -First 1
        
        if ($MatchingPackage) {
            # Extract the precise internal servicing identity name used in WinSxS
            $ComponentFolderIdentity = $MatchingPackage.PSChildName
            $FeatureLocation = "C:\Windows\WinSxS\*$ComponentFolderIdentity*"
        }
    }

    # 3. Handle a few known high-level runtime entry-point exemptions explicitly
    if ($Feature.FeatureName -eq "Microsoft-Windows-Subsystem-Linux") {
        $FeatureLocation = "C:\Windows\System32\wsl.exe"
    }
    elseif ($Feature.FeatureName -like "*Hyper-V-Hypervisor*") {
        $FeatureLocation = "C:\Windows\System32\hvax64.exe"
    }

    # Build the custom object structure
    [PSCustomObject]@{
        Name          = $Feature.FeatureName
        State         = $Feature.State
        Description   = $Feature.Description
        DateInstalled = $InstallDate # (From the previous Event Log matching logic)
        FileLocation  = $FeatureLocation
    }
}

# ///////////////////////////////////////////////////////////////////////////

# Export the clean object structure to the CSV path
$Features | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "DISM optional features audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -TableView flag to view the exported data file
if ($TableView) {
    if (Test-Path -Path $ExportPath) {
        Import-Csv -Path $ExportPath | Out-GridView -Title "Exported Windows Features Log"
    }
    else {
        Write-Warning "Export file not found at $ExportPath"
    }
}