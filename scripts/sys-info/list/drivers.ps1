# List all currently installed drivers
# These should all usually exist in System32 System32/Drivers System32/DRIVERS or System32/DriverStore folders
# This also lists their running status, installed date, associated .inf files, and more

# Get-CimInstance Win32_SystemDriver |
# Where-Object { $_.State -eq "Running" } |
# ForEach-Object {
#     $sig = Get-AuthenticodeSignature $_.PathName
#     [PSCustomObject]@{
#         Name        = $_.Name
#         DisplayName = $_.DisplayName
#         StartMode   = $_.StartMode
#         State       = $_.State
#         PathName    = $_.PathName
#         Publisher   = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "Unsigned/Unknown" }
#         Status      = $sig.Status
#     }
# } | Out-GridView

Write-Host "========================================" -ForegroundColor Magenta
Write-Host "   SYSTEM DRIVER & HARDWARE SCANNER   " -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "[*] Mapping services to PnP hardware devices..." -ForegroundColor Yellow

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Drivers.csv"
$BackupFolder = Join-Path (Split-Path $PSScriptRoot -Parent) "data-backup"

if (Test-Path $ExportPath) {
    # Ensure backup directory exists
    if (-not (Test-Path $BackupFolder)) { 
        New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null 
    }

    # Create timestamp (e.g., 20260417-1655)
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FileName = Split-Path $ExportPath -Leaf
    $BackupPath = Join-Path $BackupFolder "$Timestamp-$FileName"

    # Move and rename
    Move-Item -Path $ExportPath -Destination $BackupPath -Force
    Write-Host "[!] Existing audit archived to: $BackupPath" -ForegroundColor Gray
}

# Get all running system drivers
$Drivers = Get-CimInstance Win32_SystemDriver

# Pre-fetch PnP drivers
$PnPMap = Get-CimInstance Win32_PnPSignedDriver

$Results = foreach ($d in $Drivers) {
    # Cross-reference
    $pnp = $PnPMap | Where-Object { $_.DriverName -eq $d.Name -or $_.DeviceName -eq $d.DisplayName }
    $sig = Get-AuthenticodeSignature $d.PathName
    
    # --- Fix for Date Format Error ---
    $rawDate = if ($pnp.InstallDate) { $pnp.InstallDate } elseif (Test-Path $d.PathName) { (Get-Item $d.PathName).CreationTime } else { $null }
    
    $formattedDate = "Unknown"
    if ($rawDate) {
        try {
            if ($rawDate -is [DateTime]) {
                $formattedDate = $rawDate.ToString("yyyy-MM-dd HH:mm")
            }
            else {
                # Convert CIM string, but trim any weirdness first
                $dt = [Management.ManagementDateTimeConverter]::ToDateTime($rawDate.ToString())
                $formattedDate = $dt.ToString("yyyy-MM-dd HH:mm")
            }
        }
        catch {
            # Final fallback: if conversion fails, check file system one last time
            if (Test-Path $d.PathName) {
                $formattedDate = (Get-Item $d.PathName).CreationTime.ToString("yyyy-MM-dd HH:mm")
            }
            else {
                $formattedDate = "N/A"
            }
        }
    }

    # --- Fix for Provider {$null, $null} ---
    # We'll try the PnP provider details, fallback to the PnP Manufacturer, or the Signer
    $provider = if ($pnp.DriverProviderDetails -join "") { $pnp.DriverProviderDetails -join ", " } 
    elseif ($pnp.Manufacturer) { $pnp.Manufacturer } 
    else { "---" }

    [PSCustomObject]@{
        NAME         = $d.Name
        DISPLAY_NAME = $d.DisplayName
        STATE        = $d.State
        VERSION      = if ($pnp.DriverVersion) { $pnp.DriverVersion } else { "N/A" }
        PROVIDER     = $provider
        INF_FILE     = $pnp.InfName
        DEVICE_ID    = $pnp.DeviceID
        INSTALLED    = $formattedDate
        PUBLISHER    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "Unsigned/Unknown" }
        SIGN_STATUS  = $sig.Status
        PATH         = $d.PathName
    }
}

# Display results in a searchable grid and export to CSV

$Results | Sort-Object INSTALLED -Descending | Out-GridView -Title "Driver Inventory"
$Results | Sort-Object INSTALLED -Descending | Export-Csv -Path $ExportPath -NoTypeInformation