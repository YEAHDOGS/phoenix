# Phoenix `$OEM$` source tree

This directory is the **source of truth** for the unattended post-install
hooks Windows Setup picks up from the USB root (`$OEM$\$$\Setup\Scripts\`
lands at `C:\Windows\Setup\Scripts\` automatically).

## What runs, and when

| Script | Pass | Context | Job |
|---|---|---|---|
| `Specialize.ps1` | specialize (Order 2) | SYSTEM | Creates `C:\Phoenix\{Logs,Scripts}`, copies the audited toolbox off the USB onto disk, writes `specialize.done`. |
| `DefaultUser.ps1` | specialize (Order 4) | SYSTEM, `HKU\DefaultUser` mounted | Default-profile registry tweaks (Explorer, taskbar, privacy, Game Bar) every new account inherits. |
| `FirstLogon.ps1` | oobeSystem → FirstLogonCommands | new local admin | Offline-first app install from `cache\apps\*.nupkg` on the USB; online install only with explicit `-AllowOnline`. |

## Contracts (non-negotiable)

1. **Never fail setup/OOBE.** Every step is guarded; failures log, never
   throw out of the script. All three scripts end with `exit 0`.
2. **Air-gap default.** `Specialize` and `DefaultUser` make zero network
   calls. `FirstLogon` only opens a socket when `-AllowOnline` is passed.
3. **No credentials, no machine-specific paths.** These scripts are
   committed to the repo — anything secret or Brandon-specific stays out.
4. **Match the answer file.** `win-install/autounattend.xml` invokes these
   three exact filenames at `C:\Windows\Setup\Scripts\`. Renaming a file
   here requires the matching XML change (and vice versa) — the regression
   test `tests/tools/test-oem-setup.sh` asserts the pair stays in sync.

## Staging

`tools/Build-PhoenixUsb.ps1` / `tools/Build-PhoenixUsb.sh` copy this whole
`$OEM$` tree to the USB root (fail-closed if missing). Windows Setup picks
it up from the data partition automatically — no reburn needed.
