# NUKE Safety Spec — Phoenix nuclear disk sanitization

This document is the safety contract for `tools/Invoke-Nuke.sh`. Read it in
full before running `--nuke` on anything. The short version: the script is
designed so that **doing nothing is the default, destroying something takes
five deliberate steps, and the boot USB can never be the target.**

## 1. Why nwipe, not DBAN

DBAN (Darik's Boot and Nuke) is **dead** — last release 2015, no SSD/NVMe
awareness, no UEFI-era hardware support. We standardize on
**[nwipe](https://github.com/martijnvanbrummelen/nwipe)** (v0.40, Feb 2026),
the maintained fork of DBAN's `dwipe` engine:

- Runs on any modern Linux (the Phoenix boot env), not a frozen 2015 ISO.
- Handles NVMe / 4Kn / large drives, parallel multi-disk wipes, PDF wipe
  certificates, HPA/DCO detection (needs `hdparm` + `smartmontools` present).
- Scriptable: `nwipe --autonuke --nogui --method=... --verify=... /dev/sdX`.

nwipe's own documentation is explicit: **nwipe does not fully sanitize SSDs**
(overprovisioned/spare flash is invisible to host overwrites). That is why
the module never relies on overwrite alone for flash media — see §3.

## 2. Interlocks (all structural, not advisory)

| # | Interlock | How it works |
|---|-----------|--------------|
| 1 | **Dry-run default** | No flags, or `--whatif`: enumerate only, exit 0. Destruction requires `--nuke <id>`. |
| 2 | **Explicit enumeration** | Numbered table first: device, model, serial, size, bus (TRAN), media class, flags. |
| 3 | **Never auto-select** | No default target. `<id>` must be a row number, `/dev` node, by-id path, or serial. |
| 4 | **Boot-USB guard** | The booted USB is detected (mounted partitions + `/proc/cmdline` root device) and **refused structurally** — the script exits, it does not warn-and-continue. |
| 5 | **Mounted-disk guard** | Any disk with a mounted partition is refused. You cannot nuke live media. |
| 6 | **Serial-required confirmation** | Arming requires typing the target's exact serial (or `NUKE <serial>`) on a **real terminal** — stdin must be a TTY, so piped or scripted input (`echo $serial \| Invoke-Nuke.sh --nuke ...`) is refused structurally. Y/N is not accepted. Disks without a readable serial are refused. |
| 7 | **Confirmation logging** | The typed confirmation is written to the USB log with a UTC timestamp before anything destructive runs. |
| 8 | **Abort window** | 5-second countdown after arming (Ctrl-C aborts; `--no-countdown` only for scripted VM tests). |
| 9 | **Identity re-check** | The serial is re-read immediately before execution; if it changed, the run aborts. |
| 10 | **No bare `--autonuke`** | nwipe's `--autonuke` (wipe-everything mode) is never invoked without an explicit, guard-passed device. |
| 11 | **Image-proof gate** | `--nuke` refuses without `--image-proof <file>`: a valid `phoenix-image-proof/1` manifest (written by `tools/New-ImageProof.sh` in the Backup phase) with `verified=YES`, a 64-hex sha256, a positive image size, and a `source_serial` that **matches the nuke target** — a proof for disk A cannot arm a wipe of disk B. This is runbook invariant 1 ("verified image or no wipe") enforced in code, not just documentation. `--skip-image-gate` is the emergency escape hatch: it requires typing `NUKE WITHOUT BACKUP` on a real TTY (piped input refused) and is logged. |
| 12 | **Stick policy (`--config`)** | When the stick's `phoenix-config.json` is passed explicitly (`--config /path/to/phoenix-config.json`), the stick's own policy is enforced as the outermost precondition — before the image-proof gate, before every structural refusal: `boot_entries.nuke` must be `true`; the target's serial must be on the `target_disks` allowlist (compared normalized: uppercased, whitespace-trimmed); `--skip-image-gate` is refused unless `safety.allow_skip_image_gate` is `true` (the escape hatch is compiled out of the stick otherwise); the abort countdown follows `safety.abort_countdown_seconds`. The config is validated fully first (JSON Schema + `docs/CONFIG-SCHEMA.md` §6, via `tools/Read-UsbConfig.py`); an invalid config is a hard refusal. The path is always explicit — the script never auto-discovers a config from an arbitrary attached drive; the boot menu launcher passes the stick's own `/phoenix-config.json` by path. |

## 3. NIST 800-88 mapping (Rev. 1, guidance baseline)

**Clear** = logical overwrite of all user-addressable locations (defeats
keyboard/data-recovery-utility attacks). **Purge** = firmware/physical
techniques rendering recovery infeasible even to lab attacks. **Destroy** =
physical destruction; the media can never be used again.

| Media | Method used | NIST level | Notes |
|-------|-------------|------------|-------|
| HDD (spinning, incl. USB HDD) | nwipe `--method dod522022m` (7-pass) | **Clear** | `--method gutmann` available via flag. Per NIST, a single overwrite suffices for post-2001 ATA drives; DoD 7-pass is the conservative default. |
| SATA SSD | ATA Secure Erase (`hdparm --security-erase[-enhanced]`) | **Purge** | Firmware-level; covers overprovisioned areas overwrite can't reach. |
| NVMe SSD | `nvme format --ses=1` (crypto erase), fallback `nvme sanitize -a 2` (block erase) | **Purge** | Controller-level; the correct primitive for NVMe. |
| USB flash / unknown | nwipe `--method dodshort` | **Clear** | USB bridges usually block ATA commands; best-effort only (see §4). |
| Firmware purge unsupported | nwipe fallback + **logged WARNING** | **Clear at best** | Explicitly logged as a downgrade, never silent. |
| Wipe fails / drive untrusted | Physical destruction | **Destroy** | Per nwipe guidance: a drive that errors during wipe gets destroyed, not redeployed. |

## 4. What can still go wrong (known residual risks)

- **SSD overprovisioning**: host overwrites (nwipe) cannot reach spare/retired
  flash. This is exactly why SSDs/NVMe go through firmware purge first.
  A fallback-to-nwipe run on flash is NIST Clear at best — the log says so.
- **Frozen ATA security state**: many BIOSes freeze the ATA security feature
  set at boot. The script detects `frozen` and refuses; fix is one
  suspend/resume cycle, then re-run. This is a fail-safe, not a bug.
- **USB bridges**: most USB-SATA/NVMe bridges do not pass through ATA Secure
  Erase or NVMe admin commands. Expect the nwipe fallback on external drives.
- **Firmware lies**: a compromised or counterfeit controller can report
  success without erasing. For genuinely adversarial threat models, Purge is
  followed by **Destroy** (physical).
- **HPA/DCO hidden areas**: nwipe detects and reports Host Protected
  Areas/Device Configuration Overlays when `hdparm` is present — ensure it is
  in the boot image.
- **Operator error**: typing the wrong serial arms the wrong disk — which is
  why confirmation requires the *serial*, the one identifier the operator had
  to read off the enumeration table deliberately.
- **Power loss mid-wipe**: an interrupted nwipe leaves a partially wiped disk
  (unbootable, but not certified). Re-run to completion; the log records it.
- **Remapped bad sectors (HDD)**: sectors remapped by the drive firmware keep
  old data invisible to overwrite. Acceptable for Clear; for higher assurance
  use Purge/Destroy.

## 5. Architectural decisions

- **Bash, not PowerShell**: the wipe runs in the Phoenix *Linux* boot
  environment. nwipe, hdparm, and nvme-cli are Linux-only; there is no
  PowerShell in the boot menu. A Windows pre-flight was rejected — the
  destruction interlocks must live where the destruction happens, and you
  cannot nuke a live OS disk from Windows anyway.
- **Logs live on the USB**: default log dir is `<boot-usb-mount>/phoenix-logs/`,
  one file per run: `nuke-<serial>-<UTC-timestamp>.log` (+ `.nwipe` suffix for
  nwipe's own log). `--log-dir` overrides.
- **Completion record feeds the chain**: on successful wipe,
  `write_nuke_completion` writes `nuke-completed.json` (schema
  `phoenix-nuke-completion/1`: serial, dev, model, method, NIST level,
  completed_at) into the log dir. The Reinstall chain-of-custody gate
  consumes it. Written only on completion — aborts, refusals, and dry runs
  leave no record, so a partial nuke can never masquerade as complete.
- **VM-only testing**: destructive paths are tested exclusively in QEMU on
  throwaway images. See `docs/NUKE-TEST-PLAN.md`. Never on bare metal.

## 6. Operator checklist (read aloud before arming)

1. I am booted from the Phoenix USB; the table shows my boot USB as BOOT-USB.
2. The target row's serial matches the physical label on the drive I intend to destroy.
3. I have a verified backup of anything on that disk I might want (Backup module) — and the **image-proof manifest** for it is on this USB (`--image-proof`).
4. I typed the serial — not Y, not Enter — and the log recorded it.
5. I understand the method and its NIST level from the table above.
