# phoenix-config.json — the OS-agnostic USB config schema

**Status:** spec + machine-readable schema + validator, 2026-09-09.

**The split (founder decision, stands):** the Config GUI runs on a *working*
machine and writes `phoenix-config.json` to the Ventoy exFAT partition root
(next to `autounattend.xml`). The boot side (Phoenix WinPE, SystemRescue,
Rescuezilla, ShredOS/nwipe) reads it **headless** — no GUI in the boot
environment, ever. See `docs/BOOT-ARCHITECTURE.md` §2 for the USB layout
(branch `jack/phoenix-boot-arch`).

## 1. Files

| File | Role |
|---|---|
| `config/usb-config.schema.json` | Machine-readable JSON Schema (draft 2020-12). Single source of truth for shapes, enums, patterns, defaults. |
| `tools/Validate-UsbConfig.py` | Dependency-free (python3 stdlib) validator. Enforces the schema *plus* the structural safety rules in §6 that JSON Schema can't express. |
| `tests/config/test-schema.sh` | Regression suite: 10 cases, all green. Run before every commit touching config. |

The GUI is the *writer*, the boot tools are the *readers*. Both sides must
validate: the GUI validates on write (fail the build, not the boot), and the
boot side validates on read and fails closed on any error.

## 2. Design principles

1. **OS-agnostic top level.** No Windows-only keys at the root. A `reinstall.platform`
   discriminator selects the OS; anything platform-specific nests deeper.
   Matches the existing GUI `PhoenixConfig` type contract in
   `gui/phoenix-tauri/src/lib/types.ts` (branch `jack/phoenix-gui`).
2. **Allowlist, not denylist.** The nuke target disk allowlist (`target_disks`)
   lists serials that *may* be wiped; everything else is structurally refused.
3. **Fail closed.** Missing or invalid config = do nothing. The boot side never
   guesses defaults for destructive behavior.
4. **Machine-checkable.** Everything in this doc is either in the schema file or
   enforced by the validator. Prose that isn't enforced is marked as such.

## 3. Fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | integer (const `1`) | yes | Bump on breaking change; readers reject unknown versions. |
| `boot_entries` | object | yes | Toggles: `analyze`, `backup`, `nuke`, `reinstall` (booleans). The GUI stages ISOs / Ventoy aliases only for enabled entries; the boot side ignores disabled ones. |
| `target_disks` | array of `{serial, model?, note?}` | yes (may be empty) | Serial allowlist for the Nuke phase. Serials copied verbatim from the enumeration table — never hand-typed from memory. Empty = no disk may be nuked. |
| `backup_target` | object | yes | Where the Backup phase writes the verified image. `kind`: `"direct-usb"` (air-gapped default, per the runbook) or `"castle-smb"` (PROVISIONAL — share path pending founder answer). `smb_path` required when kind is `castle-smb`. |
| `unattend` | object | yes | `answer_file`: root-relative USB path of the answer file consumed by Ventoy `auto_install` (default `/autounattend.xml`). Generated from this config by the GUI. |
| `safety` | object | yes | Nuke safety flags: `require_image_proof` (default true), `allow_skip_image_gate` (default false — the escape hatch is compiled *out* of the stick unless explicitly enabled), `abort_countdown_seconds` (default 5, 0 disables; VM tests only). |
| `reinstall.platform` | enum | no | `"windows"` (default) or `"linux"` (reserved future blade). |
| `generated_by` | string | no | Free-text provenance (tool + timestamp). Informational only, never acted on. |

Unknown properties are rejected (`additionalProperties: false`) — a typo like
`requier_image_proof` must fail loudly, not silently fall back to a default.

## 4. The Castle SMB question (open)

`backup_target.kind: "castle-smb"` is specified but **provisional**: the runbook
currently images to a direct-attached USB drive (air-gapped), and the Castle
share path / credentials model hasn't been decided. Until the founder answers,
`castle-smb` configs validate syntactically but the boot side should treat the
path as unconfirmed. **Open question for Brando:** what is the Castle SMB
share for Phoenix images (host/share), and how should the boot side
authenticate — or should images stay direct-USB-only until phase 2?

## 5. Integration points

- **GUI (writer):** `gui/phoenix-tauri` (branch `jack/phoenix-gui`) — the
  SetupWizard's final step writes `phoenix-config.json` and runs
  `Validate-UsbConfig.py` before copying it to the stick. TODO once the
  worker branches land on master: generate the Svelte form's field list /
  TS types from `usb-config.schema.json` so the form and schema can't drift.
- **USB stager (writer):** `tools/Build-PhoenixUsb.*` — should refuse to stage
  a stick whose `phoenix-config.json` fails validation.
- **Nuke (reader):** `tools/Invoke-Nuke.sh` — must enforce `target_disks`
  allowlist + `safety.require_image_proof` / `safety.allow_skip_image_gate`
  (see §6). The image-proof gate itself (`NUKE-SAFETY.md` interlock 11) stays
  the runtime enforcement; the config controls whether the stick permits it.
- **Reinstall (reader):** Ventoy `auto_install` → `unattend.answer_file`;
  the GUI generates `autounattend.xml` from this config.

## 6. Structural safety rules (enforced by the validator)

These are the rules JSON Schema cannot express — they are normative, and the
boot side must treat a violation as "refuse to boot the menu":

1. **`boot_entries.nuke: true` requires `safety.require_image_proof: true`.**
   Runbook invariant 1 ("verified image or no wipe") encoded in config, not
   just documentation.
2. **`boot_entries.nuke: true` requires a non-empty `target_disks`.**
   A stick that can nuke must name exactly which serials it may nuke.
3. **`boot_entries.backup: true` requires `backup_target`.**

## 7. Example

A minimal emergency-runbook config (nuke enabled, one allowlisted disk,
direct-USB backup) lives at `tests/config/fixtures/valid-full.json` and is
validated by the suite.
