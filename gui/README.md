# gui/ — Phoenix USB Builder

WinForms (PowerShell) wizard that builds a Phoenix install USB on a
**connected** Windows machine. See `../docs/GUI-PLAN.md` for the full design.

## Run it

```powershell
# From the repo root, on Windows 10/11 (PowerShell 5.1+):
powershell -ExecutionPolicy Bypass -File gui\phoenix-setup.ps1
```

No build step, no SDK, no dependencies beyond .NET Framework WinForms
(which ships with Windows).

## What it does today (scaffold)

- **Main form**: 4 boot-module tiles (Analyze / Backup / Nuke / Reinstall)
  with include-checkboxes, USB drive picker, `New Setup...` wizard,
  `Open Setup...` (stubbed), `BUILD USB`, and a password-safe log pane.
- **New Setup wizard** (5 pages): Machine → Accounts → Apps → Options → Review.
  - Accounts: masked password boxes, match validation, held as `SecureString`,
    never written to the log.
  - Apps: `CheckedListBox` bound to `data/choco-install/apps.json` using the
    `{package, description, category, defaultSelected}` schema, with a category
    filter. Degrades to an empty list while the sibling worker populates it.
- **Build wiring**: `Invoke-PhoenixBuild` dot-sources
  `tools/New-UnattendXml.ps1` → `New-UnattendXml` and
  `tools/New-AppInstallScript.ps1` → `New-AppInstallScript`, then
  `tools/Stage-Usb.ps1` → `Stage-Usb`. If any module is missing it logs and
  shows a message box instead of crashing.

## Nuke safety

- The Nuke tile defaults to **unchecked**. Checking it opens a modal warning
  (staging ≠ running); unchecking is free.
- `BUILD USB` with Nuke staged asks for a second explicit confirmation naming
  the drive.
- The GUI **never invokes the nuke module**. Typed confirmation lives in the
  nuke module on the target machine and cannot be bypassed from here.

## Still to do / needs Windows testing

- [ ] Run on a real Windows 10/11 box; walk every wizard page at 100% and 150% DPI.
- [ ] Wire to the real `New-UnattendXml` / `New-AppInstallScript` /
      `Stage-Usb` modules when the sibling workers land (contracts are in
      `docs/GUI-PLAN.md` §2c).
- [ ] Implement `Open Setup...` / `*.phoenix.json` save-load (password is
      never stored — prompt at build time).
- [ ] Elevation story for the USB write step (relaunch `-Verb RunAs` when
      the stager needs it).
- [ ] The on-USB WinPE boot menu that consumes `usb-staging/modules.json`
      (separate worker; the GUI only stages the modules).

## Relationship to the existing launcher

`scripts/tools/gui-launcher.ps1` is the **live-machine** script runner and is
untouched. This app is the **installer builder** — a separate product that
happens to share its WinForms-in-PowerShell pattern and dark-theme styling.
