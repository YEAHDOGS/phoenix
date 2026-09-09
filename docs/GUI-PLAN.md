# Phoenix GUI Plan — USB Builder (founder-approved architecture)

> Status: design + scaffold (2026-09-09). Static review only — no PowerShell on
> this Linux VM. **Windows-side testing still required** before this is trusted.

## 0. Architecture split (founder decision, 2026-09-09)

Two sides, hard boundary between them:

- **Config side (this GUI):** runs on a *working Windows machine*. Collects the
  setup in a wizard, stages ISOs onto the USB, and writes
  **`phoenix-config.json`** (apps selection, username/password, answer-file
  options) to the USB. That's its whole job.
- **Boot side:** reads `phoenix-config.json` and runs **HEADLESS**. No GUI in
  WinPE — that is where projects go to die.

The 4-option boot menu (Analyze / Backup / Nuke / Reinstall) is provided by
**Ventoy** (multi-boot, validated) — the GUI stages the ISOs, Ventoy renders
the menu. The GUI never constructs a boot menu.

## 1. Stack recommendation (ONE)

**Extend the existing PowerShell WinForms launcher** (`scripts/tools/gui-launcher.ps1`).
The USB builder becomes a new mode inside the launcher — a `USB Builder...`
menu entry that opens the builder dialog (`gui/phoenix-setup.ps1`,
dot-sourced as a library exposing `Show-PhoenixBuilder`).

### Why this, and not the alternatives

- **Zero new dependencies.** The launcher branch already exists, already runs,
  already solved WinForms-in-PowerShell styling, elevation
  (`#Requires -RunAsAdministrator`), and script execution with output display.
  The builder reuses all of it instead of rebuilding it.
- **Matches the repo.** Everything in Phoenix is PowerShell; the builder
  dot-sources the generator modules and calls them as functions — natural
  parameter binding, no IPC, no second toolchain, and the same people who
  write the scripts can fix the GUI.
- **One app on the working machine.** The launcher is already "the thing you
  open on a working Windows box to do Phoenix things." A builder mode keeps
  one entry point instead of two competing apps.
- The earlier idea of a separate `gui/phoenix-setup.ps1` app is superseded:
  that file is now a **library the launcher loads**, still runnable standalone
  for development.

Rejected alternatives:

- **Separate standalone app** — two apps, two menus, duplicated styling and
  elevation handling, for no gain. (This was the previous recommendation;
  the founder's split retired it.)
- **WPF/XAML** — prettier, but needs XAML design tooling and is harder to
  debug from a Linux workstation. Marginal gain for a form-driven wizard.
- **Tauri v2 + Svelte 5 + Tailwind** (VISION.md's Phase 5 pick) — buys a
  Rust+Node toolchain and an IPC boundary between the UI and the PowerShell
  modules it exists to drive. Parked; revisit only if the builder outgrows
  `.ps1`.
- **Web UI** — needs a browser/host on the build machine and has the worst
  elevation story for disk operations.
- **Any GUI inside WinPE** — explicitly vetoed by the founder.

## 2. Screen map

### (a) Launcher + Builder mode

The launcher keeps its current Scripts view untouched. Additive change only:
a **File → `USB Builder...`** menu item (and it stays working if the builder
library is absent — the item reports "builder not found" instead of crashing).

The builder dialog (1000x700, same dark theme):

```
+----------------------------------------------------------+
| PHOENIX - USB Builder                    [wizard above]   |
+----------------------------------------------------------+
|  [Analyze]      [Backup]       [Nuke]       [Reinstall]   |
|  SystemRescue   Rescuezilla    ShredOS      WinPE+Win ISO  |
|  [x] stage ISO  [x] stage ISO  [ ] stage    [x] stage ISO  |
+----------------------------------------------------------+
|  Ventoy USB: [E:\  v]  [Verify Ventoy]                    |
|  [New Setup...] [Open Setup...]  [ BUILD USB ]            |
+----------------------------------------------------------+
|  (log pane - passwords never written here)                |
+----------------------------------------------------------+
```

- Each tile = one Ventoy ISO to stage (see §5). Checkbox = "stage this ISO".
  Nuke (ShredOS) defaults OFF.
- `Verify Ventoy` checks the target drive for a Ventoy install (`ventoy/`
  dir); BUILD refuses to run against a non-Ventoy drive.
- `New Setup...` opens the wizard (§2b). `BUILD USB` stages ISOs + writes
  `phoenix-config.json` (§2c) + writes the WinPE headless payload.

### (b) "New Setup" wizard (modal dialog, hidden-tab TabControl, Next/Back)

| Page | Fields |
|---|---|
| 1. Machine | Computer name (validated: ≤15 chars, A–Z 0–9 `-`), timezone dropdown (defaults to the build machine's), Windows edition dropdown (Pro/Home/Education), product key textbox (optional; blank = generic key) |
| 2. Accounts | Username, password (masked, `UseSystemPasswordChar`), confirm password (must match). Held as `SecureString` in the GUI; written **plaintext** into `phoenix-config.json` (see security note §6) — never to the log. |
| 3. Apps | `CheckedListBox` (check-on-click) with category filter, bound to `data/choco-install/apps.json` entries `{package, description, category, defaultSelected}`. Empty/missing file → "app list not populated yet" and continue (apps are optional). |
| 4. Answer-file options | Locale, skip OOBE (default on), disable WPBT (default on), driver-pack profile dropdown, "stage updates" checkbox |
| 5. Review & Build | Read-only summary (password `••••••`), ISO/module list, target drive, `[ Build USB ]`, progress log |

Wizard state lives in one `$Setup` hashtable; `Open Setup...` / save round-trips
a `*.phoenix.json` sidecar (password omitted — re-prompted at build).

### (c) Contracts

**`phoenix-config.json`** — written by the GUI to `<USB>:\phoenix\phoenix-config.json`.
The headless boot side is the consumer.

```json
{
  "version": 1,
  "computerName": "PHOENIX-01",
  "username": "brando",
  "password": "<plaintext, see security note>",
  "timeZone": "Central Standard Time",
  "edition": "Pro",
  "productKey": "",
  "locale": "en-US",
  "options": { "skipOobe": true, "disableWpbt": true, "stageUpdates": false, "driverProfile": "" },
  "apps": ["git", "vscode"],
  "modules": ["analyze", "backup", "reinstall"]
}
```

**Generator modules** (sibling workers; the GUI dot-sources them and calls
functions — it never shells out to `powershell.exe`). Missing modules degrade
gracefully (wizard reports "not available yet", Build disabled):

- `tools/New-UnattendXml.ps1` → `New-UnattendXml -ComputerName -Username -Password(SecureString) -TimeZone -Edition -ProductKey -Options(hashtable) -OutputPath` → path. The GUI pre-generates `autounattend.xml` onto the USB at build time; the headless side can also regenerate from `phoenix-config.json`.
- `tools/New-AppInstallScript.ps1` → `New-AppInstallScript -AppsJsonPath -SelectedPackages -OfflineCachePath -OutputPath` → path.
- `tools/Stage-Usb.ps1` → `Stage-Usb -Setup -IncludeModules -TargetDrive -IsoCacheDir` → stages ISOs (download + SHA-512 verify per VISION.md), writes `phoenix-config.json`, lays down the WinPE headless payload. Fails the build if any required asset is missing.

**Headless side contract** (for the boot-side worker): WinPE `startnet.cmd`
runs `<USB>:\phoenix\headless\Start-Phoenix.ps1`, which reads
`..\phoenix-config.json` and executes without user interaction: apply the
pre-generated `autounattend.xml` path, run offline app installs from the
staged cache, apply driver profile. No windows, no prompts — prompts in WinPE
are where projects go to die.

## 3. What the scaffold implements (this branch)

- `gui/phoenix-setup.ps1` — refactored into a **dot-sourcable library**
  exposing `Show-PhoenixBuilder`; still runnable standalone for dev
  (`powershell -File gui\phoenix-setup.ps1`). Contains the builder dialog,
  the 5-page wizard, `Write-PhoenixConfig`, and `Invoke-PhoenixBuild`.
- `scripts/tools/gui-launcher.ps1` — **additive only**: a File-menu
  `USB Builder...` item that dot-sources the builder library and opens it.
  The Scripts view is untouched.
- `gui/README.md` — run/test notes.

## 4. Boot side: Ventoy mapping (for the screen map)

The founder validated Ventoy multi-boot. The GUI stages these ISOs; Ventoy's
own menu is the 4-option menu — the GUI builds no boot menu.

| GUI tile | ISO staged | Provides |
|---|---|---|
| Analyze | SystemRescue | hardware analysis, full file manager, shell |
| Backup | Rescuezilla | full-machine image backup before anything destructive |
| Nuke | ShredOS | `nwipe` secure disk wipe (own on-device confirmations) |
| Reinstall | Windows installer ISO + Phoenix WinPE payload | headless config-driven install via `phoenix-config.json` |

### File explorer requirement (founder)

Brandon wants to browse drives from the bootable tool. Accounted for, not
solved by the GUI:

- **WinPE side:** stage a portable file manager — **Explorer++** is the
  standard pick — into the WinPE payload (`<USB>:\phoenix\tools\Explorer++.zip`
  extracted, launched from the headless script or a WinPE shortcut).
- **Linux side:** SystemRescue / Rescuezilla / ShredOS all ship full file
  managers natively — nothing to stage.
- The GUI's only job here: include Explorer++ in the staging manifest and
  verify it landed.

## 5. This replaces the old §5

There is no Phoenix-built PE boot menu anymore. The old `modules.json`
manifest idea is retired — Ventoy owns the menu, `phoenix-config.json` owns
the configuration. The builder writes both the ISOs and the config; the
headless WinPE payload consumes the config.

## 6. Safety

### Nuke interlocks

- The Nuke tile (ShredOS ISO) defaults to **unchecked**. Checking it opens a
  modal warning: staging the ISO only puts the wipe tool on the USB — nothing
  runs on the build machine, and ShredOS/`nwipe` keeps its own on-device
  confirmations, which this GUI cannot bypass.
- `BUILD USB` with Nuke staged requires a second explicit confirmation naming
  the target drive.
- The GUI never invokes any wipe tool. There is no "run nuke now" anywhere in
  the builder.

### Password handling

- In the GUI: `SecureString`, masked boxes, match validation, never logged
  (`Write-SetupLog` redacts `password/secret/token/*key` keys).
- On the USB: `phoenix-config.json` carries the password in **plaintext** —
  unavoidable, because `autounattend.xml` requires it and the headless WinPE
  side must read it without a build-machine DPAPI key. Same exposure as the
  existing `win-install/autounattend.xml` in the public repo.
- Policy (matches the existing README): the password in the config is a
  **throwaway install-time credential**, changed after first logon. The GUI's
  Review page states this next to the masked password field.

## 7. Founder questions

1. **Throwaway-credential policy** — confirm: config passwords are always
   throwaway install-time creds, changed post-install. (Current assumption.)
2. **Ventoy prep** — should `Stage-Usb` expect a pre-made Ventoy USB (verify
   `ventoy/` dir, bail with instructions) or install Ventoy itself (needs the
   Ventoy package + admin)? Leaning: verify-and-bail for now.
3. **ISO pinning** — who curates the pinned ISO list + SHA-512 hashes
   (Windows 11, SystemRescue, Rescuezilla, ShredOS versions)? Sibling worker
   or a data file in repo (`data/iso-pins.json`)?
4. **Explorer++ sourcing** — download at build time (needs a pinned URL +
   hash) or vendor the portable zip in the repo?

## 8. What's still missing (not this worker's job)

- `tools/New-UnattendXml.ps1`, `tools/New-AppInstallScript.ps1`,
  `tools/Stage-Usb.ps1` (sibling workers) — the builder detects and reports
  their absence instead of crashing.
- `data/choco-install/apps.json` content (sibling worker populating).
- The headless WinPE payload (`phoenix/headless/Start-Phoenix.ps1`,
  `startnet.cmd` hook) that consumes `phoenix-config.json`.
- ISO pin list + hashes (see Q3).
- Windows-side testing: launcher → File → USB Builder → walk the wizard at
  100%/150% DPI; verify Ventoy detection against a real Ventoy USB.
