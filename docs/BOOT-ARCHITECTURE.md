# Phoenix Boot Architecture — the Ventoy multi-boot Swiss Army knife

**Status:** validated 2026-09-09. This is the target architecture. See
`docs/EMERGENCY-RUNBOOK.md` for the operator-facing procedure that rides on it.

**One-liner:** one Ventoy USB stick carries every boot environment Phoenix needs.
The Ventoy boot menu *is* the founder's Analyze / Backup / Nuke / Reinstall
menu. PowerShell runs everything Windows-side (native in WinPE); Linux-side
tools use bash as needed.

## 1. The stack (chosen + why)

| Role | Pick | Why this one |
|---|---|---|
| Multiboot layer | **Ventoy** | Drop ISOs on the stick, get a boot menu. Validated fresh 2026-09-09: YUMI exFAT itself now ships the Ventoy bootloader (v1.1.17, 07/2026); multiple 2026 sources rank Ventoy top for multiboot. Rejected: custom GRUB2 (more control, far more work — not worth it), Rufus (single-boot only, not suitable). |
| Windows-side env | **Phoenix WinPE** (ADK + WinPE add-on) | Free, official Microsoft tooling. Optional components WinPE-WMI, WinPE-NetFX, WinPE-Scripting, WinPE-PowerShell give us a real PowerShell runtime — the existing Phoenix PowerShell scripts run natively, extended not rewritten. Never build a GUI for WinPE (founder decision; the config GUI lives on a working Windows machine). |
| Nuke | **ShredOS** | Actively maintained (release days ago), boots straight into nwipe, and explicitly documents Ventoy as a supported install target. |
| Backup / clone | **Rescuezilla** | Already the project's backup standard (Ubuntu-based, desktop, image-verify built in). |
| Linux rescue / analyze | **SystemRescue** | Arch-based, full toolkit (testdisk, ddrescue, partition tools, terminal + desktop). Carried as a *separate ISO alongside Rescuezilla* — Ventoy makes a second ISO free, and analyze vs. backup are different jobs. |
| Install media | **Windows 11 ISO** (clean source media) | SHA-256/SHA-512 verified per the repo's checksum pattern (`scripts/checksum/check.ps1`). |
| File explorer in WinPE | **Explorer++** (portable) | Explicit founder requirement: must browse drives from the boot tool. Explorer++ is the standard portable pick and runs in WinPE without installation. Linux side: the file managers built into the SystemRescue/Rescuezilla desktops. |

## 2. USB layout

Ventoy repartitions the stick into two partitions. We only ever touch the
**exFAT data partition** (plain-readable from any Windows machine — this is
what makes the config-GUI split work).

```
VENTOY-USB (exFAT data partition)
│
├─ ventoy/
│   └─ ventoy.json              # menu aliases + auto-install wiring (written by Build-PhoenixUsb.ps1)
│
├─ ISOs/
│   ├─ systemrescue-<ver>-amd64.iso      # ANALYZE
│   ├─ rescuezilla-<ver>-64bit.iso       # BACKUP
│   ├─ ShredOS-<ver>_x86_64.iso          # NUKE
│   ├─ Win11_24H2_English_x64.iso        # REINSTALL (with ventoy auto_install → autounattend.xml)
│   └─ phoenix-winpe.iso                 # PHOENIX TOOLKIT (PowerShell in WinPE)
│
├─ phoenix-config.json          # written by the config GUI on a WORKING Windows machine (schema §5)
├─ autounattend.xml             # generated from phoenix-config.json (used by Ventoy auto_install)
│
└─ phoenix/
    ├─ scripts/                 # version-pinned copy of this repo's PowerShell toolbox
    ├─ tools/
    │   └─ Explorer++.zip       # portable file explorer, extracted into the WinPE WIM
    ├─ WinPE/                   # build notes + staging for phoenix-winpe.iso
    ├─ $OEM$/                   # answer-file hooks (Specialize.ps1 / DefaultUser.ps1 — VISION Phase 3)
    ├─ $WinPEDriver$/           # driver packs, per machine profile
    ├─ cache/apps/              # offline installers / choco .nupkg cache (air-gap staging)
    ├─ cache/updates/           # update catalog + MSU files
    └─ manifest.json            # SHA-256 of everything above; stager fails if anything is missing
```

> Supersedes the "Air-gap staging spec" root layout in `VISION.md` (written
> before Ventoy): everything now nests under `phoenix/` on the Ventoy exFAT
> partition instead of the USB root, except `phoenix-config.json` and
> `autounattend.xml`, which stay at root by convention (the config GUI and
> Ventoy's auto-install plugin both look at root).

**Sizing:** the ISO set alone is ~10 GB (Windows 11 ISO dominates). With
driver packs, app caches, and update catalogs, use a **≥ 64 GB stick**;
128 GB if you want real cache headroom. The old "16 GB Phoenix USB + 2 GB
Rescuezilla USB" split is gone — one stick replaces both.

## 3. The boot menu = the founder's menu

Ventoy's `ventoy.json` uses `menu_alias` to rename ISO entries, so the boot
menu reads exactly like the founder's flow:

| Boot menu entry | ISO | Founder phase |
|---|---|---|
| `[1] ANALYZE — SystemRescue` | `systemrescue-<ver>-amd64.iso` | Analyze: inspect the suspect machine without booting its OS (file manager, terminal, disk tools; bootable AV rescue ISOs can be added here later) |
| `[2] BACKUP — Rescuezilla` | `rescuezilla-<ver>-64bit.iso` | Backup: full-disk image to direct-attached USB, verified, before anything destructive |
| `[3] NUKE — ShredOS` | `ShredOS-<ver>_x86_64.iso` | Nuke: method-per-media sanitization (§8) |
| `[4] REINSTALL — Windows 11 (unattended)` | `Win11_24H2_English_x64.iso` + Ventoy `auto_install` → `/autounattend.xml` | Reinstall: unattended install driven by the generated answer file |
| `[5] TOOLKIT — Phoenix WinPE` | `phoenix-winpe.iso` | PowerShell console: run Phoenix scripts, Explorer++ file browsing, password rotation, driver work |

Ventoy's `auto_install` plugin points the Windows ISO at the answer file on
the data partition — no manual XML placement inside the ISO, no reburning.
(The `ventoy.json` for this is written by `tools/Build-PhoenixUsb.ps1`.)

## 4. Phoenix WinPE build (ADK)

Built **once, on a clean Windows machine** with the free Microsoft ADK +
WinPE add-on. Steps:

1. Install **Windows ADK** (Deployment Tools feature) and the **WinPE add-on**.
2. `copype amd64 C:\WinPE_amd64` — staging dir for the build.
3. Mount `C:\WinPE_amd64\media\sources\boot.wim` and add the optional
   components **in dependency order** with DISM `/Add-Package`:
   `WinPE-WMI` → `WinPE-NetFX` → `WinPE-Scripting` → `WinPE-PowerShell`
   (plus each package's language pack if you need a non-en-US shell).
   This is the standard documented practice for PowerShell in WinPE.
4. While mounted, inject Phoenix: copy `phoenix/scripts/` and the extracted
   **Explorer++** into the WIM (e.g. `X:\phoenix\`), and set the startup
   hook (`winpeshl.ini` or `Startnet.cmd`) to scan mounted drives for
   `\phoenix-config.json` at USB root and launch the Phoenix menu —
   `tools/Invoke-PhoenixMenu.ps1` (WinPE side) / `tools/phoenix-menu.sh`
   (Linux rescue side). The menu pair is the in-environment
   Analyze/Backup/Nuke/Reinstall dispatcher: it reads
   `phoenix-config.json` headlessly (no jq — plain text parsing on Linux,
   `ConvertFrom-Json` in WinPE), parses only the non-sensitive fields
   (`schemaVersion`, `machine.computerName`, `os.family` — the
   install-time password is never printed, echoed, or logged), and hands
   Nuke off to the nuke tools, which enforce their own interlocks. The
   menu itself is never destructive. Regression suite:
   `tests/tools/test-phoenix-menu.sh` (53 cases).
5. `MakeWinPEMedia /ISO C:\WinPE_amd64 C:\staging\phoenix-winpe.iso`,
   then drop it in `ISOs/` on the Ventoy stick.
6. Increase scratch space (`/Set-ScratchSpace`) if the PowerShell tooling
   needs it — 512 MB is the usual starting point.

The WinPE WIM is rebuilt whenever the script bundle changes; the
`phoenix/WinPE/` folder holds the build notes so it's reproducible.

## 5. `phoenix-config.json` schema (OS-agnostic from day one)

Written to the **USB root** by the config GUI — a **Svelte 5 + Tauri 2**
desktop app (sibling worker owns the app itself; this doc treats it as the
config producer). Founder-validated pick: Tauri ships ~3–30 MB binaries vs
Electron's 150–250 MB, ~50–100 MB RAM vs 200–500 MB, and it's cross-platform —
the same GUI shell can drive future macOS/Linux blades.

Boot-side scripts read the config headless: the WinPE startup hook and the
answer-file generator consume this one file today; future blades consume the
same file tomorrow. **Schema rule:** plain OS-agnostic JSON — no Windows-only
assumptions baked into the top-level keys. Windows-specific options live under
`os.answerFile` where non-Windows blades ignore them.

```jsonc
{
  "schemaVersion": 1,
  "machine": {
    "computerName": "BRANDON-PC",
    "timezone": "Central Standard Time"
  },
  "credentials": {
    "username": "brandon",
    "password": "correct-horse-battery-staple"   // see security note below
  },
  "os": {
    "family": "windows",          // "windows" today; "linux" / "macos" later
    "edition": "Professional",
    "productKey": "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX",  // or null for digital license
    "answerFile": {               // windows-only; ignored by other blades
      "disableWPBT": true,
      "partitionLayout": "gpt-uefi"
    }
  },
  "apps": [
    { "id": "googlechrome", "source": "choco" },
    { "id": "steam",        "source": "choco" }
  ]
}
```

**Security note (non-negotiable):** unattend requires the password in a
reversible form (base64-obfuscated = effectively plaintext). The USB is a
**key** — anyone holding it can read the password. Physical-security rules:
keep the stick on your person, never leave it in the machine, rotate the
install-time password at first logon (the runbook enforces this), and never
commit a real `phoenix-config.json` to the repo. This is the known tradeoff
of the unattended-install approach, not a bug to fix later.

## 6. File explorer story (founder requirement)

- **WinPE side:** portable **Explorer++** staged in `phoenix/tools/` and
  injected into the WinPE WIM. No installer, runs from RAM — browse any
  attached drive from the TOOLKIT entry.
- **Linux side:** the file managers built into the SystemRescue and
  Rescuezilla desktops. Nothing to stage; they ship with the ISOs.

## 7. Secure Boot caveats

- **First boot per machine:** Ventoy is signed with its own key. On first
  boot you'll get the blue **MOK (Machine Owner Key) enrollment screen** —
  enroll the key once, and Ventoy boots cleanly on that machine forever
  after. This is expected, not an error. Document it in the runbook's
  prep phase so nobody panics.
- Some firmwares additionally need **"Allow Microsoft 3rd Party UEFI CA"**
  enabled in the Secure Boot settings. If Ventoy won't boot and there's no
  MOK screen, check this toggle.
- Rescuezilla ≥ 2.6 carries an updated SBAT shim and should boot under
  Secure Boot; if you hit "SBAT self-check failed", re-download the newest
  build.

## 8. Nuke: method-per-media is mandatory

**CRITICAL nuance from nwipe's own docs:** nwipe **cannot** fully sanitize
SSDs — wear-levelling, overprovisioning, and remapped blocks keep data out
of reach of any overwrite pass. nwipe-only on an SSD is **insufficient**.
Per NIST 800-88 Purge, the nuke step must pick the method by media type:

- **Spinning HDD:** nwipe (ShredOS) with an appropriate pass — fine.
- **SATA/NVMe SSD:** **firmware-level sanitize first** — `nvme format
  --ses=1` / `nvme sanitize`, or the manufacturer Secure Erase utility /
  `hdparm` ATA Secure Erase — then nwipe as a supplement if desired.
- **Unknown / can't confirm media type:** treat as SSD. The destructive
  path must fail closed toward the stronger method.

The nuke module has landed as `tools/Invoke-Nuke.sh` (bash, Linux boot env —
deliberate: nwipe/hdparm/nvme-cli are Linux-only, and the destruction
interlocks must live where the destruction happens; see docs/NUKE-SAFETY.md).
It already encodes this: detects media type, refuses nwipe-only on SSDs, and
keeps the typed-confirmation + serial-number interlock from the runbook.

## 9. Build flow

Three halves, split by design:

1. **Config GUI — Svelte 5 + Tauri 2 app (sibling worker owns it):** form-driven
   `phoenix-config.json` + `autounattend.xml` generation, machine profiles, app
   picker. Writes to the Ventoy stick's exFAT partition, which is plain-readable.
2. **`tools/Build-PhoenixUsb.ps1` (this repo):** stages a Ventoy-prepared
   USB — verifies Ventoy is present, copies the ISO set with hash checks,
   writes `ventoy/ventoy.json` (menu aliases + auto-install), writes
   `phoenix-config.json` from parameters, stages scripts/tools, writes
   `manifest.json`. Static review only so far — **Windows testing required**
   before it touches a real stick.
3. **Bash twins (new workstream, tracked separately):** every Phoenix
   PowerShell script gets a bash equivalent for the Linux rescue side —
   `tools/<name>.ps1` ↔ `tools/<name>.sh`, same behavior, two implementations.
   Windows-side stays PowerShell, Linux-side is bash. This is mechanical parity
   work, not a rewrite of the Windows side: port behavior, keep the contract
   (inputs, outputs, exit codes) identical so the config and runbook work
   against either. The stager copies both trees (`phoenix/scripts/` carries
   `*.ps1` + `*.sh` side by side).

## 10. Rejected alternatives (and why)

- **Custom GRUB2 multiboot:** more control, far more work to build and
  maintain. Not worth it next to Ventoy.
- **Rufus:** single-boot only. Cannot host the five-entry menu.
- **Macrium Reflect Free:** discontinued — not a standard to build on.
- **ToolWiz Time Freeze:** reboot-to-restore sandbox, not a backup tool.
  Cannot image a disk. (Documented here because it keeps coming up.)
- **GUI in WinPE:** founder veto. WinPE is headless scripts + Explorer++.

## 12. Cross-platform future (honest constraint)

Don't build macOS/Linux blades now — but design for them (§5's OS-agnostic
schema is the down payment). The honest constraints, stated plainly:

- **The Ventoy multi-boot USB is a PC thing.** Apple Silicon Macs will not
  boot it, full stop. Mac support later is a **separate blade** (Apple's
  `startosinstall` / MDM path), not the same stick. Don't pretend the USB
  covers Macs.
- **A Linux reinstall blade can reuse the Ventoy stick later.** Drop a distro
  ISO in `ISOs/`, add a menu alias, drive it from the same
  `phoenix-config.json` (`os.family: "linux"`) — the bash twins (§9.3) are the
  execution layer for that blade. No new boot architecture needed.
- The Tauri config GUI is cross-platform from day one, so the same app
  produces configs for all future blades.

## 13. Open items

- Phoenix WinPE ISO is not built yet (needs the ADK build on a clean
  machine — §4 is the recipe).
- `Build-PhoenixUsb.ps1` is a scaffold: static review done, **not yet run
  on Windows**.
- `ventoy.json` auto-install template for the Windows ISO needs a live
  test against the generated `autounattend.xml`.
- Bootable AV rescue ISO for the ANALYZE entry is the forensics worker's
  call — the menu has room for it whenever it lands.
- Bash twins (§9.3) are underway: `tools/Build-PhoenixUsb.sh` (Linux USB
  stager, parity with `Build-PhoenixUsb.ps1`) and `tools/New-ImageProof.sh`
  (backup-phase image-proof writer; bash-native, the Linux boot side is the
  only side that needs it) have landed. Remaining parity ports per script,
  `tools/<name>.ps1` ↔ `tools/<name>.sh`, contract-identical behavior —
  tracked as its own workstream. The image-proof minter pair is complete:
  `tools/New-ImageProof.sh` (Linux backup side) + `tools/New-ImageProof.ps1`
  (Windows/WinPE side) emit byte-compatible `phoenix-image-proof/1`
  manifests; the nuke gate accepts either. The data-backup pair is complete:
  `tools/phoenix-data-backup.sh` (Linux backup side) + `tools/New-PhoenixDataBackup.ps1`
  (WinPE side) emit the same `phoenix-data-backup/1` manifest with the same
  dirty-data contract (executables skipped unless opted in, per-file SHA-256,
  scan-before-restore marker). The in-environment menu pair is complete:
  `tools/phoenix-menu.sh` (Linux rescue side) + `tools/Invoke-PhoenixMenu.ps1`
  (WinPE side) — the Analyze/Backup/Nuke/Reinstall dispatcher that reads
  `phoenix-config.json` headlessly (no jq) and hands Nuke to the nuke tools;
  the menu itself is never destructive (53-case suite
  `tests/tools/test-phoenix-menu.sh`).
