# Phoenix BACKUP module — `tools/Invoke-Backup.sh` (+ `.ps1` twin)

The Backup phase of the emergency runbook (`docs/EMERGENCY-RUNBOOK.md`, Phase 2):
image the infected disk to a **direct-attached USB target**, air-gapped, before
anything destructive runs. Backup is non-destructive (it never writes to the
source disk), but it is **identity-critical**: the Nuke phase's image-proof gate
(`--image-proof`) binds a proof to the imaged disk's **serial**, so a misidentified
source silently breaks the whole chain. The module therefore carries the same
identity machinery as the Nuke module.

## Two paths

1. **Scripted path (this module, default):** `tools/Invoke-Backup.sh` on the
   Linux rescue side. Headless, log-driven, emits the image-proof manifest in
   exactly the format `Invoke-Nuke.sh --image-proof` demands. Compressor
   auto-detects `pigz` → `zstd` → `gzip` → raw (no compression).
2. **Rescuezilla path (documented here, manual):** boot `[2] BACKUP —
   Rescuezilla` from the Phoenix USB and do Backup → entire source disk →
   external USB drive with compression + post-backup integrity check. Minimum
   verification bar and the image-proof step are identical; record the proof
   with `tools/New-ImageProof.sh --verified` by hand. Use this path when the
   scripted one is unavailable or the disk is failing badly enough that a
   human should watch the sectors go by.

Run `Invoke-Backup.sh --tool rescuezilla` to print the manual path's checklist
instead of imaging.

## Safety model

1. **Config is mandatory for real work.** `--config <phoenix-config.json>` is
   required for anything beyond bare enumeration (plan, `--dry-run`,
   `--tool rescuezilla`, armed run), never auto-discovered.
   `boot_entries.backup` must be true. Unknown config fields fail closed
   (schema `additionalProperties: false`).
2. **Serial resolution, never letters.** Source and target are resolved by
   **serial** (row number or /dev node accepted as aliases of the enumerated
   table, same as the Nuke UX). Letters lie; serials identify.
3. **Boot-USB guard.** The booted Phoenix USB can be neither source nor target.
   Any disk with mounted partitions is refused as a source; the target mount
   must descend from the declared target disk.
4. **Air-gap gate.** Imaging refuses if any non-loopback network interface is
   up — unless `--allow-network` is passed AND the operator types
   `ALLOW NETWORK` on a real TTY (piped stdin can never allow it). Runbook
   invariant: the infected machine talks to nothing during imaging.
5. **`castle-smb` is refused on the scripted boot path.** The config schema
   carries `backup_target.kind: castle-smb` as PROVISIONAL, but the runbook
   (Step 2.1) forbids network during imaging. A network push from the infected
   machine would violate the air-gap gate. Quarantine and copy the image to
   Castle from a **clean machine** (runbook Step 2.7) instead.
6. **Dry-run default posture.** No flags enumerates disks and exits. `--dry-run`
   walks the entire flow — config load, serial resolution, network gate, target
   verification, free-space check, image plan — and writes nothing.
7. **Duplicated serials are identity failure.** Refused, exactly like the Nuke
   module: a proof bound to an ambiguous serial is a proof of nothing.

## Verification ladder (scripted path)

1. `dd` completes with a zero exit (partial reads are fatal, not retried —
   re-run explicitly if the disk is failing).
2. The stored image is re-hashed: the recomputed `sha256sum` must equal the
   hash recorded at write time.
3. **Mount-ability smoke check:** the first 512 bytes of the image (after
   decompression for compressed images) must carry a recognizable disk
   signature (MBR `0x55AA` or GPT `EFI PART`) or `file(1)` must report a
   filesystem/partition-table — proof the image is a disk image, not garbage.
4. `tools/New-ImageProof.sh --verified` is invoked with the **real** values
   (real sha256, real size, real `source_serial`); `--verified` is passed only
   because steps 1–3 passed. The `.proof` lands on the Phoenix USB next to the
   backup log, ready for `Invoke-Nuke.sh --image-proof`.

Free-space rule: the target filesystem must hold at least **half the source
disk's size** (compressed images usually land far below that, but the module
fails closed rather than discovering mid-image that they don't). A warning is
logged when available space is below the full source size.

## Test hook

`PHOENIX_BACKUP_TEST=1` + `--test-serial <serial>` lets the regression harness
image a **regular file** as a fake source disk (file-to-file, zero destructive
potential) and skips the mount-descent verification of the target mount. The
hook is refused in normal operation: the env var unset means `--source` must
resolve against the real enumerated disks, and `--test-serial` dies without
the env var set. See `tests/tools/test-backup-interlocks.sh`.

## Windows twin

`tools/Invoke-Backup.ps1` implements the same gates where Windows can: config
validation (via `python3 Read-UsbConfig.py`), serial resolution (`Get-Disk`),
air-gap check (`Get-NetAdapter`), and `--dry-run` planning. The actual image
write is refused on Windows — the scripted dd path exists only in the Linux
rescue boot environment, which has no PowerShell — with an explicit pointer to
the Ventoy `[2] BACKUP` entry. Backup imaging is never performed from a live
Windows session anyway (runbook Step 2.2: do not boot Windows).
