# Phoenix Boot-Menu Entry Spec

**Companion to `BOOT-ARCHITECTURE.md` §3** (the founder's menu). That section
says *what* the five entries are; this spec pins down *how each entry boots,
what it consumes, and what it must refuse* — the contract any menu
implementation (Ventoy today, something else tomorrow) must satisfy.

The menu is produced by `tools/Build-PhoenixUsb.ps1` (§2: `ventoy/ventoy.json`
with `menu_alias` + `auto_install`). `phoenix-config.json` (schema v1) at the
USB root is the only headless input the boot side reads — see the
"Injections" column per entry.

## Entry contract (applies to all)

1. **No entry destroys data except `[3] NUKE`** — and NUKE never arms from
   the menu itself; it drops to the sanitization shell where
   `tools/Invoke-Nuke.sh` enforces its interlocks (dry-run default, typed
   serial+size on a real TTY, structural boot-USB/mount refusals).
2. **Every entry must boot read-only with respect to the internal disk.**
   Imaging/analysis tools mount the suspect disk read-only unless the
   operator explicitly remounts. The boot menu never auto-mounts internal
   partitions read-write.
3. **Secure Boot**: entries boot via Ventoy's shim. If an entry fails SBAT
   validation, the menu must surface the failure and offer the next entry —
   never silently boot a different entry.
4. Entry numbering is stable: `[1]` ANALYZE, `[2]` BACKUP, `[3]` NUKE,
   `[4]` REINSTALL, `[5]` TOOLKIT. Renaming an ISO must not renumber the menu
   (`menu_alias` is keyed on the image path, not position).

## The five entries

### `[1] ANALYZE — SystemRescue`

| Field | Spec |
|---|---|
| Image | `systemrescue-<ver>-amd64.iso` in `/ISOs/` (Ventoy `menu_alias`) |
| Kernel params | `checksum` (verify the ISO's own integrity at boot) |
| Injections | None from `phoenix-config.json`. Ships `scripts/tools/netmon.sh` + the analysis toolkit on the data partition for the "is it phoning home?" check. |
| Operator flow | File manager / terminal / disk tools; optional bootable AV rescue ISO (forensics worker's call — the menu has room for it). |
| Fallback | If the ISO is missing or fails SBAT, offer `[5] TOOLKIT` (WinPE) for file-level triage; never fall through to `[4] REINSTALL`. |
| Refusals | Must not mount the internal disk read-write without an explicit operator command. |

### `[2] BACKUP — Rescuezilla`

| Field | Spec |
|---|---|
| Image | `rescuezilla-<ver>-64bit.iso` in `/ISOs/` (Ventoy `menu_alias`) |
| Kernel params | Default (Rescuezilla handles its own hardware probing) |
| Injections | None from `phoenix-config.json` today. Future: `backup.imageTargetPath` / `backup.quarantineLabel` (GUI schema work in flight) pre-fill the destination naming. |
| Operator flow | Backup → select the **entire source disk** (bootloader + recovery + hidden partitions) → destination = **direct-attached USB only** (never a network share; the machine is air-gapped) → compression + post-backup integrity check ON. Name: `laptop-fulldisk-<YYYY-MM-DD>`. |
| Fallback | If Rescuezilla fails to boot, `[5] TOOLKIT` (WinPE) + `diskpart`/DISM capture is the manual fallback — documented in the runbook, not automated. |
| Refusals | The backup entry never writes to the internal disk. It must refuse to start if the destination is smaller than the source disk. |

### `[3] NUKE — sanitization shell`

| Field | Spec |
|---|---|
| Image | `ShredOS-<ver>_x86_64.iso` in `/ISOs/` (Ventoy `menu_alias`) as the firmware-purge vehicle; `tools/Invoke-Nuke.sh` is the Phoenix-native path (runs in any Linux boot env with nwipe/hdparm/nvme-cli). |
| Injections | None. The nuke module deliberately takes no config — target selection is always explicit and interactive. |
| Operator flow | Boot → `Invoke-Nuke.sh` enumerates (dry-run, exit 0) → operator picks a row → **two-factor typed confirmation** (serial + displayed size, real TTY only) → 5s abort window → serial re-verified → method-per-media (NIST 800-88: HDD→nwipe DoD 5220.22-M, SATA SSD→ATA Secure Erase, NVMe→`nvme format --ses=1`). Full log to the USB. |
| Fallback | None — there is no "softer" nuke. If the purge method is unsupported for the media, `Invoke-Nuke.sh` falls back to nwipe and logs the downgrade as a warning. |
| Refusals | The boot USB and any disk with mounted partitions are refused **structurally** (exit 1, no log). Piped/scripted confirmation is refused (TTY interlock). Disks without a readable serial are refused. **The nuke phase must refuse to run without proof of a verified image** — the operator checklist in `NUKE-SAFETY.md` is the enforcement until the menu automates it. |

### `[4] REINSTALL — Windows 11 (unattended)`

| Field | Spec |
|---|---|
| Image | `Win11_24H2_English_x64.iso` in `/ISOs/` (Ventoy `menu_alias` + `auto_install` → `/autounattend.xml`) |
| Ventoy wiring | `auto_install: [{ image: "/ISOs/<win>.iso", template: "/autounattend.xml" }]` — the answer file lives at the USB root (or data partition); no ISO reburning, no manual XML placement. |
| Injections | `phoenix-config.json` → generated by the config GUI (or `tools/New-UnattendXml.ps1`): computerName, timezone, credentials (throwaway install-time), edition, productKey, `os.answerFile` (disableWPBT, partitionLayout), `apps[]` (choco ids → FirstLogon install). |
| Operator flow | Boot → Ventoy injects the answer file → unattended install (wipes DISK 0 per the answer file's diskpart section, applies the image, injects `$WinPEDriver$`, runs `$OEM$` Specialize/DefaultUser/FirstLogon) → AutoLogon once → app install → **password rotation at first logon** (runbook Step 4.2). |
| Fallback | If `autounattend.xml` is missing or fails XML validation at staging time, `Build-PhoenixUsb.ps1` must refuse to write the `auto_install` entry (a Windows ISO with no answer file boots to manual setup — acceptable, never a half-wired unattended install). |
| Refusals | The answer-file generator refuses: missing template, existing output without `-Force`, empty passwords, leftover unfilled tokens, malformed XML. The stager never ships a real `phoenix-config.json` in the repo. |

### `[5] TOOLKIT — Phoenix WinPE`

| Field | Spec |
|---|---|
| Image | `phoenix-winpe.iso` in `/ISOs/` (Ventoy `menu_alias`) — built once on a clean machine with the ADK + WinPE add-on (recipe: `BOOT-ARCHITECTURE.md` §4). |
| Startup | `winpeshl.ini`/`Startnet.cmd` scans mounted drives for `\phoenix-config.json` at USB root, mounts `phoenix/scripts/`, opens the PowerShell console. |
| Injections | Reads `phoenix-config.json` headless (same file as `[4]`). Never writes it. |
| Operator flow | PowerShell console: Phoenix toolbox scripts, Explorer++ file browsing, password rotation, driver work, manual DISM capture fallback for `[2]`. |
| Fallback | N/A — the toolkit IS the fallback. |
| Refusals | WinPE never auto-runs destructive scripts; every destructive action is an explicit operator command in the console. |

## Wiring checklist (for the stager)

- [ ] All five ISOs staged under `/ISOs/` with SHA-256 recorded in the build manifest.
- [ ] `ventoy/ventoy.json` written: 5 `menu_alias` entries + 1 `auto_install` (REINSTALL only).
- [ ] `/autounattend.xml` present at the USB root when REINSTALL is staged (else no `auto_install` entry).
- [ ] `phoenix-config.json` (schema v1) at the USB root; no real credentials committed to the repo.
- [ ] `phoenix/scripts/` (incl. `.sh` bash twins) + `phoenix/tools/` staged for `[5]` and the Linux entries.

## Open items

- `ventoy.json` `auto_install` needs a live test against a generated `autounattend.xml` (tracked in `BOOT-ARCHITECTURE.md` §13).
- Bootable AV rescue ISO for `[1]` is the forensics worker's call.
- `[3]`'s "refuse without verified image" is an operator checklist today; automating it (menu reads the backup log before offering NUKE) is future work.
