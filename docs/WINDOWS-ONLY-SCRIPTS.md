# Windows-Only Scripts — Do Not Convert to Bash

**Decision (2026-09-09, Brandon's order):** convert PowerShell to bash only where
it honestly converts. The 67 scripts below execute on Windows by design — they
call Windows-only APIs (WMI/CIM, registry, DISM, Defender ASR, Windows Firewall,
the Windows Update COM session, Chocolatey, WinForms, DirectShow, COM shell
objects). A bash "twin" of any of them would be wrong: it could not run the
underlying operation on any platform. They stay `.ps1`-only, permanently.

**Converted instead (bash twins live alongside the originals):**
`scripts/checksum/check.ps1`, `scripts/checksum/compare.ps1`,
`qemu/get-iso.ps1`, `scripts/git/git-fucked.ps1`,
`scripts/tools/file-compare.ps1` (twin pre-existed), `scripts/tools/file-shift.ps1`,
`scripts/tools/delete-node.ps1` — pure logic (hashing, HTTP, git, file ops),
no Windows APIs.

## scripts/sys-info/ (34 scripts)
Windows introspection via WMI/`Get-CimInstance`, registry, DISM, `systeminfo`,
AppX, COM/DCOM — no Linux equivalents for these providers.
- `info.ps1`, `open-csv.ps1` (`Out-GridView`), `open-hosts.ps1` (`notepad.exe` RunAs)
- `list/all.ps1`, `appx.ps1`, `check-debug.ps1`, `com.ps1`, `com-lookup.ps1`,
  `dcom.ps1`, `devices.ps1`, `dev`-family (`driver-store.ps1`, `drivers.ps1`),
  `dism.ps1`, `dism-updates.ps1`, `envs.ps1`, `filters.ps1`, `hosts.ps1`,
  `messaging-hosts.ps1`, `notifications.ps1`, `path.ps1`, `pipes.ps1`,
  `programs.ps1`, `service-path.ps1`, `services.ps1`, `startup.ps1`,
  `systeminfo.ps1`, `tasks.ps1`, `UEFI.ps1`, `users.ps1`, `utils.ps1`
- `list/wmi/` (4): `wmi.ps1`, `hidden-processes.ps1`, `persistance.ps1`,
  `startup.ps1` — raw WMI event-consumer/process queries.

## scripts/asr/ (8 scripts)
Microsoft Defender Attack Surface Reduction rules (`Set-MpPreference` /
`Get-MpPreference`): `asr-ruleset.ps1`, `add-asr-rule.ps1`,
`add-all-asr-rules.ps1`, `disable-asr-rule.ps1`, `disable-all-asr-rules.ps1`,
`check-asr-rules.ps1`, `get-active-asr-rules.ps1`, `fetch-asr-rules.ps1`.

## scripts/firewall/ (3 scripts)
Windows Defender Firewall (`New-NetFirewallRule`/netsh): `block-lolbas.ps1`,
`block-updates.ps1`, `programs.ps1`.

## scripts/get-windows-updates/ (3 scripts)
Windows Update Agent COM session (`Microsoft.Update.Session`):
`fetch-updates.ps1`, `sync-updates.ps1`, `install.ps1`.

## scripts/kill-updates/ (1 script)
`wake-disable.ps1` — disables Windows Update wake timers/services via
`schtasks`/service control.

## scripts/chocolatey/ (2 scripts)
`install-chocolatey-online.ps1`, `apps.ps1` — Chocolatey package manager
(Windows-only installer ecosystem).

## scripts/settings/ (1 script)
`remove-optional.ps1` — removes Windows optional features/AppX packages
(`Remove-AppxPackage`, DISM capabilities).

## scripts/tools/ — Windows/PS-bound helpers (10 scripts)
- `godmode.ps1` — creates the `GodMode.{ED7BA470-...}` Explorer shell folder.
- `gui-launcher.ps1`, `gui-lib.ps1` — WinForms launcher UI (`#Requires -RunAsAdministrator`).
- `netmon.ps1` — live network monitor on WinForms + `Get-NetTCPConnection`.
- `process-zombies.ps1` — arcade game written in PowerShell WinForms.
- `set-profile.ps1` — PowerShell `$PROFILE` with hardcoded `C:\` tool paths.
- `runscripts.ps1` — `Set-ExecutionPolicy Bypass` runner.
- `shred.ps1` — parallel secure delete; requires Administrator to break file locks.
- `claude-clear.ps1` — wipes Windows Claude Code install paths
  (`%APPDATA%`, `%LOCALAPPDATA%`, `.local\bin\claude.exe`).
- `create-app.ps1` — Svelte scaffolder hardcoded to `$env:USERPROFILE\Projects`.

## scripts/music/ (1 script)
`record.ps1` — DirectShow webcam/microphone/screen capture.

## scripts/files/ (1 script)
`games.ps1` — creates Windows `.lnk` shortcuts via the `WScript.Shell` COM object.

## scripts/git/ (1 script)
`copy-git-utils.ps1` — rebuilds a `C:\toolbox\git` tree from `C:\git-sdk-64`
(Windows Git-SDK paths).

## qemu/ launchers (2 scripts)
`qemu/start.ps1`, `scripts/qemu/start.ps1` — QEMU launchers that read host
CPU/RAM via WMI (`Win32_Processor`, `Win32_ComputerSystem`) and assume a
Windows QEMU install (`C:\Program Files\qemu`).

---
*If a script above ever gains a platform-neutral implementation, convert it
then — until that day, do not re-litigate this list.*
