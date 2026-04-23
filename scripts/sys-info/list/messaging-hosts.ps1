param (
    [Alias("t")]
    [switch]$TableView
)

# This script should catch spy things like this https://www.thatprivacyguy.com/blog/anthropic-spyware/

# Define the registry paths for all major browsers
$regPaths = @(
    # --- Major Players ---
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts",
    "HKLM:\Software\Google\Chrome\NativeMessagingHosts",
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts",
    "HKLM:\Software\Microsoft\Edge\NativeMessagingHosts",
    "HKCU:\Software\Mozilla\NativeMessagingHosts",
    "HKLM:\Software\Mozilla\NativeMessagingHosts",

    # --- Privacy & Hardened Browsers ---
    "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts",
    "HKLM:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts",
    "HKCU:\Software\LibreWolf\NativeMessagingHosts", # Often symlinked to Mozilla
    "HKLM:\Software\LibreWolf\NativeMessagingHosts",
    "HKCU:\Software\Waterfox\NativeMessagingHosts",
    "HKLM:\Software\Waterfox\NativeMessagingHosts",

    # --- Productivity & Power-User Browsers ---
    "HKCU:\Software\Vivaldi\NativeMessagingHosts",
    "HKLM:\Software\Vivaldi\NativeMessagingHosts",
    "HKCU:\Software\Opera Software\NativeMessagingHosts",
    "HKLM:\Software\Opera Software\NativeMessagingHosts",
    "HKCU:\Software\The Browser Company\Arc\NativeMessagingHosts", # Arc Browser
    "HKLM:\Software\The Browser Company\Arc\NativeMessagingHosts",
    
    # --- Generic/Chromium Fallbacks ---
    "HKCU:\Software\Chromium\NativeMessagingHosts",
    "HKLM:\Software\Chromium\NativeMessagingHosts"
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "NativeMessagingHosts-Browsers"

$results = @()

Write-Host "Scanning for all Browser-to-Desktop bridges..." -ForegroundColor Cyan

foreach ($path in $regPaths) {
    if (Test-Path $path) {
        $keys = Get-ChildItem -Path $path
        foreach ($key in $keys) {
            # The 'Default' value of the key points to the JSON manifest
            $manifestPath = (Get-ItemProperty -Path $key.PSPath)."(default)"
            
            if ($manifestPath -and (Test-Path $manifestPath)) {
                $manifestContent = Get-Content $manifestPath | ConvertFrom-Json
                $results += [PSCustomObject]@{
                    Browser     = $path.Split('\')[2] # Extracts 'Google', 'Microsoft', etc.
                    BridgeName  = $key.PSChildName
                    AppPath     = $manifestContent.path
                    Description = $manifestContent.description
                    Manifest    = $manifestPath
                }
            }
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "No native messaging bridges found." -ForegroundColor Yellow
}
else {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Host "Native Messaging Hosts audit exported to $ExportPath" -ForegroundColor Cyan

    # Check for the -t (TableView) flag
    if ($TableView) {
        Import-Csv -Path $ExportPath | Out-GridView -Title "Native Messaging Hosts (Browser-to-Desktop Bridges)"
    }
}