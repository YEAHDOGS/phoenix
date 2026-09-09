# BACKUP Phase — full-disk imaging with structural gates

**Scope of this doc:** the Phoenix *Backup* phase tooling — imaging the
(possibly infected) source drive **before** any wipe, with the same
interlock philosophy as the nuke phase (docs/NUKE-SAFETY.md). Implements
the manual-mode steps of `docs/EMERGENCY-RUNBOOK.md` Phase 2 (runbook
branch `jack/phoenix-runbook`): air-gapped imaging to a direct-attached
USB drive, verified image, quarantined copy.

## 1. Components

| File | Role |
|---|---|
| `tools/lib/backup-gates.sh` | Bash gate library, sourced by the flow. Sources `tools/lib/nuke-interlock.sh` and reuses its TTY + typed-confirmation gates. Adds: `backup_require_source`, `backup_require_destination`, `backup_image_disk`, `backup_require_image_proof`. |
| `tools/Backup-DiskImage.sh` | Linux / boot-environment imaging flow: enumerate → select → gates → dd → hash → proof. |
| `tools/Backup-DiskImage.ps1` | WinPE / staging-side twin: same gates, same proof artifacts, raw `\\.\PhysicalDriveN` read + incremental SHA-256. |
| `tests/tools/test-backup.sh` | Regression suite (30 cases, fully mocked — no real disks). |

## 2. The four gates

1. **Source gate** (`backup_require_source`): the disk comes from the
   enumeration table, has a readable manufacturer serial, and has no
   mounted partitions. Serial-less and mounted disks are refused
   structurally — without a serial there is no target card to confirm
   against and no proof to bind the image to.
2. **Destination gate** (`backup_require_destination`): the target dir must
   exist, be a directory, have the **full source size** free (raw image —
   no compression assumed), and must **not live on the source disk itself**
   (partition suffixes stripped before comparing: `sdb1`→`sdb`,
   `nvme0n1p2`→`nvme0n1`). Writing the image onto the disk being imaged is
   the backup-phase equivalent of nuking the wrong disk.
3. **Typed confirmation** (reused `nuke_confirm_target`): the operator types
   the exact `SERIAL MODEL` pair (or `IMAGE SERIAL MODEL`) on a real
   terminal. Piped/redirected stdin is refused — scripting the confirmation
   is structurally impossible.
4. **Image proof** (`backup_require_image_proof`): every image is hashed
   during the write and re-verified after it. The flow records
   `<label>.img`, `<label>.img.sha256`, `<label>-manifest.json`, and
   `backup-image-proof.json` (schema `phoenix-image-proof/1`) binding
   serial + model + size + sha256. The nuke phase's image-proof gate
   consumes this proof — **verified image or no wipe**. The gate refuses:
   missing proof, `verified != true`, serial mismatch, missing image,
   missing sidecar, sidecar/proof hash mismatch.

The flow also refuses to overwrite an existing image file, and logs every
start/finish/confirmation to the state dir (`backup-gates.log`).

## 3. Usage

```bash
# boot environment (air-gapped, direct-attached USB as destination)
tools/Backup-DiskImage.sh --dest /mnt/usb-images --state /mnt/usb-images/phoenix-state 2
```

The destination in the runbook's air-gapped mode is always a
**direct-attached** drive — never a network share from the infected
machine. (`phoenix-config.json`'s `backup_target.kind: "castle-smb"` is
provisional pending the founder's Castle share answer; see
docs/CONFIG-SCHEMA.md §4. The image is copied to Castle from a **clean**
machine afterwards.)

## 4. WinPE side is staging-only

`Backup-DiskImage.ps1` verifies the *flow* on a working machine (gates,
destination mapping, proof artifacts) but imaging a live Windows system
disk cannot produce a clean image — the real run happens from the boot
environment where nothing is mounted. Same restriction as the nuke twin
(NUKE-SAFETY.md §8).

## 5. Known residual risks

- **dd with `conv=noerror,sync`**: unreadable sectors are zero-filled, not
  fatal — the image completes but the manifest does not record *which*
  sectors were lost. A failing disk's image should be noted as degraded.
- **Torn image if the source changes mid-read**: the boot environment has
  nothing mounted, so this is a non-issue in practice; the hash binds the
  bytes that were actually written.
- **Infected image is evidence, not a restore source**: it stays
  quarantined (`QUARANTINE-INFECTED-<date>`) and is never mounted on a
  production machine (runbook invariant 2).
