# These are some binaries that are commonly abused by attackers for living off the land techniques. 
# This script will block outbound traffic for these binaries to help 
# mitigate the attack surface for LOLBAS (Living Off The Land Binaries and Scripts) attacks.

# This needs customization and tweaking as blocking some of these may restrict functionality.

# https://lolbas-project.github.io/

#Requires -RunAsAdministrator

$AllBins = @(
    # Network/Exfil
    "certutil.exe", "bitsadmin.exe", "mshta.exe", "curl.exe", "hh.exe", "certoc.exe", 
    "certreq.exe", "cmdl32.exe", "desktopimgdownldr.exe", "finger.exe", "mobsync.exe", 
    "configsecuritypolicy.exe", "scriptrunner.exe", "ftp.exe", "tftp.exe", "extrac32.exe", 
    "ieexec.exe", "mavinject.exe", "atbroker.exe", "pcalua.exe", "wiaacmgr.exe", "findstr.exe",
    # Stealth/Hollowing Hosts
    "dashost.exe", "grpconv.exe", "openwith.exe", "werfault.exe", "compattelrunner.exe",
    # Execution & Persistence
    "powershell_ise.exe", "wscript.exe", "cscript.exe", "bash.exe", "scrcons.exe", "cmd.exe", 
    "regsvr32.exe", "rundll32.exe", "reg.exe", "schtasks.exe", "sc.exe", "at.exe", "msiexec.exe",
    # Hardware & Low-Level
    "pnputil.exe", "dism.exe", "driverquery.exe", "mountvol.exe", "vssadmin.exe", "wbadmin.exe", 
    "diskshadow.exe", "bcdedit.exe", "bootcfg.exe", "fltmc.exe"
)

$searchPaths = @("$env:windir\System32", "$env:windir\SysWOW64")
foreach ($bin in $AllBins) {
    foreach ($dir in $searchPaths) {
        $fullPath = Join-Path $dir $bin
        if (Test-Path $fullPath) {
            $ruleName = "LOLBAS-BLOCK-$bin-$(Split-Path $dir -Leaf)"
            if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name $ruleName -DisplayName "LOLBAS Block: $bin" -Direction Outbound `
                    -Program $fullPath -Action Block -Description "2026 LOLBAS Blocks"
            }
        }
    }
}