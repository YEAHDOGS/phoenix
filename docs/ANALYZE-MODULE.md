# Phoenix ANALYZE module — `tools/Invoke-Analyze.sh` (+ `.ps1` twin)

The Analyze phase of the Phoenix Ventoy USB (boot menu entry `[1] ANALYZE —
SystemRescue`, see `docs/BOOT-ARCHITECTURE.md` §3): collect disk enumeration +
hardware inventory + malware-triage data from the suspect machine **without
booting its OS**, and emit an OS-agnostic JSON triage report for the staging
machine and the task board.

Analyze is **read-only by construction** (it never mounts, writes to, or
destroys anything), but it is **identity-critical**: the serials it reports
are what the operator copies into the nuke `target_disks` allowlist, and the
Backup phase's image-proof gate binds proofs to source serials. A shifted
column or a dropped empty field here silently breaks the whole chain — so the
module carries the same serial-resolved identity machinery as the Nuke and
Backup modules.

This module is the *payload* of the Analyze menu entry. The *toolkit* staged
onto the USB for deeper work (Kaspersky Rescue Disk, Sysinternals, Emsisoft,
FTK Imager, Autopsy) is a separate concern — see `docs/ANALYSIS-TOOLKIT.md`
and `tools/Stage-AnalysisTools.ps1`. Relationship between the two:

- **Payload (this doc):** runs headless at boot, read-only, produces the
  triage report. Answers *"what hardware is here?"*
- **Toolkit (ANALYSIS-TOOLKIT.md):** operator-driven tools for *"what is on
  these disks?"* — all inspection happens against the **image** (mounted
  read-only on the staging machine) or a bootable scanner's own OS, never by
  booting the infected Windows.

## Two implementations, one contract

1. **Linux payload (this module's record):** `tools/Invoke-Analyze.sh` runs
   in the Phoenix Linux boot environment (SystemRescue). Disk enumeration via
   `lsblk -J`, with a `/sys/block` fallback when `lsblk` is unavailable;
   hardware via `lscpu`/`dmidecode` with `/proc`+`/sys/class/dmi` fallbacks.
2. **Windows twin:** `tools/Invoke-Analyze.ps1` for the WinPE side (USB menu
   entry `[5] TOOLKIT — Phoenix WinPE`) and clean staging machines. Same
   report schema, same identity rules, same atomic write. Enumerates via
   `Get-Disk` / CIM only — it contains **no destructive cmdlets** (verified
   by the regression suite).

Both emit `phoenix-analyze-report` / `report_version` **1**:

```jsonc
{
  "report": "phoenix-analyze-report",
  "report_version": 1,
  "tool": "Invoke-Analyze.sh 0.1.0",
  "collected_at": "2026-09-10T12:00:00Z",
  "machine": {
    "cpu": "Intel(R) Core(TM) i7-12700K", "cpu_count": 12,
    "ram_total_kb": 32648752,
    "bios_vendor": "Dell Inc.", "bios_version": "2.4.0",
    "system_product": "XPS 8950",
    "secure_boot": "enabled|disabled|unknown", "tpm": "present|absent|unknown",
    "network_interfaces": [{"name": "eth0", "state": "down"}],
    "efi_boot_entries": "<efibootmgr -v output, NVRAM only>"
  },
  "disks": [{
    "row": 1, "device": "/dev/nvme0n1",
    "model": "Samsung SSD 970 EVO Plus 1TB", "serial": "S6P7NX0T123456A",
    "size_bytes": 1024209543168, "transport": "nvme", "media": "SSD|HDD|unknown",
    "removable": false, "smart_support": "yes|no|unknown",
    "dup_serial": false, "has_mounted_partitions": false, "is_boot_usb": false
  }],
  "image_proof": {"provided": true, "valid": true, "source_serial": "S6P7NX0T123456A"},
  "notes": ["lsblk unavailable; enumerated via /sys/block fallback"]
}
```

## Safety model

1. **Read-only by construction.** No `mount`, no `mkfs`, no `dd`, no
   `hdparm`, no `nvme format/sanitize`, no `wipefs`, no `shred` — enforced by
   a static regression test that strips comments and greps the code. Disks
   with mounted partitions are still enumerated (the data is needed) but
   flagged `has_mounted_partitions`; the script never mounts or unmounts
   anything itself.
2. **No network.** Only interface *operstate* is read (`/sys/class/net` /
   `Get-NetAdapter Status`). Nothing is brought up, no packets are sent.
3. **No suspect-OS boot.** All data comes from the rescue kernel: sysfs,
   procfs, NVRAM (`efibootmgr -v` reads firmware variables, never the disk),
   `dmidecode`. Offline filesystem inspection is the toolkit's job, on the
   staging machine, against the mounted image.
4. **Serial-resolved identity.** Row number, `/dev` node, kernel name, or
   serial all resolve to the enumerated table. Duplicate serials are flagged
   `DUP-SERIAL` and break identity — the report refuses to pick one disk and
   says so in `notes`. Unlike the Nuke module, duplicates do **not** refuse
   the run: analyze destroys nothing, so flagging is data, not a decision.
5. **Boot-USB marking.** `--boot-device <id>` (or the `PHOENIX_BOOT_DEVICE`
   env var set by the menu launcher) marks the Phoenix stick `is_boot_usb`
   in the report, so the operator can tell the stick apart from the suspect
   disks. Unresolvable ids produce a note, never a failure.
6. **Config honesty.** `--config <phoenix-config.json>` is optional. When
   given it must validate (`Validate-UsbConfig.py`) and
   `boot_entries.analyze` must be true, else the script refuses — the stick
   must not offer Analyze unless the builder enabled it. The reader is
   `tools/Read-UsbConfig.py` (`CFG_ANALYZE_ENABLED`).
7. **Image-proof is a hint, never a gate.** `--image-proof <file>` records
   whether a structurally valid proof exists (same field rules as
   `Invoke-Nuke.sh check_image_proof` — format, `verified=YES`, 64-hex
   sha256, positive size, named serial — minus the target binding, since
   analyze has no single target). An invalid proof is noted and treated as
   absent; the run continues.
8. **Fail closed.** No disks enumerated → exit 1, no report. The report is
   written atomically (temp file + rename) and must parse as JSON, or it does
   not land — a partial/corrupt report never exists under its final name.

## Field-fidelity rules (learned the hard way)

Two real bugs shaped the implementation; both are pinned by regression tests
in `tests/tools/test-analyze-payload.sh`:

- **Bash `IFS=$'\t'` collapses empty fields.** Tab is IFS *whitespace*, so
  consecutive tabs merge and a disk with a null model/serial shifts every
  later column (serial showed the rota boolean, models showed transports).
  The `lsblk` parse now joins on `\x1f` (unit separator — never IFS
  whitespace) and every tab-split `read` uses `IFS="$SEP"`.
- **Python `or ""` drops JSON `false`.** `str(d.get("rota") or "")` turns
  `rota: false` into `""`, misclassifying every SSD as `media: "unknown"`.
  The parse now maps `None` → `""` and keeps `False` → `"False"` (normalized
  to `0` in bash).

## Test hook

`tests/tools/test-analyze-payload.sh` (36 cases): fixture `/sys`+`/proc`+`/dev`
trees plus a mock `lsblk` (failing → fallback path; JSON-emitting → parse
path). Environment overrides honored by the script: `PHOENIX_SYSFS_ROOT`,
`PHOENIX_PROC_ROOT`, `PHOENIX_DEV_ROOT`, `PHOENIX_BOOT_DEVICE`,
`PHOENIX_TOOLS_DIR`. The `.ps1` twin is covered by static contract checks
(no destructive cmdlets, `report_version` parity, parameter contract).

## Windows twin notes

`Invoke-Analyze.ps1` never images anything: like `Invoke-Backup.ps1`, the
`.ps1` side validates and triages; the Linux side is the payload of record.
`smart_support` is always `"unknown"` on the Windows side (no non-invasive
identify query is made); `has_mounted_partitions` is always `false` (the twin
never mounts — detection of mounted suspect partitions is a Linux-side
concern). Secure Boot state comes from `Confirm-SecureBootUEFI`; TPM from
`Get-Tpm`; both degrade to `"unknown"` in WinPE without the components.
