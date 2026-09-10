# RESTORE-MODULE.md — Phoenix selective restore (data phase)

Applies a backup manifest onto a **new machine**. Twin engines, same behavior:

- `scripts/backup/restore-selective.ps1` — Windows side (PowerShell)
- `scripts/backup/restore-selective.sh` — Linux rescue side (bash)

```
# see what would happen (default; read-only, verifies backup hashes too)
restore-selective.sh --manifest-dir /mnt/castle/brando-laptop \
                     --target-root /mnt/newdisk/Users/Brando --plan

# actually restore one app's files
restore-selective.sh --manifest-dir /mnt/castle/brando-laptop \
                     --target-root /mnt/newdisk/Users/Brando \
                     --app ableton --apply
# -> prints full plan, then you type RESTORE to proceed
```

## The flow

1. **Read manifest** — `manifest.json` (file list + SHA-256) and
   `manifest-meta.json` (source fingerprint: host, source home, filesystem
   id/UUID). A missing meta degrades loudly but doesn't block.
2. **Map to target** — each `<app>/<path>` entry is resolved against the
   target root. Entries that can't be mapped safely are SKIPPED, never guessed.
3. **Profile rule check** — every entry is classified through its app's
   `profiles/*.json`: `data`/`config` restore, `cache`/`executable` (and
   anything not in the profile) are **never** restored, even if smuggled into
   the manifest. `config` files ending in `.json` are revalidated before being
   written; invalid ones are quarantined.
4. **Integrity gate** — SHA-256 of every restorable backup file is checked
   against the manifest in plan mode too. Any mismatch refuses the whole run.
5. **Interlocks, then typed confirmation** — see below.
6. **Apply** — re-verify hash right before each copy, copy, verify hash of the
   written file. Any mismatch aborts with a failure list. Final report shows
   planned vs actually restored counts.

## Stick-policy + chain-of-custody gates (opt-in)

The restore engine predates the config-schema world; two opt-in flags wire
it into the unified line without changing default behavior:

- `--config phoenix-config.json` — the config is fully validated by
  `tools/Read-UsbConfig.py` (JSON Schema + `docs/CONFIG-SCHEMA.md` §6) and
  the stick's Backup lane must be enabled (`boot_entries.backup`). A restore
  from data that did not come through a Phoenix backup is refused.
- `--chain <state-dir>` — the state dir from the same USB must hold a
  **verified** `backup-image-proof.json` (schema `phoenix-image-proof/1`)
  **and** `nuke-completed.json` (schema `phoenix-nuke-completion/1`): restore
  happens only after the full-disk backup + wipe were recorded. Enforcement
  is *ordering*, not serial binding — selective manifests are filesystem-level
  (`source_fs_id`/`source_uuid`), so interlocks 2-4 remain the primary
  defense; `--chain` adds the phase-ordering proof.

In the boot menu flow, Restore runs **after** Reinstall (Phase 4 → data
phase): the new machine is built, then the operator restores app data onto
it. It is not a boot-menu entry itself.

## Safety interlocks

Restoring onto the wrong disk must be structurally hard:

1. `--target-root` / `-TargetRoot` is **required** — no default target exists.
2. Target == recorded `source_home` (canonical path compare) → hard refuse.
3. Target filesystem id / volume serial / UUID matches the source fingerprint
   in the manifest → hard refuse. Override only with `--allow-same-disk` /
   `-AllowSameDisk` (for local testing or a second profile on one machine) —
   typed confirmation is still required.
4. Target inside the backup directory → hard refuse (can't restore a backup
   onto itself).
5. `--apply` prints the full plan, then requires typing `RESTORE` exactly.
   `--confirm-word RESTORE` bypasses the prompt for the Svelte/Tauri GUI and
   says so loudly.

## Per-app restore rules

The restore engine doesn't invent policy — it enforces the profile. For each
manifest entry it finds the app's profile (`profiles/<app>.json`,
`phoenix-profile/v1`) and classifies the *target* path against the profile's
`windows`/`linux` locations:

| profile class | restore behavior |
|---|---|
| `data` | restored, hash-verified before and after copy |
| `config` | `.json` files revalidated (must parse); anything else trusted per the profile's `notes`; invalid JSON quarantined, never written |
| `cache`, `executable`, unknown, no profile | **SKIP** — printed as kill-list, never restored |

So `--app ableton` restores only entries tagged `ableton` in the manifest,
and only the ones Ableton's profile classifies as data or valid config.
Adding a new app = adding `profiles/<app>.json`; the restore engine picks it
up with zero code changes.

## Manifest formats

`manifest.json`: `[{app, file, sha256}]` — `file` is `<app>/` + the path as the
backup engine stored it (home-relative from the bash engine, drive-stripped
from the PowerShell engine; restore handles both).

`manifest-meta.json` (`phoenix-backup-meta/v1`): `created`, `tool`,
`source_host`, `source_home`, `source_fs_id` (Linux `stat -c %d` / Windows
volume serial), `source_uuid` (filesystem UUID when available), `apps`.
