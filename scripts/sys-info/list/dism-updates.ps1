param (
    [switch]$TableView  # Allows running the script with -TableView or -t if aliased
)

# Import, initialize
. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "DISM_UPDATES"

Write-Host "Analyzing update initiators and calling applications..." -ForegroundColor Cyan

# ///////////////////////////////////////////////////////////////////////////

. "$PSScriptRoot\com-lookup.ps1"

$FilterHashtable = @{
    LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
    Id      = @(41, 43, 44) # Focus on installation lifecycle events
}

Write-Host "Fetching events and initializing resolution cache..." -ForegroundColor Cyan
$RawEvents = Get-WinEvent -FilterHashtable $FilterHashtable -ErrorAction SilentlyContinue

# Initialize an empty hash table to store resolved GUID metadata and avoid duplicates
$ResolutionCache = @{}

$InitiatorReport = foreach ($Event in $RawEvents) {
    
    # Convert the binary security descriptor into a readable username/system context
    $UserIdentity = "System / Background Engine"
    if ($null -ne $Event.UserId) {
        try {
            $UserIdentity = $Event.UserId.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            $UserIdentity = "SID: $($Event.UserId.Value)" 
        }
    }

    # Extract the internal 'Caller Name' API property
    $CallingApplication = "Unknown API Call"
    if ($Event.Properties.Count -gt 1) {
        foreach ($Prop in $Event.Properties) {
            if ($Prop.Value -match "UpdateOrchestrator|WIH|DISM|WindowsDefender|CCM|UsoClient|DeviceDriver") {
                $CallingApplication = $Prop.Value
                break
            }
        }
        if ($CallingApplication -eq "Unknown API Call" -and $null -ne $Event.Properties[1].Value) {
            $CallingApplication = $Event.Properties[1].Value
        }
    }

    # Clean up the asset name (Update Title/Feature Title)
    $TargetAsset = if ($Event.Properties.Count -gt 0) { $Event.Properties[0].Value } else { "N/A" }

    # --- DYNAMIC CACHING AND LOOKUP ENGINE ---
    $CallingAppName = "Unknown"
    $CallingAppLocation = "N/A"

    Write-Host "Checking $CallingApplication"

    # Check if the token is formatted as a GUID
    if ($CallingApplication -match '^\{?[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}\}?$') {
        Write-Host "$CallingApplication is GUID"

        # If this GUID is already in our map, grab the cached properties directly
        if ($ResolutionCache.ContainsKey($CallingApplication)) {
            $CallingAppName = $ResolutionCache[$CallingApplication].Name
            $CallingAppLocation = $ResolutionCache[$CallingApplication].Location
            Write-Host "$CallingApplication in cache" -ForegroundColor Blue
        } 
        else {
            # Not in cache: Perform the heavy registry lookup once
            $ComResolution = Resolve-WindowsComGuid -Guid $CallingApplication
            $CallingAppName = $ComResolution.ComponentName
            $CallingAppLocation = $ComResolution.BinaryLocation

            # Save the results to our map to safeguard future iterations
            $ResolutionCache[$CallingApplication] = @{
                Name     = $CallingAppName
                Location = $CallingAppLocation
            }
            Write-Host "$CallingApplication not in cache" -ForegroundColor Red
        }
    } 
    else {
        # Fallback for standard plain-text engine tokens
        $CallingAppName = $CallingApplication
        $CallingAppLocation = "Native Windows Update Engine Context"
        Write-Host "$CallingApplication is NOT GUID" -ForegroundColor Red
    }

    [PSCustomObject]@{
        Timestamp          = $Event.TimeCreated
        EventID            = $Event.Id
        InitiatedByUser    = $UserIdentity
        CallingAppGUID     = $CallingApplication
        CallingAppName     = $CallingAppName
        CallingAppLocation = $CallingAppLocation
        TargetAsset        = $TargetAsset
    }
}

# ///////////////////////////////////////////////////////////////////////////

# Export the clean object structure to the CSV path
$InitiatorReport | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "DISM UPDATES audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -TableView flag to view the exported data file
if ($TableView) {
    if (Test-Path -Path $ExportPath) {
        Import-Csv -Path $ExportPath | Out-GridView -Title "Windows Update Trigger & Initiator Forensics"
    }
    else {
        Write-Warning "Export file not found at $ExportPath"
    }
}