# List all currently installed drivers
# These should all usually exist in System32 System32/Drivers System32/DRIVERS or System32/DriverStore folders
# This also lists their running status, installed date, associated .inf files, and more

# This is where the wild things are.

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
Write-Host "     SYSTEM DRIVER STORE & HARDWARE SCANNER     " -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "[*] Let's rock" -ForegroundColor Yellow

# 1. Fetch data sources
Write-Host "[*] Fetching system drivers..." -ForegroundColor Yellow
$Drivers = Get-CimInstance Win32_SystemDriver

Write-Host "[*] Fetching PnP driver details..." -ForegroundColor Yellow
$PnPMap = Get-CimInstance Win32_PnPSignedDriver

Write-Host "[*] Fetching driver store (this may take a moment)..." -ForegroundColor Yellow
$StoreRaw = Get-WindowsDriver -Online -All
# Bridge: Convert Store to a Hash Table for high-speed lookup via INF name
$StoreTable = $StoreRaw | Group-Object Driver -AsHashTable -AsString

Write-Host "[*] Correlating all data layers..." -ForegroundColor Yellow

$Results = foreach ($d in $Drivers) {
    # Cross-reference Service -> PnP
    $pnp = $PnPMap | Where-Object { $_.DriverName -eq $d.Name -or $_.DeviceName -eq $d.DisplayName } | Select-Object -First 1
    
    # Cross-reference PnP -> Store (Using the INF file as the bridge)
    $store = if ($pnp.InfName) { $StoreTable[$pnp.InfName] } else { $null }
    
    $sig = Get-AuthenticodeSignature $d.PathName
    
    # --- Fix for Date Format Error ---
    $rawDate = if ($pnp.InstallDate) { $pnp.InstallDate } elseif (Test-Path $d.PathName) { (Get-Item $d.PathName).CreationTime } else { $null }
    
    $formattedDate = "Unknown"
    if ($rawDate) {
        try {
            if ($rawDate -is [DateTime]) {
                $formattedDate = $rawDate.ToString("yyyy-MM-dd HH:mm") + " (DT)"
            }
            else {
                # Convert CIM string, but trim any weirdness first
                $dt = [Management.ManagementDateTimeConverter]::ToDateTime($rawDate.ToString())
                $formattedDate = $dt.ToString("yyyy-MM-dd HH:mm") + " (CIM)"
            }
        }
        catch {
            # Final fallback: if conversion fails, check file system one last time
            if (Test-Path $d.PathName) {
                $formattedDate = (Get-Item $d.PathName).CreationTime.ToString("yyyy-MM-dd HH:mm") + " (File System)"
            }
            else {
                $formattedDate = "N/A"
            }
        }
    }

    # --- Fix for Provider {$null, $null} ---
    # We'll try the PnP provider details, fallback to the PnP Manufacturer, or the Signer
    $provider = if ($store.ProviderName) { $store.ProviderName } 
    elseif ($pnp.DriverProviderDetails -join "") { $pnp.DriverProviderDetails -join ", " } 
    elseif ($pnp.Manufacturer) { $pnp.Manufacturer } 
    else { "---" }

    [PSCustomObject]@{
        # --- Service & PnP Data ---
        NAME          = $d.Name
        DISPLAY_NAME  = $d.DisplayName
        STATE         = $d.State
        SERVICE_TYPE  = $d.ServiceType
        VERSION       = if ($store.Version) { $store.Version } else { $pnp.DriverVersion }
        PROVIDER      = $provider
        INF_FILE      = $pnp.InfName
        DEVICE_ID     = $pnp.DeviceID
        INSTALLED     = $formattedDate
        PUBLISHER     = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "Unsigned/Unknown" }
        SIGN_STATUS   = $sig.Status
        PATH          = $d.PathName

        # --- Store Data Additions ---
        IS_INBOX      = if ($store) { $store.Inbox } else { "N/A" }
        BOOT_CRITICAL = if ($store) { $store.BootCritical } else { ($d.StartMode -eq "Boot") }
        STORE_CLASS   = if ($store) { $store.ClassName } else { $pnp.DeviceClass }
        ORIGINAL_FILE = $store.OriginalFileName
        DATA_ORIGIN   = "$(if($store){'STORE '})$(if($pnp){'PNP '})$(if($d){'SERVICE'})"
    }
}

# 2. Add Second Pass for Dormant Store Entries (Staged but not running)
$RunningInfs = $Results.INF_FILE
foreach ($s in ($StoreRaw | Where-Object { $RunningInfs -notcontains $_.Driver })) {
    $Results += [PSCustomObject]@{
        NAME          = "Dormant"
        DISPLAY_NAME  = "Staged Driver Only"
        STATE         = "Not Loaded"
        SERVICE_TYPE  = "N/A"
        VERSION       = $s.Version
        PROVIDER      = $s.ProviderName
        INF_FILE      = $s.Driver
        DEVICE_ID     = "N/A"
        INSTALLED     = $s.Date.ToString("yyyy-MM-dd HH:mm") + " (Store Date)"
        PUBLISHER     = "N/A"
        SIGN_STATUS   = "N/A"
        PATH          = $s.OriginalFileName
        IS_INBOX      = $s.Inbox
        BOOT_CRITICAL = $s.BootCritical
        STORE_CLASS   = $s.ClassName
        ORIGINAL_FILE = $s.OriginalFileName
        DATA_ORIGIN   = "STORE ONLY"
    }
}

# Display & Export
Write-Host "[+] Driver Store Inventory Complete." -ForegroundColor Green

$ExportPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\Sys-Driver-Store.csv"

$Results | Sort-Object DATA_ORIGIN, INSTALLED -Descending | Out-GridView -Title "Driver Store Inventory"
$Results | Sort-Object DATA_ORIGIN, INSTALLED -Descending | Export-Csv -Path $ExportPath -NoTypeInformation