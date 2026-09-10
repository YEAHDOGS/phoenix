# REINSTALL Phase — unattended Windows install onto a proven-nuked disk

**Scope of this doc:** the Phoenix *Reinstall* phase tooling — boot-menu
item `[4] REINSTALL`, the last step of the emergency runbook ("Analyze"
→ "Backup" → "Nuke" → "Reinstall"). It installs Windows from the staged
ISO with the generated `autounattend.xml` **only onto a disk that
provably went through the Nuke phase**. Implements the runbook's Phase 4
(runbook branch `jack/phoenix-runbook`).

Reinstall is where the safety story closes the loop. Installing Windows
is not destructive to *data* the way Nuke is, but installing onto the
**wrong disk** (a disk that still holds the infected OS, or a data drive)
destroys the chain of custody the whole runbook depends on. These gates
make that structurally impossible, not merely unlikely.

## 1. Components

| File | Role |
|---|---|
| `tools/lib/reinstall-gates.sh` | Bash gate library, sourced by the flow. Blank-target gate, artifact gate, config-consistency gate, chain-of-custody gate, TTY + typed-confirmation (reuses `tools/lib/nuke-interlock.sh`). |
| `tools/Reinstall-Windows.sh` | Linux / boot-environment flow: USB-config stick-policy gate → enumerate → gates → hand off to Windows Setup (via Ventoy `auto_install`). Never launches Setup itself. |
| `tools/Reinstall-Windows.ps1` | WinPE / staging-side twin: same gate contract against `Get-Disk`/`Get-Partition` enumeration, same JSON shapes. Enforces the same stick-policy gates (reinstall enabled, platform windows) against the config; full JSON-schema validation stays in the Linux-side reader (no python3 in WinPE). |
| `tests/tools/test-reinstall.sh` | Regression suite (fully mocked — no real disks, no real install). |

## 2. The six gates (all fail closed)

0. **USB-config (stick-policy) gate** (`reinstall_load_usb_config`): the
   config is *fully* validated by `tools/Read-UsbConfig.py` (JSON Schema +
   `docs/CONFIG-SCHEMA.md` §6 — the same single reader Invoke-Nuke and
   Invoke-Backup use) and the stick's Reinstall lane must be enabled
   (`boot_entries.reinstall`, platform `windows`). A stick that disables
   the lane cannot arm a reinstall. Runs before every other gate.

1. **Blank-target gate** (`reinstall_require_target_blank`): the target
   disk must be provably blank — no GPT/MBR partition table, no
   recognizable filesystem on any partition slot, first 1 MiB all zeros.
   A disk that still has partitions or a filesystem **fails**: Reinstall
   refuses to pave over a disk Nuke never touched. This is the core
   anti-wrong-disk property of this phase: the only disks that pass are
   disks the Nuke flow blanked.
2. **Artifact gate** (`reinstall_require_artifacts`): the staged
   `autounattend.xml` and the Windows ISO (from `phoenix-config.json`
   `boot_entries` / the Ventoy staging dir) both exist and are readable.
   A missing answer file means Windows Setup would prompt mid-install —
   exactly the headless flow Reinstall must never produce. A missing ISO
   means there is nothing to install.
3. **Config-consistency gate** (`reinstall_require_config_match`): the
   answer file's `Image/InstallFrom` image name and the ISO filename
   recorded in `phoenix-config.json` agree with what is actually staged.
   A stale config (ISO renamed without rebuilding the USB) is a
   mismatched-install waiting to happen — fail closed.
4. **Chain-of-custody gate** (`reinstall_require_chain_of_custody`): the
   state dir (`--state`) must contain a completed Backup proof
   (`backup-image-proof.json`, `verified: true`) and a completed Nuke
   record for this disk's serial. Reinstall is Phase 4 of a four-phase
   runbook; running it without Phases 2–3 on record means the operator
   skipped the image-and-wipe. Refuse.
5. **Typed confirmation** (reuses `nuke_require_tty` +
   `nuke_confirm_target`): operator types the exact `SERIAL MODEL` pair
   on a real terminal. Even though the target is blank, the human
   confirms the physical disk (USB vs internal NVMe mixups kill).

## 3. What "blank" means, precisely

A disk passes `reinstall_require_target_blank` iff ALL of:

- it exposes no mounted partitions in the `phoenix-disk-inventory/1`
  enumeration (a wiped disk has nothing to mount),
- its `partition_hash` in `disk-fingerprints.json` (written by the same
  `Get-DiskInventory.sh --save-state` enumeration run, so the two records
  cannot disagree about the disk) equals the all-zeros constant
  `sha256:30e14955…fcb58` — the SHA-256 of 1 MiB of zero bytes,
- it has a readable serial (no serial = no target card to confirm against).

Zero-fill of the first megabyte is what the Nuke flow produces
(`Invoke-Nuke.sh` wipes partition metadata + leading sectors); a disk
with a live partition table can never satisfy this gate, even if its
partitions were somehow hidden from enumeration. Belt and suspenders.
The gate also refuses when the fingerprint file is missing or the serial
has no fingerprint record — no probe, no install.

## 4. Usage

```bash
# boot environment: the Ventoy menu already booted [4] REINSTALL, or run manually:
tools/Reinstall-Windows.sh --state /mnt/usb/phoenix-state --target 2
# --target is the disk id from the phoenix-disk-inventory/1 enumeration
```

The flow stops after the gates pass and prints the exact command the
operator (or Ventoy `auto_install`) runs next — it does **not** launch
Setup itself. Launching the installer from a scripted flow would skip
the human's final look at the target card; the gates arm the install,
the operator fires it.

## 5. WinPE side is staging-only

Same contract as the other phases: `Reinstall-Windows.ps1` runs only on
the staging machine (building/validating the USB) or inside WinPE for
validation — never as the installer launcher on the target machine. The
boot-side `.sh` is the authority.

## 6. Relationship to the answer-file generator

`tools/New-UnattendXml.ps1` (unattend-gen branch) produces the answer
file the artifact gate checks. The gate reads the staged file, not the
generator — a hand-edited or corrupted `autounattend.xml` that still
parses is fine; a missing one is not. Content validation of the answer
file (schema, specialize order) stays with `tools/Test-UnattendXml.ps1`;
this phase only requires presence + readability + config agreement.
