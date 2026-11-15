# Phoenix architecture (v2)

One engine, one config, one app. Everything the app does goes through the
PowerShell engine; the app never builds PowerShell strings itself.

The repo root holds only six folders: `app/`, `config/`, `docs/`, `landing/`,
`scripts/`, `tests/`. The USB kit (`<USB>\phoenix\`) and the installed kit
(`C:\ProgramData\Phoenix\kit\`) use the same layout, so the engine finds
everything relative to the kit root (`Get-PhxKitRoot`, two levels above
`scripts\engine\`).

```
app/
  src/, src-tauri/        Tauri 2 + Svelte 5 desktop app (Phoenix.exe)
  unattend/               phoenix-unattend.exe: the Schneegans generator, wrapped
  third_party/unattend-generator/   vendored upstream library (MIT, pinned)
config/
  phoenix.example.json    example user config (no secrets)
  packs/*.json            shareable, composable hardening packs
  catalog/apps.json       offline app catalog for the Apps picker
  loadout/manifest.json   software the USB builder downloads + verifies
  profiles/*.json         per-app backup/restore profiles
  remove/*.json           legacy removal lists (services, devices, features)
docs/                     architecture, runbooks, win-install notes
landing/                  the landing page (GitHub Pages)
scripts/
  engine/
    phoenix.ps1           CLI entry point (the only thing the app spawns)
    lib/*.ps1             engine modules, dot-sourced by phoenix.ps1
    runbook.json          the wipe-and-restore stages (manual + automated)
    tests/Test-Engine.ps1 read-only self-test (safe on any machine)
  tools/                  disk tools: backup, analyze, nuke, reinstall, USB staging
  qemu/                   test VMs
  ...                     standalone utility scripts
tests/                    shell/python regression suites for scripts/tools
```

Target runtime: **Windows PowerShell 5.1** (a fresh install has no pwsh).
Engine code must run on 5.1 and 7.x. No modules from the gallery.

## The flow

| # | Stage | Who | Network |
|---|---|---|---|
| 1 | Configure profile, accounts, packs, apps; build the Phoenix USB | App, on any PC | online |
| 2 | Remove Wi-Fi card | manual | - |
| 3 | BIOS: secure-erase SSD, boot from Win11 USB | manual | - |
| 4 | Windows Setup reads `autounattend.xml` from the Phoenix USB root, installs, auto-logs on the admin | automated | offline |
| 5 | FirstLogon finds the Phoenix USB, copies the kit to `C:\ProgramData\Phoenix\kit`, runs phase **admin**, powers off | automated | offline |
| 6 | Unplug Win11 USB. Log on admin, run Dogs Playbook in AME Wizard (Defender must be off for AME) | manual (app launches AME) | offline |
| 7 | Phase **admin-post**: Defender back on, offline signatures, ASR, optional BitLocker; power off | app | offline |
| 8 | Log on lead user. Phase **user-offline**: per-user privacy/settings, tools, env vars, `$PROFILE` | app (elevates via UAC for machine-wide parts) | offline |
| 9 | Power off, reinsert Wi-Fi card | manual | - |
| 10 | Phase **user-online**: device pass for new hardware, adapter bindings, firewall install window, Chocolatey bootstrap + apps, close window | app | online |
| 11 | Breathe | manual | - |

Phase ids: `admin`, `admin-post`, `user-offline`, `user-online`.

## Accounts and least privilege

- `admin` - the only Administrator (e.g. `BigMan`). Auto-logon once, for phase admin.
- `lead` - standard user (Users group). Daily driver. Elevates with the admin's credentials via UAC.
- `users[]` - any number of standard users.

**Passwords are never stored in config or packs.** They are typed at USB-build
time, passed to the engine in a temp secrets file that the engine deletes after
reading, and written only into `autounattend.xml` on the USB (the unattend
format requires them; base64 there is obfuscation, not encryption). The app
warns the user to change them after install.

## User config (`phoenix.config.json`)

Stored by the app in `%APPDATA%\Phoenix\phoenix.config.json` and copied to the
USB as `\phoenix\phoenix.config.json`.

```json
{
  "schema": 1,
  "machine": {
    "computerName": "THE-MACHINE",
    "timeZone": "Central Standard Time",
    "edition": "Windows 11 Pro",
    "productKey": "",
    "uiLanguage": "en-US",
    "systemLocale": "en-001",
    "userLocale": "en-001",
    "inputLocale": "0409:00000409",
    "diskNumber": 0
  },
  "accounts": {
    "admin": { "name": "BigMan" },
    "lead":  { "name": "Main" },
    "users": [ { "name": "Kid" } ]
  },
  "packs": ["base", "tier-balanced", "hw-hp-omnibook"],
  "overrides": {
    "steps": { "<stepId>": { "enabled": false } },
    "items": { "<stepId>": [ { "key": "<itemKey>", "enabled": false } ] }
  },
  "apps": ["git", "vscode", "7zip"],
  "loadout": ["sysinternals", "platform-tools", "rufus", "ame-wizard"],
  "usb": { "label": "PHOENIX" }
}
```

## Packs (`config/packs/<id>.json`)

```json
{
  "id": "base",
  "name": "Base",
  "description": "What every Phoenix machine gets.",
  "version": 1,
  "steps": [ <Step>, ... ]
}
```

Packs are applied in the order listed in config. A later pack's step with the
same `id` **merges into** the earlier one: scalar fields are replaced, `items`
are merged by item key (later wins; an item with `"enabled": false` turns it
off). Config `overrides` apply last. Packs are plain files: share them, trade
them, diff them.

### Step

```json
{
  "id": "services.disable",
  "phase": "admin",
  "kind": "services",
  "title": "Disable unneeded services",
  "why": "Shrinks attack surface and stops telemetry.",
  "risk": "safe | caution | danger",
  "enabled": true,
  "items": [ <Item>, ... ]
}
```

`danger` steps and items are never enabled by a pack by default; the user must
turn them on in the app.

### Step kinds and their items

Every item may carry `key` (stable id used for merging/overrides; defaults
shown below), `why`, `risk`, `enabled`.

| kind | item fields | default key | apply semantics |
|---|---|---|---|
| `setting` | `setting`, `value` (see named settings below) | `setting` | named, built-in system setting |
| `services` | `name` (service name, wildcards ok), `startup`: `Disabled`\|`Manual`\|`Automatic`, `stop`: bool | `name` | Set-Service startup; stop if asked. Missing service = skipped, not an error |
| `devices` | `match`: `{ "friendlyName": "WAN Miniport*" }` or `{ "instanceId": "ROOT\\*" }` or `{ "class": "Bluetooth" }`, `action`: `disable`\|`remove`, `includeHidden`: bool (default true) | JSON of `match` | `pnputil /disable-device` or `/remove-device` |
| `tasks` | `path` (task path + name, wildcards ok), `action`: `disable` | `path` | Disable-ScheduledTask |
| `features` | step-level: `removeAll`: bool, `keep`: [names]; items: `{ "name": "...", "action": "remove"\|"keep" }` | `name` | Disable-WindowsOptionalFeature `-NoRestart`; also Windows capabilities when `capabilities: true` |
| `appx` | `pattern` (package name wildcard), `action`: `remove`\|`keep`, `provisioned`: bool (default true) | `pattern` | Remove-AppxPackage -AllUsers + Remove-AppxProvisionedPackage |
| `registry` | `path` (`HKLM:\...`, `HKCU:\...`), `name`, `type` (`DWord`\|`QWord`\|`String`\|`ExpandString`\|`MultiString`\|`Binary`), `value`, `scope`: `machine`\|`current-user`\|`default-user`\|`all-users` | `path\name` | Set-ItemProperty; default-user loads `C:\Users\Default\NTUSER.DAT` |
| `autoruns` | step-level: `categories`: [`logon`], `keep`: [entry name wildcards]; items: `{ "name": "...", "action": "disable"\|"keep" }` | `name` | Run/RunOnce values move to an `AutorunsDisabled` subkey; Startup-folder items move to an `AutorunsDisabled` folder (same convention Sysinternals Autoruns uses, so Autoruns can re-enable them) |
| `firewall` | step-level: `defaultInbound`, `defaultOutbound`: `Block`\|`Allow`, `logging`: bool, `keepGroups`: [display groups], `disableOtherRules`: bool; items: `{ "name": "...", "direction": "Outbound", "program": "%ProgramFiles%\\...", "action": "Allow"\|"Block" }` | `name` | NetSecurity cmdlets. Rules Phoenix creates are in group `Phoenix` |
| `network` | items: `{ "binding": "ms_tcpip6", "enabled": true }` (adapter component bindings); step-level `onlyBindings`: [component ids] | `binding` | Set-NetAdapterBinding on all physical adapters |
| `defender` | step-level: `realtime`: bool, `asr`: `Block`\|`Audit`\|`Off`, `asrExclude`: [rule GUIDs], `signaturesFrom`: `usb`\|`online`\|`none` | - | Set-MpPreference, Add-MpPreference ASR, MpCmdRun signature update from the kit |
| `bitlocker` | step-level: `enable`: bool, `recoveryKeyTo`: `usb` | - | Enable-BitLocker (TPM), recovery key saved to the Phoenix USB |
| `choco` | step-level: `bootstrapFrom`: `usb`\|`online`, `window`: `{ "minutes": 30 }`; apps come from config `apps` | - | opens the firewall install window, installs Chocolatey (from the kit's nupkg if present), installs apps, always closes the window in `finally` |
| `tools` | items: `{ "loadout": "sysinternals", "dest": "C:\\Tools\\Sysinternals" }`, `{ "env": "PATH+", "value": "C:\\Tools\\Sysinternals" }`, `{ "profileSnippet": "..." }` | `loadout`/`env`/`profileSnippet` | copies loadout items from the kit, sets env vars, appends to `$PROFILE` |
| `manual` | step-level: `instructions` (markdown), `launch`: `{ "loadout": "ame-wizard", "args": [...] }` | - | never automated; shown in the app with a "mark done" button |

### Named settings (`kind: setting`)

`pagefile: off`, `hibernate: off`, `fast-startup: off`, `crash-dump: off`,
`remote-assistance: off`, `remote-desktop: off`, `device-install-from-wu: off`,
`uac: always-notify`, `time-server: <host>`, `llmnr: off`, `netbios: off`,
`activity-history: off`, `search-web: off`, `cross-device-share: off`,
`game-dvr: off`, `network-throttling: off`, `task-history: on`.

## Engine CLI

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\engine\phoenix.ps1 <command> [-ArgsPath <json>] [-LogPath <file>]
```

`-ArgsPath` points at a JSON file with the command's arguments (the app writes
it to a temp dir). The engine writes **NDJSON events** to stdout, one per line,
and also appends them to `-LogPath` when given (used for elevated runs, whose
stdout the app can't see). Exit code 0 = success, 1 = failure, 2 = needs admin.

| command | args | result `data` |
|---|---|---|
| `version` | - | `{ engineVersion, psVersion, isAdmin, os, kitRoot }` |
| `profile` | `{ configPath }` | resolved steps (packs merged + overrides) |
| `packs` | - | list of available packs (id, name, description, step count) |
| `plan` | `{ configPath, phase? }` | per step: list of `change` events: `{ step, key, current, target, action }` |
| `apply` | `{ configPath, phase, steps?: [ids], unattended?: bool }` | needs admin; snapshots first; summary |
| `undo` | `{ snapshotId }` | restores services, registry, firewall, autoruns from a snapshot |
| `snapshots` | - | list |
| `scan` | - | `{ manufacturer, model, bios, cpu, gpus, ram, disks, nics, devices: [...], hidden, services, features, appx, autorunsCount }` |
| `state` | - | `{ stages: { <stageId>: { status, at } } }` from `C:\ProgramData\Phoenix\state.json` |
| `mark` | `{ stage, status }` | marks a runbook stage done/skipped |
| `runbook` | - | `scripts/engine/runbook.json` merged with state |
| `drives` | - | removable USB disks: `{ number, letter, label, sizeBytes, busType, fileSystem, isBoot, isSystem }` |
| `unattend` | `{ configPath, secretsPath, outPath }` | writes answer file; deletes secrets file; returns `{ outPath, sha256 }` |
| `loadout` | - | manifest items + cache status `{ id, name, cached, version, sha256, sizeBytes }` |
| `fetch` | `{ items: [ids] }` | downloads to `%LOCALAPPDATA%\Phoenix\cache`, verifies, records in `cache\lock.json` |
| `usb-build` | `{ configPath, secretsPath, driveLetter, items: [ids] }` | writes kit to the drive; returns file list + `SHA512SUMS` |
| `usb-verify` | `{ driveLetter }` | re-hashes against `SHA512SUMS` |
| `choco-search` | `{ query }` | `[ { id, title, version, summary, downloads } ]` from the community feed |
| `launch` | `{ loadout, args? }` | starts a loadout tool from the kit (e.g. AME Wizard with the playbook) |

Shared helpers in `scripts/engine/lib/Util.ps1`: `Get-PhxDataRoot`, `Get-PhxCacheRoot`,
`Get-PhxKitRoot`, `Get-PhxPacksRoot`, `Resolve-PhxConfigPath`, `Get-PhxConfig`,
`Read-PhxJson`, `Write-PhxJson`, `Assert-PhxAdmin`, `Read-PhxSecrets`, `Get-PhxSha`.
`ConvertTo-PhxHashtable` and `Test-PhxIsAdmin` live in `phoenix.ps1`.

### Event schema

```json
{ "t": "log",      "ts": "2026-11-14T17:00:00Z", "level": "info|warn|error", "msg": "..." }
{ "t": "step",     "ts": "...", "step": "services.disable", "status": "start|ok|skip|fail", "msg": "..." }
{ "t": "change",   "ts": "...", "step": "...", "key": "DiagTrack", "current": "Automatic", "target": "Disabled", "action": "set|remove|disable|skip", "applied": false }
{ "t": "progress", "ts": "...", "step": "...", "pct": 42, "msg": "..." }
{ "t": "result",   "ts": "...", "ok": true, "data": { ... } }
```

Exactly one `result` event ends every command (also on failure: `ok: false`,
`data.error`).

## Answer file: Schneegans generator, wrapped

The answer file is generated by [cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator)
(MIT, the library behind schneegans.de), vendored at `app/third_party/unattend-generator`
and wrapped by `app/unattend/` (a .NET console app, `phoenix-unattend.exe`). Every
option the website offers is available, offline, and no password ever leaves
the machine.

The wrapper is **reflection-driven**, so new upstream options appear without
Phoenix code changes:

```
phoenix-unattend schema                       -> JSON schema of the whole Configuration
phoenix-unattend generate --in <dto.json> [--secrets <json>] --out <xml>
phoenix-unattend defaults                     -> Phoenix's default DTO
```

Engine commands: `unattend-schema` (args `{}`) returns the schema;
`unattend-defaults` returns the default DTO; `unattend` (args `{ configPath, secretsPath, outPath }`) generates.

### Schema format (`unattend-schema` result `data`)

```json
{
  "root": "Configuration",
  "types": {
    "Configuration":            { "kind": "record", "params": [ <Param>, ... ] },
    "ILanguageSettings":        { "kind": "interface", "implementations": ["InteractiveLanguageSettings", "UnattendedLanguageSettings"] },
    "UnattendedLanguageSettings": { "kind": "record", "params": [ ... ] },
    "ExpressSettingsMode":      { "kind": "enum", "values": ["Interactive", "EnableAll", "DisableAll"], "flags": false },
    "ImageLanguage":            { "kind": "keyed", "options": [ { "id": "en-US", "label": "English (United States)" } ] }
  },
  "groups": [ { "id": "region", "label": "Region and language", "params": ["LanguageSettings", "TimeZoneSettings"] } ]
}
```

`<Param>` = `{ "name", "type", "nullable", "collection": null|"list"|"set"|"dict", "keyType"?, "default"?, "label", "help"? }`.
`type` is a schema type name or a primitive: `string`, `bool`, `int`, `bytes` (base64), `ComponentAndPass`.

### DTO format (`config.unattend`)

The DTO mirrors the schema: a record is an object of its params; an
interface-typed value is an object with `"$type": "<implementation>"` plus that
implementation's params; a keyed type is its `id` string; an enum is its name;
lists/sets are arrays; the Components dictionary is `[ { "component", "pass", "xml" } ]`.

### What Phoenix adds on top of the DTO

`unattend` merges these into the DTO before generating, so the user can't
accidentally drop them:

- **Accounts** from `config.accounts`: admin (Administrators, auto-logon once),
  lead and users (Users group), with passwords from the secrets file. Used
  unless `config.unattend.AccountSettings.$type` is set explicitly and
  `config.unattendAccountsFromProfile` is `false`.
- **FirstLogon handoff script**: finds `\phoenix\phoenix.id` on any volume,
  copies `\phoenix` to `C:\ProgramData\Phoenix\kit`, runs phase `admin`
  unattended. Appended to `ScriptSettings.Scripts`.
- Machine fields from `config.machine` (computer name, time zone, edition,
  product key, locales) when the DTO leaves them unset.

## State and snapshots (on the target machine)

```
C:\ProgramData\Phoenix\
  kit\            copy of the USB's \phoenix folder (engine, packs, config, loadout)
  state.json      runbook stage status
  logs\<ts>-<command>.ndjson
  snapshots\<ts>-<phase>\  services.json, registry.json, firewall.wfw, autoruns.json, meta.json
```

State lives on the machine, not the USB, so a write-locked (Rock) USB works.

## USB layout

```
<USB root>\
  autounattend.xml          Windows Setup scans removable-drive roots for this
  phoenix\
    phoenix.id              marker FirstLogon uses to find the drive
    Phoenix.exe             the app (portable)
    phoenix.config.json
    scripts\engine\         the engine (same layout as the repo)
    config\packs\ config\catalog\
    config\loadout\manifest.json
    config\loadout\<id>\... verified downloads (Sysinternals, AME Wizard, dogs-playbook.apbx, ...)
    SHA512SUMS
```
