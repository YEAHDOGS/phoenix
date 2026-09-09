# Phoenix GUI Plan — USB Builder Wizard

> Status: design + scaffold (2026-09-09). Static review only — no PowerShell on
> this Linux VM. **Windows-side testing still required** before this is trusted.

## 1. Stack recommendation (ONE)

**WinForms in PowerShell — a new wizard app, `gui/phoenix-setup.ps1`.**
Same pattern as the existing `scripts/tools/gui-launcher.ps1` (WinForms via
`System.Windows.Forms`, Segoe UI, dark-theme styling), but a **separate product**,
not an extension of the launcher.

### Why this, and not the alternatives

The GUI's whole job is driving PowerShell modules: reading `data/*.json`,
calling the answer-file and app-install generators, staging files, writing a
USB. A WinForms `.ps1` app **dot-sources those modules and calls them as
functions** — natural parameter binding, shared scope, errors flow through,
no process-spawning plumbing. Everything the GUI needs is already guaranteed
present: every Windows 10/11 build machine ships PowerShell 5.1 + .NET
Framework WinForms. Zero compiler, zero SDK, zero second toolchain, and the
same people who write the 60 scripts can read and fix the GUI. Elevation for
disk ops is a one-liner (`#Requires -RunAsAdministrator`, or a RunAs
relaunch). The QEMU test loop can even drive the wizard's functions
headlessly, since the UI is a thin skin over plain functions.

Rejected alternatives:

- **Extend `gui-launcher.ps1`** — wrong product. The launcher runs scripts on a
  *live* machine (VISION.md keeps it as the live-machine tweak tool). The
  builder wizard configures a USB that runs on a *different* machine. Merging
  them would couple the installer to the tweak tool and risk breaking the
  working launcher. Reuse its styling conventions, not its form.
- **WPF/XAML app** — prettier, but needs XAML design tooling and is harder to
  debug from a Linux workstation (opaque XamlReader errors). Marginal gain for
  a form-driven wizard.
- **Tauri v2 + Svelte 5 + Tailwind** (VISION.md's Phase 5 pick) — the right
  answer *if* the app outgrows `.ps1`, but today it buys a Rust+Node toolchain
  and an IPC boundary between the UI and the PowerShell modules it exists to
  drive. Park it; revisit when the wizard needs real app-ness (profiles,
  update feeds, driver-pack management).
- **Web UI** — needs a browser/host on the build machine and has the worst
  elevation story of all candidates for diskpart/DISM work.

## 2. Screen map

### (a) Main form — module configuration (`gui/phoenix-setup.ps1`)

The boot flow is a **4-option menu: Analyze / Backup / Nuke / Reinstall**.
The builder GUI does not *run* that menu (it lives on the USB, in WinPE — see
§5) — it configures which modules get staged onto the USB, then builds it.

Layout (1000x700, same dark theme as the launcher):

```
+----------------------------------------------------------+
| PHOENIX - USB Builder                    [About]          |
+----------------------------------------------------------+
|  [Analyze]      [Backup]       [Nuke]       [Reinstall]   |
|  tile w/ desc   tile w/ desc   tile w/ desc  tile w/ desc  |
|  [x] include    [x] include    [ ] include   [x] include   |
+----------------------------------------------------------+
|  USB drive: [E:\  v]   [New Setup...]   [Open Setup...]   |
+----------------------------------------------------------+
|  [ BUILD USB ]                  (log pane)                |
+----------------------------------------------------------+
```

- Each tile: module name, one-line description, an **include checkbox**
  (Analyze/Backup/Reinstall default ON, **Nuke defaults OFF** — see §6).
- Toggling Nuke ON pops the warning dialog (§6). Checking it only stages the
  module; it never executes anything on the build machine.
- `New Setup...` opens the wizard (§2b). `Open Setup...` loads a saved
  `*.phoenix.json` setup file. `BUILD USB` runs the staging pipeline and
  writes the USB.
- Log pane at the bottom. **Passwords are never written to the log** — the
  logging helper redacts `Password`/`SecureString` values by key name, and the
  password lives as a `SecureString` in memory only until XML generation.

### (b) "New Setup" wizard (modal dialog, hidden-tab TabControl, Next/Back)

| Page | Fields |
|---|---|
| 1. Machine | Computer name (validated: ≤15 chars, A–Z 0–9 `-`), timezone dropdown (defaults to the build machine's), Windows edition dropdown (Pro/Home/Education), product key textbox (optional; blank = generic key) |
| 2. Accounts | Username, password (masked, `UseSystemPasswordChar`), confirm password (must match), optional "also create admin" checkbox. Password held as `SecureString`; compare via `SecureString` → cleared after use. Never logged. |
| 3. Apps | `CheckedListBox` (check-on-click) grouped by category, bound to `data/choco-install/apps.json` entries `{package, description, category, defaultSelected}`. If the file is empty/missing: show "app list not populated yet — sibling worker in progress" and continue (apps are optional). Tooltip/description column shows `description`. |
| 4. Answer-file options | Extra unattend toggles: locale, skip OOBE (default on), disable WPBT (default on), driver-pack profile dropdown, "stage updates" checkbox |
| 5. Review & Build | Read-only summary of all choices (password shown as `••••••`), module list from the main form, `[ Build USB ]` button, progress log |

Wizard state lives in a single `$Setup` hashtable; the final page serializes it
to `*.phoenix.json` (password stored only as a DPAPI-protected blob or omitted
with a prompt-at-build option — founder question §7).

### (c) How the wizard calls the generator scripts

The generators are being built by sibling workers. The wizard dot-sources them
and calls exported functions — **the GUI never shells out to `powershell.exe`**.
Missing scripts degrade gracefully (wizard shows "generator not available
yet" and disables Build).

**`tools/New-UnattendXml.ps1`** → function `New-UnattendXml`

| Parameter | Type | Source |
|---|---|---|
| `ComputerName` | string | wizard p1 |
| `Username` | string | wizard p2 |
| `Password` | SecureString | wizard p2 (converted to plaintext only inside the generator at XML-write time, then zeroed) |
| `TimeZone` | string | wizard p1 |
| `Edition` | string | wizard p1 |
| `ProductKey` | string (optional) | wizard p1 |
| `Options` | hashtable | wizard p4 (SkipOobe, DisableWpbt, Locale, DriverProfile, StageUpdates) |
| `OutputPath` | string | wizard picks `usb-staging/autounattend.xml` |
| **returns** | string | path of the written XML |

**`tools/New-AppInstallScript.ps1`** → function `New-AppInstallScript`

| Parameter | Type | Source |
|---|---|---|
| `AppsJsonPath` | string | `data/choco-install/apps.json` |
| `SelectedPackages` | string[] | wizard p3 checked items (`.package` values) |
| `OfflineCachePath` | string | `usb-staging/cache/apps` |
| `OutputPath` | string | `usb-staging/$OEM$/.../Install-Apps.ps1` (or wherever the staging contract lands) |
| **returns** | string | path of the written script |

**Build pipeline** (`BUILD USB`): the wizard hands `$Setup` + module selection
to the stager (VISION.md Phase 1 `tools/Stage-Usb.ps1`, sibling work):

```
Stage-Usb -Setup $Setup -IncludeModules @('Analyze','Backup','Reinstall')
          -StagingDir <temp> -TargetDrive 'E:' [-WhatIf]
```

The stager owns ISO download/verification, driver packs, app cache, manifest —
the GUI just collects intent and shows progress. GUI contract for the stager:
parameters in, `usb-staging/` tree + `manifest.json` out, non-zero/throw on
any missing required asset (a USB that silently skips steps is worse than no
USB).

## 3. What the scaffold implements (this branch)

`gui/phoenix-setup.ps1` — a real, runnable-on-Windows skeleton:

- Main form: 4 module tiles with include checkboxes + descriptions, USB drive
  picker, `New Setup...` / `Open Setup...` / `BUILD USB` buttons, log pane.
- Wizard dialog: 5 pages (Machine / Accounts / Apps / Options / Review),
  masked password boxes with match validation, app checklist loading
  `data/choco-install/apps.json` via the `{package, description, category,
  defaultSelected}` schema, timezone/edition dropdowns, review summary, and
  `Build USB` wiring that detects the generator scripts and reports their
  absence cleanly instead of crashing.
- `Write-SetupLog` helper that redacts password-ish keys.
- `gui/README.md` — how to run it, what's stubbed, what needs Windows testing.

Deliberately NOT in the scaffold: actual XML generation, USB writing, the
WinPE boot menu — those belong to the generator/stager/PE workers.

## 4. File map (this work)

- `docs/GUI-PLAN.md` — this document.
- `gui/phoenix-setup.ps1` — wizard app skeleton.
- `gui/README.md` — run/test notes.

Untouched: `scripts/tools/gui-launcher.ps1`, `scripts/tools/gui-lib.ps1`
(the live-machine tool keeps working exactly as before).

## 5. The on-USB 4-option menu (boundary)

The Analyze/Backup/Nuke/Reinstall menu that appears when you boot the USB is
**not a WinForms screen** — it runs in WinPE (batch/PowerShell in
`startnet.cmd` or a PE-side `.ps1` menu). The builder GUI's job ends at
staging: it writes `usb-staging/modules/{analyze,backup,nuke,reinstall}/`
plus a `modules.json` manifest listing which modules shipped and their
display order. The PE menu reads that manifest and renders the 4 options.
**This manifest contract is the handoff to whoever builds the PE menu.**

## 6. Safety: Nuke interlocks

The Nuke entry point in this GUI is **staging-only and heavily gated**:

1. The Nuke tile's include-checkbox **defaults to OFF**.
2. Checking it opens a modal warning: *"The Nuke module wipes the target
   machine's disk with no recovery. Staging it only puts it on the USB —
   nothing runs on this machine. On the target machine, Nuke still requires
   its own typed confirmation."* Buttons: `I understand — stage it` / Cancel.
3. The GUI **never invokes the nuke module directly**. There is no "test nuke"
   or "run nuke now" button anywhere in the builder. The typed confirmation
   lives in the nuke module itself (sibling worker's code); the GUI must not
   and does not bypass it.
4. `BUILD USB` with Nuke included requires a second explicit confirmation
   naming the target drive letter.

## 7. Founder questions (for Brandon)

1. **Password storage in `*.phoenix.json`:** omit the password (prompt at
   build time) or store it DPAPI-encrypted on the build machine? Leaning
   omit — unattend XML needs plaintext at write time anyway.
2. **Revisit Tauri later?** WinForms gets the wizard shipped fastest; Tauri
   stays a real option if the app grows profiles/driver-pack management.
3. **Nuke on the default USB:** keep Nuke opt-in per build (current design),
   or ship a separate "rescue USB" profile? Current: opt-in checkbox.
4. **PE menu owner:** the `modules.json` manifest contract (§5) needs a
   builder — is that a sibling worker's job, or does the GUI branch own the
   PE-side menu too?

## 8. What's still missing (not this worker's job)

- `tools/New-UnattendXml.ps1` and `tools/New-AppInstallScript.ps1`
  (sibling workers) — the wizard detects and reports their absence.
- `tools/Stage-Usb.ps1` + the WinPE boot menu + `modules.json` consumer.
- `data/choco-install/apps.json` content (sibling worker populating).
- Windows-side testing: run `powershell -File gui/phoenix-setup.ps1` on a
  Windows 10/11 box, walk the wizard, verify layout at 100%/150% DPI.
