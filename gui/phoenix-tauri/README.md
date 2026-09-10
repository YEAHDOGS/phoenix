# Phoenix USB Builder (Tauri app)

The **flagship** Phoenix config GUI: Tauri 2 + Svelte 5 + Tailwind. Runs on a
**working Windows machine**, stages Ventoy ISOs onto the USB, and writes the
OS-agnostic `phoenix-config.json`. The boot side stays headless. Full design:
`../../docs/GUI-PLAN.md`.

> The WinForms launcher (`scripts/tools/gui-launcher.ps1` +
> `gui/phoenix-setup.ps1`) remains the **zero-dependency fallback** —
> maintenance only. New builder work goes here.

## Prerequisites (build machine)

- Node 20+ and npm
- Rust toolchain (stable) + Visual Studio C++ build tools (Windows)
- **WebView2 runtime** — preinstalled on Windows 11 and most Windows 10
  installs; effectively a non-issue, but it is a hard requirement
- A Ventoy-prepared USB for the build step (the app verifies, never installs,
  Ventoy)

## Develop

```powershell
cd gui/phoenix-tauri
npm install
npm run tauri dev
```

## Required spike (on a real Windows machine — not done yet)

1. `npm run tauri dev`
2. Open **Diagnostics: PowerShell streaming spike** → *Run streaming spike*
3. Stdout/stderr lines must stream live into the build log. This is the
   validated core pattern (`tauri-plugin-shell` → `phx-output` events);
   if it doesn't work, nothing below it is trusted.
4. Walk the wizard (File → … → *New Setup…*), verify Ventoy detection on a
   real Ventoy USB, implement `list_removable_drives`.

Frontend-only checks (done on Linux): `npm run check` (svelte-check),
`npm run build` (vite + adapter-static).

## Elevation

The app runs **unelevated**. UAC prompts only on the Write USB step, via a
`runas`-verb helper (designed, not yet implemented — see GUI-PLAN.md §2.2).
Do NOT stamp `requireAdministrator` on the app.

## Project layout

```
src/
  lib/
    types.ts        OS-agnostic phoenix-config.json schema + Blade types
    blades.ts       Blade registry - the seam future interfaces plug into
    store.svelte.ts Wizard state + password-safe logging (Svelte 5 runes)
    phoenix.ts      Tauri invoke wrappers + phx-output event subscription
    components/     ModuleTiles, SetupWizard, LogPane, SpikePanel
  routes/           +page.svelte (main), +layout.svelte
  app.css           Tailwind v4 theme
src-tauri/
  src/lib.rs        Commands: stream_powershell_script/_inline (the spike),
                    list_removable_drives (stub), verify_ventoy,
                    write_phoenix_config, get_app_catalog
  capabilities/
    shell.json      Whitelists powershell.exe + explicit arg allowlist
```

## Security notes

- `capabilities/shell.json` locks the JS-side shell API to `powershell.exe`
  with `-NoProfile -ExecutionPolicy Bypass (-File|-Command) <path>`.
- Passwords: masked inputs, memory-only in the GUI, never logged, cleared
  after build. Plaintext **only** in `phoenix-config.json` on the USB
  (unattend requires it) — throwaway install-time credential, changed after
  first logon.

## Honest constraints

- The Ventoy multi-boot USB is a **PC thing** — Apple Silicon Macs won't boot
  it. Mac support is a separate future blade (`startosinstall`/MDM), not the
  same stick. The config schema is OS-agnostic from day one so that blade can
  reuse this GUI.
- Never runs in WinPE (no WebView2 there by construction).
