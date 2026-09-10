# Phoenix answer-file generator + app picker (one-step flow)

The wipe → plug-in → rebuilt pipeline: generate a clean, debloated
`autounattend.xml` and a Chocolatey app selection, stage both on the Phoenix
USB, and the fresh Windows install configures itself with zero clicks.

Two generators, one contract:

| Script | Platform | Role |
|---|---|---|
| `scripts/Generate-Unattend.ps1` | Windows (PS 5.1+/7) | Headless/automation entry point. SecureString passwords, masked prompt fallback. |
| `scripts/generate_unattend.py` | Anywhere (stdlib only) | Cross-platform twin. Same options schema, byte-identical output for the same inputs. The Svelte+Tauri config GUI calls this headlessly with `--options-json`. |

Both fill `win-install/autounattend.template.xml` — the tokenized,
credential-free copy of the proven Schneegans-generated file. Both write to
`win-install/staging/autounattend.xml`, which is gitignored.

Related work on other branches: `tools/New-UnattendXml.ps1` + `tools/Test-UnattendXml.ps1`
(classic interactive CLI and its Pester-free suite, on `jack/phoenix-unattend-gen`)
and `tools/New-UnattendXml.sh` (bash twin, on `jack/phoenix-unattend-twin`).

## The one-step flow

1. **Analyze** (optional but wise on a suspect machine): `tools/Invoke-Analyze.*`
2. **Backup**: `tools/Invoke-Backup.*` — image the drive, copy data to Castle.
3. **Generate the answer file** (on any working machine):
   ```powershell
   .\scripts\Generate-Unattend.ps1 -ComputerName NIGHTMARE -Username brando
   # prompts for the password (SecureString -- never touches shell history)
   ```
   or headless, exactly how the GUI will call it:
   ```powershell
   .\scripts\Generate-Unattend.ps1 -OptionsJson C:\Phoenix\machine.json -Force
   ```
   ```bash
   python3 scripts/generate_unattend.py --options-json config/machine.json --force
   ```
4. **Generate the app installer**:
   ```powershell
   .\scripts\Install-Apps.ps1 -UseDefaults -Offline   # review the plan first
   ```
5. **Stage the USB**: copy `win-install/staging/autounattend.xml` to the USB
   root as `autounattend.xml` (next to `install.wim`/`install.esd`), plus the
   generated app-install script.
6. **Nuke + reinstall**: wipe the target disk, boot the USB. Setup consumes
   the answer file: partitions DISK 0 (GPT), applies the image, skips OOBE,
   creates the local admin (AutoLogon once), runs the Specialize hardening,
   and the app picker installs the selection at first logon.

> **Disk warning:** the template's windowsPE pass wipes **DISK 0** via
> diskpart (`SELECT DISK=0, CLEAN`). Verify the target disk with
> `tools/Get-DiskInventory.*` + `tools/Confirm-NukeTarget.ps1` before booting
> the USB on real hardware. See `docs/NUKE-SAFETY.md` on the payload branch.

## Option reference (`--options-json` schema)

```json
{
  "computer_name": "NIGHTMARE",
  "username": "brando",
  "password": "…",
  "standard_username": "",
  "standard_password": "",
  "timezone": "Central Standard Time",
  "edition": "Windows 11 Pro",
  "product_key": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
  "input_locale": "0409:00000409",
  "system_locale": "en-001",
  "ui_language": "en-US",
  "user_locale": "en-001",
  "telemetry": "off",
  "generated_at": "2026-09-10T14:00:00Z",
  "force": false
}
```

| Option | Default | Notes |
|---|---|---|
| `computer_name` | *(required)* | NetBIOS name, 1–15 chars `[A-Za-z0-9-]` |
| `username` | *(required)* | Primary local account: Administrators + AutoLogon (1x) |
| `password` | *(prompted)* | SecureString / getpass prompt. **Never empty, never a default.** |
| `standard_username` / `standard_password` | *(none)* | Optional second account (Users group) |
| `timezone` | `Central Standard Time` | Windows timezone ID |
| `edition` | `Windows 11 Pro` | Must match `/Name:"…"` of an image in install.wim/esd |
| `product_key` | MS generic Win11 Pro key | Public generic key, not a license; swap in a real key if you have one |
| `input_locale` | `0409:00000409` | Keyboard layout ID |
| `system_locale` / `ui_language` / `user_locale` | `en-001` / `en-US` / `en-001` | Also rewritten into the Schneegans regen URL in the file comment |
| `telemetry` | `off` | `off` appends `AllowTelemetry=0` reg blocks to the embedded Specialize.ps1; `basic` leaves the template untouched |
| `generated_at` | now (UTC) | Stamp override; fixes output byte-for-byte for the parity test |
| `force` | `false` | Overwrite an existing output file |

The generator fails closed (no partial write) on: missing template, existing
output without force, empty passwords, identical admin/standard usernames,
leftover unfilled tokens, missing locale/telemetry anchors, or malformed XML.

The Schneegans generator URL in the template header is rewritten to match the
chosen options, so a filled file stays hand-tweakable at
https://schneegans.de/windows/unattend-generator/. Password "obscuring" is
Schneegans' own scheme, reproduced exactly:
`base64( UTF-16LE( password + "Password" ) )`.

## App picker (`config/apps.json` + install scripts)

`config/apps.json` is the curated picker manifest: 26 Chocolatey package ids
with categories and `defaultSelected` flags (16 on by default). Entries with
`"source": "manual"` (currently Ableton — not on Chocolatey) are skipped by
the installer and surfaced as post-install steps.

| Script | Platform | Behavior |
|---|---|---|
| `scripts/Install-Apps.ps1` | Windows | Installs the selection via Chocolatey. Bootstraps Chocolatey if missing; idempotent (`choco list --local-only` skip); failures logged to `C:\Phoenix\Logs\app-install.log`, never fatal (never blocks OOBE); always exits 0. `-Offline` prints the plan only. `-ChocoSource <dir>` installs from a pre-staged folder (air-gap). |
| `scripts/install_apps.sh` | Linux | Prints the same plan (Chocolatey is Windows-only). Same flags; always exits 0. |

## Security notes

- **The generator is the only source of credentials. Never a committed file.**
  The template has zero credentials; the filled file has real ones and lives
  in gitignored `win-install/staging/`. Never commit, paste, or screenshot it.
- **Passwords are parameters, not files.** PS1 takes SecureString (masked
  prompt fallback, nothing in shell history); py takes `--password` or a
  getpass prompt. An `--options-json` file carrying a plaintext password is
  the GUI's headless path — treat it like the output: never commit it.
- **Obscured ≠ encrypted.** The unattend `<Password><Value>` obfuscation is
  reversible by design (Windows must read it). Anyone holding the USB can
  recover the local-admin password — physically protect the USB.
- **No default or empty passwords, ever.** Both generators refuse them. The
  regression suite asserts no well-known defaults appear in output.
- **No network, no installs.** Both generators are pure local string/XML work
  (stdlib only). They never fetch anything.

## Testing

```bash
bash tests/unattend/run.sh        # all unattend/app-picker regression tests
```

Covers: XML well-formed, all 7 passes, `Microsoft-Windows-Setup` in windowsPE,
`UserAccounts` in oobeSystem, token-free output, no default/empty passwords,
proven obfuscation hash vectors, locale + telemetry options, PS1↔py parity
(full diff when `pwsh` is available; static token-set parity otherwise),
and the `config/apps.json` schema.
