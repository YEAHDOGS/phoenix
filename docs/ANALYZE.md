# ANALYZE Phase — read-only disk triage before Backup

**Scope of this doc:** the Phoenix *Analyze* phase tooling — strictly
READ-ONLY triage that runs **before** the Backup phase of the emergency
runbook (boot menu item "Analyze" → "Backup" → "Nuke" → "Reinstall").
It enumerates disks, inventories partitions, runs heuristic filesystem
scans, and writes a `phoenix-triage-report/1` JSON report. It implements
the manual-mode steps of the emergency runbook Phase 1 (runbook branch
`jack/phoenix-runbook`).

> `docs/EMERGENCY-RUNBOOK.md` does not exist on this branch yet; when the
> runbook lands, link Phase 1 to this doc.

## 1. Components

| File | Role |
|---|---|
| `tools/lib/analyze-gates.sh` | Bash gate library, sourced by the flow. Disk enumeration (`analyze_enumerate_disks`), partition inventory (`analyze_partition_inventory`), the **read-only self-check** (`analyze_assert_readonly`), the read-only mounter (`analyze_ro_mount`), the report-dir gate (`analyze_require_report_dir`), heuristic scans (`analyze_scan_mount`), report assembly (`analyze_write_report`). |
| `tools/Analyze-DiskTriage.sh` | Linux / boot-environment triage flow: self-check → enumerate → partition inventory → scans → report. |
| `tools/Analyze-DiskTriage.ps1` | WinPE / staging-side twin: same report shape, same heuristics, same read-only contract (its own `Assert-ReadOnly` self-check). |
| `tests/tools/test-analyze.sh` | Regression suite (22 cases, fully mocked — no real disks). |

## 2. The read-only guarantee (enforced, not documented)

1. **Self-check on startup** (`analyze_assert_readonly`, `Assert-ReadOnly`):
   the flow scans every file in the Analyze toolchain — the lib, itself,
   and the PowerShell twin — for forbidden write patterns (`dd of=/dev`,
   `mkfs`, `wipefs`, `blkdiscard`, `mount -o rw`, `Format-Volume`,
   `Clear-Disk`, `Initialize-Disk`, `Remove-Partition`, …) and FAILS CLOSED
   if any match. A tool that somehow gained a write path cannot start.
2. **Read-only mounts only**: partitions the flow mounts itself go through
   `analyze_ro_mount`, which refuses any options string containing "rw"
   (substring match — `errors=remount-ro` is refused too) and adds
   `noload` for ext filesystems (no journal replay touches the disk).
3. **Report never on the target**: `analyze_require_report_dir` refuses
   `/` and any directory whose backing device lives on a triaged disk.
   The normal case is a dir on the Phoenix boot USB itself — the wipe can
   never destroy the triage report.

## 3. What the triage reports

Per disk: the full `phoenix-disk-inventory/1` record plus a partition
inventory (name, size, fstype, label, parttype, mountpoint).

Indicators come in two flavors:

- **Structural** (`heuristic: false`) — facts, not guesses. Currently one:
  `UNKNOWN_PARTITION` (a partition with no recognized filesystem; may be
  recovery/EFI/raw — informational).
- **Heuristic** (`heuristic: true`, title prefixed `HEURISTIC:`) — triage
  signals for the operator, never verdicts:
  - `OVERSIZED_TEMP` — temp dir over 2 GiB (override:
    `PHOENIX_ANALYZE_TEMP_MAX_KB`); malware staging loves `%TEMP%`.
  - `RECENT_SYSTEM_MODIFY` — files under system dirs modified in the last
    24 h (cap 5); legitimate updaters do this too.
  - `AUTORUN_ARTIFACT` — `autorun.inf` or Startup-folder payloads present;
    classic persistence.
  - `HIDDEN_ROOT_EXECUTABLE` — dotfile/executable sitting at the volume
    root; droppers land here.

`verdict` is `triage-complete`, or `triage-complete-suspicious` when any
`suspicious`-severity indicator fired. The verdict informs the operator —
it never auto-arms anything. Destruction still requires the nuke phase's
interlocks (docs/NUKE-SAFETY.md).

## 4. Usage

```bash
# boot environment (air-gapped; report goes to the Phoenix USB, never the target)
tools/Analyze-DiskTriage.sh --save-state /mnt/usb/phoenix-state
# also scan unmounted partitions via read-only mounts:
tools/Analyze-DiskTriage.sh --save-state /mnt/usb/phoenix-state --mount-ro
```

Without `--mount-ro`, only partitions the boot environment already has
mounted are scanned; unmounted partitions still get a partition
inventory (no filesystem peek).

## 5. WinPE side is staging-only

`Analyze-DiskTriage.ps1` verifies the *flow* on a working machine
(enumeration shape, heuristics, report assembly, read-only self-check)
but scanning a live Windows system disk cannot see the unmounted state
the boot environment will see — the real run happens from the boot
environment. Same restriction as the nuke twin (NUKE-SAFETY.md §8).

## 6. Known residual risks

- **Heuristics are heuristic**: `RECENT_SYSTEM_MODIFY` fires on legitimate
  updaters; `OVERSIZED_TEMP` fires on game caches. They are triage leads
  for the operator, and the report says so on every finding.
- **Read-only mount is still a mount**: `mount -o ro` issues no writes to
  the disk (with `noload`, not even journal replay), but it does touch
  kernel state on the *boot* machine. Nothing on the target is modified.
- **Encrypted partitions are opaque**: BitLocker/LUKS volumes report as
  unknown-fstype partitions until unlocked by the operator. Analyze will
  not attempt decryption on its own.
