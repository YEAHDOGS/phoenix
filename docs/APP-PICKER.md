# Phoenix App Picker

Installs Brandon's chosen Windows apps automatically at first logon via Chocolatey.
Three moving parts:

| Piece | Path | Role |
|---|---|---|
| Catalog | `data/choco-install/apps.json` | Curated list: 82 packages + descriptions + categories + defaults. Source of truth for the picker GUI. |
| Generator | `tools/New-AppInstallScript.ps1` | Turns a package selection into a self-contained setup-time installer. |
| Setup hook | `win-install/autounattend.xml` (oobeSystem → `FirstLogonCommands`) | Runs the generated script at first logon. |

Nothing here touches `scripts/chocolatey/apps.ps1` — that file is the curated
source of descriptions; the JSON catalog is extracted from it (descriptions
copied verbatim).

## The catalog (`data/choco-install/apps.json`)

A JSON array of 82 objects:

```json
{
  "package": "GoogleChrome",
  "description": "Probably the most popular browser to ever browser",
  "category": "Browsers",
  "defaultSelected": true
}
```

Categories: Drivers, Utilities, File Management, Documents, Dev Tools, SDKs,
Media, Comms, Security, VPNs, Gaming, Browsers, Browser Extensions,
Manual Install.

34 packages are `defaultSelected: true` — the stuff Brandon actually uses:
Chrome, Firefox, uBlock, VS Code, Git, GitHub Desktop, Docker Desktop, WSL2,
NodeJS, Python, PuTTY, PowerShell Core, 7zip, QEMU, Steam + retro emulators
(RetroArch, PCSX2, Dolphin, SNES9x, DS4Windows), Spotify, Audacity, VLC,
GIMP, Inkscape, Discord, WireGuard, Tailscale, Wireshark, SysInternals,
SumatraPDF, Notepad++, f.lux-free minimalism… plus the NVIDIA driver/app.

One entry (`Ableton`) carries `"source": "manual"` with a note — it is not on
Chocolatey and cannot be auto-installed. The generator skips these with a
warning and leaves them as a post-install reminder for the user.

The catalog is deliberately machine-generated from `apps.ps1`; to change the
selection the picker GUI (or a text edit of `apps.json`) is the path, not the
generator.

## The generator (`tools/New-AppInstallScript.ps1`)

Run from anywhere on a machine with PowerShell:

```powershell
# Default selection straight from the catalog:
.\New-AppInstallScript.ps1 -UseDefaults -OutFile ..\..\win-install\app-install.ps1

# Or a hand-picked list:
.\New-AppInstallScript.ps1 -Packages GoogleChrome, Steam, VLC

# Bake in a custom Chocolatey source (air-gap, see below):
.\New-AppInstallScript.ps1 -UseDefaults -ChocoSource 'C:\Phoenix\Feed' -OutFile app-install.ps1
```

### Linux-side twin (`tools/New-AppInstallScript.sh`)

The build machine may be Linux (Brandon's clean room is as likely to be a
penguin as a window). The bash twin is a drop-in replacement for the
PowerShell generator — same selection rules, same fail-closed guards, same
emitted `app-install.ps1`:

```bash
./tools/New-AppInstallScript.sh --use-defaults --output win-install/staging/app-install.ps1
./tools/New-AppInstallScript.sh --packages GoogleChrome,Steam,VLC
./tools/New-AppInstallScript.sh --use-defaults --choco-source 'C:\Phoenix\Feed' --output app-install.ps1
```

Byte-parity trick: the twin **extracts its template from the `.ps1`'s own
here-string** instead of carrying a copy, then applies the PS emission rules
exactly (CRLF-joined package block, placeholder substitution, `exit 0` +
CRLF ending). One source of truth — a template edit in the `.ps1` can never
drift from the twin. Parity is machine-checked by
`tests/tools/test-app-install-twin.sh` (24/24 green; full suite green),
which byte-diffs the twin against an independent python reference port for
both selection modes and asserts the fail-closed guards (mutual exclusion,
empty selection, package-name regex, missing catalog).

The emitted `app-install.ps1` is self-contained:

1. **Bootstraps Chocolatey** if `choco` is missing (online install from
   `community.chocolatey.org`, TLS 1.2, execution-policy bypass scoped to the
   process). Refreshes the session PATH afterwards so `choco` is usable
   without a reboot.
2. **Installs the selected packages** with
   `choco install <pkg> -y --no-progress --limit-output --source=...`.
3. **Idempotent**: before each install it runs `choco list --local-only --exact`
   and skips packages that are already installed, so the script is safe to
   re-run or resume after a failure.
4. **Logged**: everything goes to `C:\Phoenix\Logs\app-install.log`
   (logging failures can never break the install).
5. **Never blocks OOBE**: it always `exit 0`, even when packages fail; failures
   are listed in the log.

## The setup-time hook

The proven unattended pattern is `FirstLogonCommands` in the `oobeSystem`
pass. `win-install/autounattend.xml` already runs
`C:\Windows\Setup\Scripts\FirstLogon.ps1` as Order 1. Two ways to wire the
generated script in:

**Option A — extra synchronous command (recommended).** Add an Order 2 entry
right after the existing one:

```xml
<FirstLogonCommands>
    <SynchronousCommand wcm:action="add">
        <Order>1</Order>
        <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
    </SynchronousCommand>
    <SynchronousCommand wcm:action="add">
        <Order>2</Order>
        <CommandLine>powershell.exe -WindowStyle "Minimized" -ExecutionPolicy "Bypass" -NoProfile -File "C:\Windows\Setup\Scripts\app-install.ps1"</CommandLine>
        <Description>Phoenix app install</Description>
    </SynchronousCommand>
</FirstLogonCommands>
```

**Option B — call from `FirstLogon.ps1`.** Add a line at the end of the existing
`FirstLogon.ps1` file block that dot-runs the app installer.

Either way, `app-install.ps1` must exist on the target machine at
`C:\Windows\Setup\Scripts\`. Get it there via the schneegans distribution share
(`$OEM$\$$\Setup\Scripts\app-install.ps1`) — the `$OEM$` folder is copied to
`C:\Windows` during setup — or generate it into that path at USB-build time.

Timing notes:

- `FirstLogonCommands` runs in the context of the first interactive logon.
  There is network access by then (drivers allowing), so the online Chocolatey
  bootstrap works.
- The install is long (30+ packages). Run it minimized/backgrounded so it does
  not sit on the desktop blocking the user; the log file is the status page.
- `choco install` installs machine-wide, so elevation matters: FirstLogonCommands
  runs elevated when the account is an administrator (the schneegans default).

## Air-gap path

When there is no network, pre-stage the packages instead of pulling them live:

1. On a connected machine, for each selected package:
   `choco download <pkg> --internalize --source=https://community.chocolatey.org/api/v2/ -o C:\Phoenix\Packages`
   (`--internalize` rewrites the embedded download URLs to the local copies.)
2. Put the folder on the Phoenix USB and copy it to the target machine
   (e.g. `C:\Phoenix\Packages`) during setup.
3. Generate the installer with `-ChocoSource 'C:\Phoenix\Packages'` — the
   emitted script then passes `--source=C:\Phoenix\Packages` and never hits
   the network. (The Chocolatey bootstrap itself is online-only, so ship
   Chocolatey on the USB too and pre-install it, or skip the bootstrap when a
   marker like `C:\Phoenix\.choco-installed` exists.)

## Testing checklist (Windows side — not done yet)

- [ ] `pwsh`/`powershell` syntax: parse the emitted script with
  `[System.Management.Automation.PSParser]::Tokenize` (zero errors).
- [ ] `PSScriptAnalyzer` clean on both the generator and one emitted sample.
- [ ] Dry-run on a test VM: generate with a tiny `-Packages` list
  (e.g. `7zip`) and run the emitted script twice — second run must skip.
- [ ] Verify log file lands at `C:\Phoenix\Logs\app-install.log`.
- [ ] Full `autounattend.xml` first-logon run in a VM with the whole default
  set; confirm OOBE completes even with a failing package injected.

## Open questions for Brandon

1. **NVIDIA drivers on by default?** Currently `Nvidia-App` and
   `Nvidia-Display-Driver` are pre-selected. On non-NVIDIA machines they fail
   gracefully (logged, skipped), but they're heavy downloads — keep them as
   defaults or move to opt-in?
2. **Manual-install items** (`Ableton`): post-install reminder on screen, a
   "pending manual installs" list in the GUI, or just ignore?
3. **JDK forest** (7/8/11/12/17/21/22): all off by default right now. Keep
   only the ones you actually target, or keep the catalog exhaustive and let
   the GUI handle it?
