# Phoenix (desktop app)

Tauri 2 + Svelte 5 + Tailwind 4. The cockpit for the whole wipe-and-restore:
runbook, profile, answer file, packs, scan/plan, apps and the USB builder.
Contract: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## How it talks to the system

The app never builds PowerShell. The Rust backend (`src-tauri/src/lib.rs`)
spawns `engine/phoenix.ps1 <command> -ArgsPath <tmp.json>` for commands on a
fixed allowlist and forwards each NDJSON line as an `engine-event`
(`{ runId, event }`); every run ends with `engine-exit` (`{ runId, code }`).

- `engine_run` / `engine_call`: un-elevated, streams stdout.
- `engine_run_elevated`: UAC via a hidden launcher (`Start-Process -Verb RunAs`);
  the elevated engine writes events to `-LogPath`, which the app tails.
  Exit code 1223 = the UAC prompt was declined.
- `configPath` is always passed explicitly, because an elevated run may execute
  as the admin account, whose `%APPDATA%` isn't the lead user's.
- Passwords go through `secrets_write` (a temp file in `%LOCALAPPDATA%\Phoenix\tmp`,
  ACL'd to the current user) and the engine deletes it after reading.

There is no shell plugin and no frontend access to arbitrary processes.

## Finding the engine (kit root)

1. `%PHOENIX_KIT_ROOT%`
2. Walk up from the exe until a folder contains `engine\phoenix.ps1`
   (repo root in dev; `<USB>\phoenix\` when `Phoenix.exe` runs from the stick)
3. `C:\ProgramData\Phoenix\kit` (installed by the FirstLogon handoff)

`<kit>\phoenix.id` present = running from the USB kit.

## Build

Prereqs: Node 20+, Rust stable (MSVC), Visual Studio C++ build tools, WebView2
(built into Windows 11).

```powershell
npm install
npm run check          # svelte-check, must be 0 errors
npm run tauri dev      # dev window against the repo's engine
npm run tauri build    # src-tauri\target\release\phoenix.exe (+ NSIS installer)
```

The release `phoenix.exe` is portable: copy it next to `engine\` (the USB
builder does this as `\phoenix\Phoenix.exe`).
