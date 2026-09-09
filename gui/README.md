# gui/ — Phoenix USB Builder

Builder-side GUI for the Phoenix project, loaded by the WinForms script
launcher (`scripts/tools/gui-launcher.ps1` → File → **USB Builder...**).
See `../docs/GUI-PLAN.md` for the full design.

## Architecture (founder decision)

- **This GUI runs on a working Windows machine.** It stages Ventoy ISOs onto
  the USB and writes **`phoenix-config.json`** (apps selection,
  username/password, answer-file options) to `<USB>:\phoenix\`.
- **The boot side is headless.** Ventoy renders the 4-option boot menu from
  the staged ISOs (Analyze → SystemRescue, Backup → Rescuezilla,
  Nuke → ShredOS, Reinstall → Windows installer ISO + Phoenix WinPE). WinPE
  reads `phoenix-config.json` and runs with no user interaction.
- **No GUI in WinPE.** That is where projects go to die.

## Run it

```powershell
# Normal path: open the launcher, File -> USB Builder...
powershell -ExecutionPolicy Bypass -File scripts\tools\gui-launcher.ps1

# Dev shortcut: run the builder standalone
powershell -ExecutionPolicy Bypass -File gui\phoenix-setup.ps1
```

No build step, no SDK, no dependencies beyond .NET Framework WinForms
(which ships with Windows).

## What the scaffold does today

- **Builder dialog**: 4 ISO tiles (Analyze/Backup/Nuke/Reinstall) with
  stage-checkboxes, Ventoy USB drive picker, `Verify Ventoy` check,
  `New Setup...` wizard, `Open Setup...` (stubbed), `BUILD USB`, and a
  password-safe log pane.
- **New Setup wizard** (5 pages): Machine → Accounts → Apps → Options → Review.
  - Accounts: masked password boxes, match validation, held as `SecureString`
    in the GUI, never written to the log.
  - Apps: `CheckedListBox` bound to `data/choco-install/apps.json` using the
    `{package, description, category, defaultSelected}` schema, with a category
    filter. Degrades gracefully while the sibling worker populates it.
- **Build flow** (`Invoke-PhoenixBuild`): verifies the target is a Ventoy USB,
  dot-sources `tools/New-UnattendXml.ps1` → `New-UnattendXml` and
  `tools/New-AppInstallScript.ps1` → `New-AppInstallScript`, calls
  the planned `tools/Stage-Usb.ps1` → `Stage-Usb` module for ISO staging
  (not yet implemented — the current stager scaffold is
  `tools/Build-PhoenixUsb.ps1`, a standalone script with `-WhatIf`
  dry-run support; the GUI skips staging with a warning until the
  `Stage-Usb` module contract lands), then writes
  `<USB>:\phoenix\phoenix-config.json` via `Write-PhoenixConfig`. Missing
  modules are reported, not crashed on.

## Password policy

Plaintext in `phoenix-config.json` is unavoidable (unattend requires it; WinPE
can't use the build machine's DPAPI key). The config password is a
**throwaway install-time credential**, changed after first logon — stated on
the wizard's Review page. Same exposure as the existing
`win-install/autounattend.xml`.

## Nuke safety

- The Nuke tile (ShredOS ISO) defaults to **unchecked**. Checking it opens a
  modal warning (staging ≠ running); unchecking is free.
- `BUILD USB` with Nuke staged asks for a second explicit confirmation naming
  the drive.
- The GUI **never invokes any wipe tool**. `nwipe`'s on-device confirmations
  stand and cannot be bypassed from here.

## File explorer requirement (founder)

Accounted for, not solved by the GUI: the staging manifest must include
**Explorer++ portable** in the WinPE payload; the Linux ISOs
(SystemRescue/Rescuezilla/ShredOS) ship full file managers natively.

## Still to do / needs Windows testing

- [ ] Run on a real Windows 10/11 box: launcher → File → USB Builder → walk
      the wizard at 100%/150% DPI; verify Ventoy detection on a real Ventoy USB.
- [ ] Wire to the real `New-UnattendXml` / `New-AppInstallScript` /
      `Stage-Usb` modules when the sibling workers land (contracts are in
      `docs/GUI-PLAN.md` §2c).
- [ ] Implement `Open Setup...` / `*.phoenix.json` save-load (password is
      never stored — re-prompted at build).
- [ ] Elevation story for the USB write step (relaunch `-Verb RunAs` when
      the stager needs it).
- [ ] The headless WinPE payload (`phoenix/headless/Start-Phoenix.ps1`,
      `startnet.cmd` hook) that consumes `phoenix-config.json`.
- [ ] ISO pin list + SHA-512 hashes; Explorer++ sourcing (see GUI-PLAN.md §7).
