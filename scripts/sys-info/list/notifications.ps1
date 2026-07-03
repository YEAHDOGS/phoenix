param (
    [Alias("t")]
    [switch]$TableView,

    [Alias("l")]
    [int]$Limit = 25
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Notifications"

# 1. Define C# helper for SQLite using winsqlite3.dll via P/Invoke
$csharpCode = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinSqlite {
    private const string DLL_NAME = "winsqlite3.dll";

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    public static extern int sqlite3_open16(string filename, out IntPtr db);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_close(IntPtr db);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    public static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int numBytes, out IntPtr stmt, IntPtr pzTail);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_step(IntPtr stmt);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_column_count(IntPtr stmt);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_column_name16(IntPtr stmt, int index);

    [DllImport(DLL_NAME, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_column_text16(IntPtr stmt, int index);

    public static List<Dictionary<string, string>> Query(string dbPath, string sql) {
        var results = new List<Dictionary<string, string>>();
        IntPtr db = IntPtr.Zero;
        if (sqlite3_open16(dbPath, out db) != 0) {
            throw new Exception("Failed to open database.");
        }

        IntPtr stmt = IntPtr.Zero;
        try {
            if (sqlite3_prepare16_v2(db, sql, -1, out stmt, IntPtr.Zero) != 0) {
                throw new Exception("Failed to prepare statement.");
            }

            int colCount = sqlite3_column_count(stmt);
            string[] colNames = new string[colCount];
            for (int i = 0; i < colCount; i++) {
                colNames[i] = Marshal.PtrToStringUni(sqlite3_column_name16(stmt, i));
            }

            while (sqlite3_step(stmt) == 100) { // SQLITE_ROW
                var row = new Dictionary<string, string>();
                for (int i = 0; i < colCount; i++) {
                    IntPtr valPtr = sqlite3_column_text16(stmt, i);
                    row[colNames[i]] = valPtr == IntPtr.Zero ? null : Marshal.PtrToStringUni(valPtr);
                }
                results.Add(row);
            }
        } finally {
            if (stmt != IntPtr.Zero) {
                sqlite3_finalize(stmt);
            }
            if (db != IntPtr.Zero) {
                sqlite3_close(db);
            }
        }
        return results;
    }
}
"@

# Safely compile the class in the session to support repeated runs
if (-not ([System.Management.Automation.PSTypeName]"WinSqlite").Type) {
    Add-Type -TypeDefinition $csharpCode
}

# 2. Path and application name resolution helper functions
function Resolve-AppPath {
    param (
        [string]$PrimaryId
    )

    if (-not $PrimaryId) { return "Unknown" }

    # Check if it's already a valid path
    if (Test-Path $PrimaryId -PathType Leaf) {
        return $PrimaryId
    }

    # Common system AUMIDs mapping
    $SystemAumidMap = @{
        "Windows.SystemToast.SecurityAndMaintenance"   = "$env:SystemRoot\System32\SecurityHealthSystray.exe"
        "Windows.SystemToast.BackgroundAccess"         = "$env:SystemRoot\System32\taskhostw.exe"
        "Windows.SystemToast.StartupApp"               = "$env:SystemRoot\System32\taskhostw.exe"
        "Windows.SystemToast.Audio"                    = "$env:SystemRoot\System32\SndVol.exe"
        "Windows.SystemToast.Print"                    = "$env:SystemRoot\System32\spoolsv.exe"
        "Windows.SystemToast.Print.PrinterCleanupTask" = "$env:SystemRoot\System32\PrinterCleanupTask.dll"
        "Windows.SystemToast.WiFiNetworkManager"       = "$env:SystemRoot\System32\van.dll"
        "Windows.SystemToast.Bluetooth"                = "$env:SystemRoot\System32\fsquirt.exe"
    }

    if ($SystemAumidMap.ContainsKey($PrimaryId)) {
        return $SystemAumidMap[$PrimaryId]
    }
    if ($PrimaryId -like "Microsoft.Explorer.Notification*") {
        return "$env:SystemRoot\explorer.exe"
    }

    # Check if it's a UWP app (contains '!')
    if ($PrimaryId -match '!([^!]+)$') {
        $packageFamilyName = $PrimaryId.Split('!')[0]
        $appId = $PrimaryId.Split('!')[1]
        
        $package = Get-AppxPackage -Name $packageFamilyName -ErrorAction SilentlyContinue
        if (-not $package) {
            $package = Get-AppxPackage -AllUsers -Name $packageFamilyName -ErrorAction SilentlyContinue
        }
        
        if ($package -and $package.InstallLocation) {
            $manifestPath = Join-Path $package.InstallLocation "AppxManifest.xml"
            if (Test-Path $manifestPath) {
                try {
                    [xml]$manifest = Get-Content $manifestPath -ErrorAction SilentlyContinue
                    $appNode = $manifest.Package.Applications.Application | Where-Object { $_.Id -eq $appId }
                    if ($appNode -and $appNode.Executable) {
                        return Join-Path $package.InstallLocation $appNode.Executable
                    }
                    $exec = $manifest.Package.Applications.Application.Executable | Select-Object -First 1
                    if ($exec) {
                        return Join-Path $package.InstallLocation $exec
                    }
                }
                catch {}
            }
            return $package.InstallLocation
        }
    }

    # Check Start Menu shortcuts using Get-StartApps to map to shortcut target
    $startApp = Get-StartApps | Where-Object { $_.AppID -eq $PrimaryId } | Select-Object -First 1
    if ($startApp) {
        $appName = $startApp.Name
        $startMenuPaths = @(
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
            "$env:PUBLIC\Desktop",
            "$env:USERPROFILE\Desktop"
        )
        
        foreach ($folder in $startMenuPaths) {
            if (Test-Path $folder) {
                $shortcutFile = Get-ChildItem -Path $folder -Filter "$appName.lnk" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $shortcutFile) {
                    $shortcutFile = Get-ChildItem -Path $folder -Filter "*$appName*.lnk" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                
                if ($shortcutFile) {
                    try {
                        $wsh = New-Object -ComObject WScript.Shell
                        $shortcut = $wsh.CreateShortcut($shortcutFile.FullName)
                        $targetPath = $shortcut.TargetPath
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
                        if ($targetPath -and (Test-Path $targetPath -PathType Leaf)) {
                            return $targetPath
                        }
                    }
                    catch {}
                }
            }
        }
    }

    # Fallback to App Paths in registry
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $subkeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($subkey in $subkeys) {
                if ($PrimaryId -like "*$($subkey.PSChildName)*" -or $($subkey.PSChildName) -like "*$PrimaryId*") {
                    $val = (Get-ItemProperty -Path $subkey.PSPath -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
                    if ($val -and (Test-Path $val -PathType Leaf)) {
                        return $val
                    }
                }
            }
        }
    }

    return "Unknown"
}

function Resolve-AppName {
    param (
        [string]$PrimaryId,
        [string]$ResolvedPath
    )

    if (-not $PrimaryId) { return "Unknown" }

    $startApp = Get-StartApps | Where-Object { $_.AppID -eq $PrimaryId } | Select-Object -First 1
    if ($startApp) {
        return $startApp.Name
    }

    if ($ResolvedPath -and $ResolvedPath -ne "Unknown" -and (Test-Path $ResolvedPath -PathType Leaf)) {
        try {
            $desc = (Get-Item $ResolvedPath).VersionInfo.FileDescription
            if ($desc) { return $desc }
            return (Get-Item $ResolvedPath).BaseName
        }
        catch {}
    }

    if ($PrimaryId -match '!([^!]+)$') {
        $packageFamilyName = $PrimaryId.Split('!')[0]
        $package = Get-AppxPackage -Name $packageFamilyName -ErrorAction SilentlyContinue
        if ($package) {
            return $package.Name
        }
    }

    if ($PrimaryId -like "Microsoft.Explorer.Notification*") {
        return "Windows Explorer"
    }
    if ($PrimaryId -like "Windows.SystemToast.*") {
        return $PrimaryId.Replace("Windows.SystemToast.", "")
    }

    $cleanName = $PrimaryId
    if ($cleanName -match '\.([^.]+)$') {
        $cleanName = $Matches[1]
    }
    return $cleanName
}

# 3. Locate and copy the wpndatabase.db
$dbOriginal = "$env:LOCALAPPDATA\Microsoft\Windows\Notifications\wpndatabase.db"
if (-not (Test-Path $dbOriginal)) {
    Write-Warning "Windows notifications database not found at $dbOriginal"
    return
}

$dbTemp = Join-Path $env:TEMP "wpndatabase_copy.db"
Copy-Item -Path $dbOriginal -Destination $dbTemp -Force -ErrorAction SilentlyContinue
if (Test-Path "$dbOriginal-wal") {
    Copy-Item -Path "$dbOriginal-wal" -Destination "$dbTemp-wal" -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$dbOriginal-shm") {
    Copy-Item -Path "$dbOriginal-shm" -Destination "$dbTemp-shm" -Force -ErrorAction SilentlyContinue
}

# Query the notifications
$query = "SELECT n.Payload, n.ArrivalTime, h.PrimaryId " +
"FROM Notification n " +
"LEFT JOIN NotificationHandler h ON n.HandlerId = h.RecordId " +
"ORDER BY n.ArrivalTime DESC " +
"LIMIT $Limit"

$rawNotifications = @()
try {
    $rawNotifications = [WinSqlite]::Query($dbTemp, $query)
}
catch {
    Write-Warning "Failed to query notification database: $_"
}
finally {
    # Cleanup temp database copies
    Remove-Item -Path $dbTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$dbTemp-wal" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$dbTemp-shm" -Force -ErrorAction SilentlyContinue
}

# Format and build final notification objects
$Notifications = foreach ($row in $rawNotifications) {
    # Convert arrival time (Windows FileTime)
    $date = "Unknown"
    if ($row['ArrivalTime']) {
        try {
            $fileTime = [int64]$row['ArrivalTime']
            if ($fileTime -gt 0) {
                $date = [datetime]::FromFileTime($fileTime).ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        catch {}
    }

    # Extract text from XML Payload
    $title = ""
    $message = ""
    $payload = $row['Payload']
    if ($payload -and $payload -like "<*") {
        try {
            [xml]$xml = $payload
            $textNodes = $xml.SelectNodes("//text")
            if ($textNodes.Count -gt 0) {
                $title = $textNodes[0].InnerText.Trim()
            }
            if ($textNodes.Count -gt 1) {
                $message = (($textNodes | Select-Object -Skip 1) | ForEach-Object { $_.InnerText.Trim() }) -join " | "
            }
        }
        catch {}
    }

    $appId = $row['PrimaryId']
    $programPath = Resolve-AppPath -PrimaryId $appId
    $appName = Resolve-AppName -PrimaryId $appId -ResolvedPath $programPath

    [PSCustomObject]@{
        ArrivalTime = $date
        Application = $appName
        Title       = $title
        Message     = $message
        ProgramPath = $programPath
        AppId       = $appId
    }
}

# Export to CSV
$Notifications | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Notifications audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Notifications History"
}
