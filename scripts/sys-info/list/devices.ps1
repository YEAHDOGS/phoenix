$CSharpSource = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace GetItGoin.Hardware {
    public class DNAScanner {
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex, ref SP_DEVINFO_DATA DeviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool SetupDiGetDeviceProperty(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref DEVPROPKEY PropertyKey, out uint PropertyType, byte[] PropertyBuffer, uint PropertyBufferSize, out uint RequiredSize, uint Flags);

        [StructLayout(LayoutKind.Sequential)]
        public struct SP_DEVINFO_DATA {
            public uint cbSize;
            public Guid ClassGuid;
            public uint DevInst;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DEVPROPKEY {
            public Guid fmtid;
            public uint pid;
        }

        // The "Source of Truth" Keys
        public static DEVPROPKEY DEVPKEY_Device_FriendlyName = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
        public static DEVPROPKEY DEVPKEY_Device_DeviceDesc = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 2 };
        public static DEVPROPKEY DEVPKEY_Device_Class = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 9 };
        public static DEVPROPKEY DEVPKEY_Device_Manufacturer = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 13 };
        public static DEVPROPKEY DEVPKEY_Device_Service = new DEVPROPKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 6 };
        public static DEVPROPKEY DEVPKEY_Device_InstanceId = new DEVPROPKEY { fmtid = new Guid("78c3345d-9981-4174-8255-7199923afc58"), pid = 256 };

        public const uint DIGCF_ALLCLASSES = 0x4;
        public const uint DIGCF_PRESENT = 0x2;

        public static List<Dictionary<string, string>> Scan() {
            var devices = new List<Dictionary<string, string>>();
            Guid emptyGuid = Guid.Empty;
            // Removed DIGCF_PRESENT to ensure we see the hidden nodes that ReviOS might have "ghosted"
            IntPtr hDevInfo = SetupDiGetClassDevs(ref emptyGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_ALLCLASSES);

            if (hDevInfo != (IntPtr)(-1)) {
                SP_DEVINFO_DATA devData = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA)) };
                for (uint i = 0; SetupDiEnumDeviceInfo(hDevInfo, i, ref devData); i++) {
                    var device = new Dictionary<string, string>();
                    device["Name"] = GetStringProp(hDevInfo, devData, DEVPKEY_Device_FriendlyName) ?? GetStringProp(hDevInfo, devData, DEVPKEY_Device_DeviceDesc);
                    device["Category"] = GetStringProp(hDevInfo, devData, DEVPKEY_Device_Class);
                    device["Manufacturer"] = GetStringProp(hDevInfo, devData, DEVPKEY_Device_Manufacturer);
                    device["Service"] = GetStringProp(hDevInfo, devData, DEVPKEY_Device_Service);
                    device["InstanceId"] = GetStringProp(hDevInfo, devData, DEVPKEY_Device_InstanceId);
                    devices.Add(device);
                }
            }
            return devices;
        }

        private static string GetStringProp(IntPtr hDevInfo, SP_DEVINFO_DATA devData, DEVPROPKEY key) {
            uint propType, reqSize;
            SetupDiGetDeviceProperty(hDevInfo, ref devData, ref key, out propType, null, 0, out reqSize, 0);
            if (reqSize == 0) return null;
            byte[] buffer = new byte[reqSize];
            if (SetupDiGetDeviceProperty(hDevInfo, ref devData, ref key, out propType, buffer, reqSize, out reqSize, 0)) {
                return Encoding.Unicode.GetString(buffer).TrimEnd('\0');
            }
            return null;
        }
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]"GetItGoin.Hardware.DNAScanner").Type) {
    Add-Type -TypeDefinition $CSharpSource
}



. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Devices"

Write-Host "[*] Interrogating Hardware via Binary Analysis..." -ForegroundColor Cyan
$HardwareList = [GetItGoin.Hardware.DNAScanner]::Scan()

$Results = foreach ($h in $HardwareList) {
    # 1. Keep your perfect naming logic
    $name = if ($h.Name) { $h.Name } else { "System Node (No Friendly Name)" }
    $date = "N/A"
    $publisher = "N/A"
    $binPath = "N/A"
    $sigStatus = "N/A"

    # 2. Resolve Binary Path (Your current working logic)
    if ($h.Service) {
        $srvKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($h.Service)"
        if (Test-Path $srvKey) {
            $val = (Get-ItemProperty $srvKey -ErrorAction SilentlyContinue).ImagePath
            if ($val) { 
                $binPath = $val.Trim('"').Replace('\??\', '')
                if ($binPath -notlike "*:\*") { $binPath = Join-Path $env:SystemRoot $binPath }
            }
        }
    }

    # 3. HIGH-PRIORITY: If Path exists, extract truth from the file
    if (Test-Path $binPath) {
        $fileObj = Get-Item $binPath
        
        # Publisher & Signature Extraction
        $sig = Get-AuthenticodeSignature $binPath
        $sigStatus = $sig.Status
        
        if ($sig.SignerCertificate) {
            # Extract the actual Subject (e.g., "Intel Release signing")
            $publisher = $sig.SignerCertificate.Subject.Split(',')[0].Replace("CN=", "")
        }
        elseif ($sigStatus -eq "NotSigned") {
            $publisher = "Unsigned / Local"
        }
        else {
            $publisher = "Microsoft Windows"
        }

        # Date Resolution
        # We use the 'LastWriteTime' as it's the most accurate reflection of when the driver was built/packaged
        $date = $fileObj.LastWriteTime.ToString("yyyy-MM-dd")
    }

    # 4. Fallback to Registry ONLY if file analysis failed
    if ($publisher -eq "N/A" -and $h.InstanceId) {
        $enumKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($h.InstanceId)"
        if (Test-Path $enumKey) {
            $enumProps = Get-ItemProperty $enumKey -ErrorAction SilentlyContinue
            if ($enumProps.Driver) {
                $driverRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($enumProps.Driver)"
                if (Test-Path $driverRegPath) {
                    $driverProps = Get-ItemProperty $driverRegPath -ErrorAction SilentlyContinue
                    if ($date -eq "N/A") { $date = $driverProps.DriverDate }
                    if ($publisher -eq "N/A") { $publisher = $driverProps.ProviderName }
                }
            }
        }
    }

    [PSCustomObject]@{
        DEVICE      = $name
        CATEGORY    = $h.Category
        PUBLISHER   = $publisher
        DRIVER_DATE = $date
        SIGN_STATUS = $sigStatus
        BINARY_PATH = $binPath
    }
}

$Results | Sort-Object CATEGORY | Out-GridView -Title "Devices"
$Results | Sort-Object CATEGORY | Export-Csv -Path $ExportPath -NoTypeInformation