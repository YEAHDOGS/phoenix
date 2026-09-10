# Phoenix GUI Plan — USB Builder (Tauri flagship)

> Status: design + scaffold (2026-09-09). Frontend type-checked
> (`svelte-check`: 0 errors) and production-built (`vite build`: clean) on
> Linux. **Rust side is static-review only** — no Rust toolchain on this VM.
> The spike MUST be run on a real Windows machine (`npm run tauri dev` →
> Diagnostics → Run streaming spike).

## 0. Architecture split (founder decision, stands)

Two sides, hard boundary:

- **Config side (this GUI):** runs on a *working Windows machine*. Collects the
  setup in a wizard, stages Ventoy ISOs onto the USB, writes the OS-agnostic
  **`phoenix-config.json`** to the USB. That's its whole job.
- **Boot side:** reads `phoenix-config.json` and runs **HEADLESS**. No GUI in
  WinPE — that is where projects go to die.

The 4-option boot menu (Analyze / Backup / Nuke / Reinstall) is provided by
**Ventoy** (multi-boot, validated) — the GUI stages the ISOs, Ventoy renders
the menu. The GUI never constructs a boot menu.

## 1. Stack recommendation (ONE)

**Tauri 2 + Svelte 5 + Tailwind**, scaffolded from
`npm create tauri-app -- --template svelte-ts`, living at
`gui/phoenix-tauri/`. Brandon's real stack, as a single small binary.

### Tauri vs Electron — validation note (researched 2026-09-09)

| | Tauri 2 | Electron |
|---|---|---|
| Binary size | ~3–30 MB | 150–250 MB |
| Runtime RAM | ~50–100 MB | ~200–500 MB |
| Installers | Windows .msi/.exe, macOS .dmg, Linux .deb/.AppImage from one codebase | same, at 10× the weight |
| Web stack | Svelte 5 + Vite + Tailwind (his exact stack) | same, heavier shell |

Sources: tauri.app (bundle-size and concept docs), 2026 Tauri-vs-Electron
comparisons. On-brand for a debloat tool, and it fits his "all code is a
liability" rule: the whole app is one Rust binary + web UI, no Chromium
vendored per install.

### The bar for .NET

Reach for .NET/WinForms **only** if a deep-Windows-integration need arises
that Tauri provably can't do — e.g. in-process COM/WMI that can't be reached
through a spawned PowerShell (and the streaming pattern below covers nearly
all of that). Until that bar is met with evidence, .NET stays out.

### Disposition of the WinForms launcher branch

The PowerShell WinForms launcher (`scripts/tools/gui-launcher.ps1` +
`gui/phoenix-setup.ps1`) stays in the repo as the **documented
zero-dependency fallback**: no toolchain, runs anywhere PowerShell 5.1
exists. The Tauri app is the **flagship**. New builder work goes to Tauri;
the WinForms path gets maintenance only.

## 2. Validation verdict — Tauri passes all three (researched 2026-09-09)

### (1) Spawning PowerShell + streaming output — CONFIRMED, the core pattern

`tauri-plugin-shell`: `Command.create('powershell', ['-NoProfile',
'-ExecutionPolicy', 'Bypass', '-File', scriptPath])` + `.spawn()`, with
stdout/stderr streamed line-by-line to the Svelte UI
(`cmd.stdout.on('data', …)` / `cmd.stderr.on('data', …)`) — the same shape as
the ffmpeg-streaming examples in the plugin docs. Rust-side equivalent is
documented too (`ShellExt`, `CommandEvent::Stdout` → `window.emit(…)`).

The scaffold implements the **Rust-side variant** (single code path,
frontend stays dumb): `stream_powershell_script` in
`src-tauri/src/lib.rs` spawns `powershell.exe` and re-emits every
stdout/stderr line as a `phx-output` event; `+page.svelte` subscribes once
and routes lines into the log pane. `stream_powershell_inline` covers
diagnostics. This is how the GUI will drive the stager scripts
(New-AnswerFile, USB build, downloads) without blocking.

**Security:** the plugin needs explicit scope config — done in
`src-tauri/capabilities/shell.json`, which whitelists `powershell.exe` with
an explicit arg allowlist (`-NoProfile -ExecutionPolicy Bypass
(-File|-Command) <path>`). Scripts must live under the Phoenix tools dir.

**Required spike (on a real Windows machine):** Diagnostics → *Run streaming
spike* must show interleaved stdout/stderr lines arriving live in the log.
If it doesn't, nothing below it is trusted.

### (2) Elevation story — CONFIRMED, design = elevate on demand

Tauri maintainer guidance: either stamp `requireAdministrator` in the exe
manifest (embed-resource/winres in `build.rs`) or — better — run the app
**unelevated** and elevate only privileged steps via a small helper invoked
with the `runas` verb (ShellExecute) or a self-relaunch-with-runas.

Phoenix picks **on-demand elevation**, because the config app mostly needs
NO admin: picking apps and writing `phoenix-config.json` are normal file
writes. Only raw USB writes / Ventoy install need elevation. So: the app
launches unelevated, and **UAC prompts only on the "Write USB" step**.

Do NOT stamp `requireAdministrator` on the whole app: UAC on every launch,
plus elevated processes break drag-and-drop from unelevated Explorer —
both are daily friction for zero gain here.

### (3) Never in WinPE — CONFIRMED by construction

The Tauri app is WebView2 + a Rust runtime; WinPE ships neither, and the
architecture already routes WinPE through headless scripts +
`phoenix-config.json`. Stated as a hard boundary: **the config app runs ONLY
on a working Windows machine.**

One dependency to note: the build machine needs the **WebView2 runtime** —
preinstalled on Windows 11 and most Windows 10 installs, so a non-issue in
practice, but it is listed as a prerequisite in the app README.

**Verdict: Tauri passes all three.** No fallback needed beyond the
documented WinForms zero-dependency path (§1).

## 3. Scope: one app, blade registry

"Multiple smart interfaces" = **ONE Tauri config app to start** (apps
picker, credentials, answer-file options, USB writer), architected so more
interfaces plug in later. The seam is `src/lib/blades.ts`: a `Blade`
registry (`id`, `label`, `platforms`, `description`) driving the tab bar in
`+page.svelte`. Adding a second blade is a registry entry + its Svelte
view — no app rewrite.

## 4. Screen map (Tauri)

- **Header:** Phoenix branding + blade tabs (one today: *USB Builder*).
- **Module tiles:** the 4 boot options → Ventoy ISOs to stage
  (Analyze→SystemRescue, Backup→Rescuezilla, Nuke→ShredOS, Reinstall→WinPE+Win
  ISO), each with a *Stage ISO* checkbox. Nuke defaults OFF with the modal
  interlock (§8).
- **Drive row:** Ventoy USB drive field, *Verify Ventoy*, *Detect drives*,
  repo-root field (for `data/choco-install/apps.json`), *New Setup…* button.
- **Setup wizard** (modal, 5 steps): Machine → Accounts → Apps → Options →
  Review & Build. Same fields as the WinForms wizard: computer name
  (validated), masked username/password (match validation, never logged),
  app checklist with category filter bound to the
  `{package, description, category, defaultSelected}` schema, answer-file
  options (locale, skip OOBE, disable WPBT, driver profile, stage updates),
  review summary (password `••••••`), *Build USB*.
- **Diagnostics:** collapsible *PowerShell streaming spike* panel (the
  required spike, §2.1).
- **Log pane:** build log; password/secret/token/product-key keys redacted.

## 5. Contracts

### `phoenix-config.json` — OS-agnostic from day one (founder requirement)

Written by the GUI to `<USB>:\phoenix\phoenix-config.json`. Top level has
**no Windows-only keys**; a `platform` discriminator selects the OS and
anything platform-specific nests under `platformOptions`, so macOS/Linux
execution blades can plug into the same GUI later:

```json
{
  "version": 1,
  "platform": "windows",
  "credentials": { "username": "brando", "password": "<plaintext, see §8>" },
  "apps": ["git", "vscode"],
  "options": { "timeZone": "Central Standard Time", "locale": "en-US" },
  "platformOptions": {
    "windows": {
      "computerName": "PHOENIX-01", "edition": "Pro", "productKey": "",
      "skipOobe": true, "disableWpbt": true,
      "stageUpdates": false, "driverProfile": ""
    }
  },
  "modules": ["analyze", "backup", "reinstall"]
}
```

### Tauri commands (`src-tauri/src/lib.rs`)

| Command | Contract |
|---|---|
| `stream_powershell_script(scriptPath, args)` | Spawn `.ps1`, stream stdout/stderr → `phx-output` events. The stager driver. |
| `stream_powershell_inline(command)` | Same for inline snippets (diagnostics). |
| `list_removable_drives()` | → `{letter, label}[]`. **Stubbed** — wire to `Get-CimInstance Win32_LogicalDisk` in the Windows spike. |
| `verify_ventoy(drive)` | → bool. Checks `<drive>:\ventoy\`. Real, cross-platform. |
| `write_phoenix_config(drive, config)` | Writes `<drive>:\phoenix\phoenix-config.json`. Real. |
| `get_app_catalog(repoRoot)` | Reads `<repoRoot>/data/choco-install/apps.json`, `[]` if empty/missing. Real. |

### Stager / generator modules (sibling workers)

The Tauri app drives them through `stream_powershell_script` — no direct
`powershell.exe` shell-outs from JS, one streaming code path. Missing
scripts degrade gracefully (log + message, no crash).

### Headless side (unchanged)

WinPE `startnet.cmd` → `<USB>:\phoenix\headless\Start-Phoenix.ps1` reads
`..\phoenix-config.json` and runs with zero user interaction.

## 6. Boot side: Ventoy mapping (unchanged)

| GUI tile | ISO staged | Provides |
|---|---|---|
| Analyze | SystemRescue | hardware analysis, full file manager, shell |
| Backup | Rescuezilla | full-machine image backup before anything destructive |
| Nuke | ShredOS | `nwipe` secure disk wipe (own on-device confirmations) |
| Reinstall | Windows installer ISO + Phoenix WinPE payload | headless config-driven install |

### File explorer requirement (founder)

Stage **Explorer++ portable** in the WinPE payload; the Linux ISOs ship full
file managers natively. The GUI's job: include it in the staging manifest
and verify it landed.

### Honest constraint: Macs

The Ventoy multi-boot USB is a **PC thing** — Apple Silicon Macs won't boot
it, period. Mac support is a **separate blade** down the road
(`startosinstall`/MDM path), not the same stick. The OS-agnostic schema
(§5) is what keeps that door open; nothing in v1 pretends to walk through it.

## 7. What the scaffold implements (this branch)

`gui/phoenix-tauri/` (from `npm create tauri-app -- --template svelte-ts`,
Tauri 2, customized):

- **Backend** (`src-tauri/`): shell plugin wired, the six commands above,
  `capabilities/shell.json` scope whitelist, product metadata
  (Phoenix USB Builder, `net.wearedogs.phoenix`), 1100×780 window.
- **Frontend** (`src/`): Svelte 5 runes + Tailwind v4. `lib/types.ts`
  (OS-agnostic schema), `lib/blades.ts` (registry), `lib/store.svelte.ts`
  (wizard state, password-safe logging), `lib/phoenix.ts` (invoke wrappers),
  components (`ModuleTiles`, `SetupWizard`, `LogPane`, `SpikePanel`),
  routes (`+page`, `+layout`).
- **Verified on Linux:** `npm install`, `svelte-check` (0 errors, 0 warnings),
  `vite build` (clean). Rust is static-review only here.

Untouched fallback: `scripts/tools/gui-launcher.ps1` + `gui/phoenix-setup.ps1`
(zero-dependency WinForms path — maintenance only, see §1).

## 8. Safety

### Nuke interlocks

- Nuke tile (ShredOS ISO) defaults **unchecked**; checking opens the modal
  warning (staging ≠ running); unchecking is free.
- Build with Nuke staged requires explicit confirmation naming the drive.
- The GUI never invokes any wipe tool; `nwipe`'s on-device confirmations
  stand and cannot be bypassed from here.

### Password handling

- GUI: masked inputs, in-memory only, never logged (both the TS `log()` and
  the old PS `Write-SetupLog` redact secret-like keys), cleared after build.
- USB: plaintext in `phoenix-config.json` — unavoidable (unattend requires
  it; WinPE can't use the build machine's DPAPI key). Policy, same as the
  existing `win-install/autounattend.xml`: **throwaway install-time
  credential, changed after first logon.** Stated in the wizard next to the
  password fields.

### Elevation

Unelevated by default; UAC only on the Write USB step (§2.2). No
`requireAdministrator` stamp.

## 9. Founder questions

1. **Throwaway-credential policy** — confirm: config passwords are always
   throwaway install-time creds, changed post-install. (Current assumption.)
2. **Ventoy prep** — stager expects a pre-made Ventoy USB (verify `ventoy/`,
   bail with instructions) vs. stager installs Ventoy itself? Leaning
   verify-and-bail.
3. **ISO pinning** — who curates the pinned ISO list + SHA-512 hashes
   (Windows 11, SystemRescue, Rescuezilla, ShredOS)? Sibling worker or
   `data/iso-pins.json` in repo?
4. **Explorer++ sourcing** — download at build time (pinned URL + hash) or
   vendor the portable zip in the repo?
5. **.NET bar** — confirm the bar in §1: .NET only on a proven
   Tauri-can't-do-it integration need.
6. **Mac blade priority** — after v1, or explicitly later? (Schema is ready
   either way.)

## 10. What's still missing (not this worker's job)

- **Windows spike run** (required): `cargo check` / `cargo build` the Rust
  side, `npm run tauri dev`, run the Diagnostics spike, implement
  `list_removable_drives`, walk the wizard at 100%/150% DPI, verify Ventoy
  detection on a real Ventoy USB.
- `tools/` stager + generator modules (sibling workers) — driven via
  `stream_powershell_script` when they land.
- `data/choco-install/apps.json` content (sibling worker populating).
- Headless WinPE payload (`phoenix/headless/Start-Phoenix.ps1`,
  `startnet.cmd` hook) consuming `phoenix-config.json`.
- ISO pin list + hashes; Explorer++ sourcing (see Q3/Q4).
- Elevation helper for the Write USB step (`runas`-verb helper or
  self-relaunch) — designed (§2.2), not yet implemented.
