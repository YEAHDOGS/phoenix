# NUKE Interlock Spec — Phoenix nuclear disk sanitization

**Scope of this doc:** the *pre-arming interlocks* that make wiping the wrong
disk structurally hard, built on the `phoenix-config.json` contract
(`docs/CONFIG-SCHEMA.md`). The runtime wipe engine itself
(`tools/Invoke-Nuke.sh`, boot-environment nwipe/hdparm/nvme primitives) lives
on the sibling branch `jack/phoenix-nuke` and is out of scope here; this
branch provides the enumeration, confirmation, and analyze-first gates it
(and any future engine) must call before arming.

**Design goal:** an operator acting in good faith, following the boot menu,
must be unable to arm a wipe of the wrong disk without deliberately defeating
multiple independent checks. "Fat-finger Y" is not a check. Y/N prompts are
not used anywhere in this flow.

## 1. Components

| File | Role |
|---|---|
| `tools/Get-DiskInventory.sh` | Linux-side enumeration. Prints the inventory JSON (see §2) to stdout; `--save-state <dir>` records the Analyze fingerprint (§4). |
| `tools/Get-DiskInventory.ps1` | WinPE/Windows-side twin of the same contract (`Get-Disk` via CIM). Same flags. |
| `tools/lib/nuke-interlock.sh` | Bash gate library: `nuke_require_tty`, `nuke_confirm_target` (typed confirmation, §3), `nuke_require_fingerprint` (§4), `nuke_require_allowlist` (§5). Sourced by any boot-side script that arms destruction. |
| `tools/Confirm-NukeTarget.ps1` | PowerShell twin of the confirmation + fingerprint + allowlist gates (pre-boot staging verification on a working machine). |
| `tests/tools/test-nuke-interlock.sh` | Regression suite with mocked inventories (no real disks touched). |

Both OS sides share one JSON contract — the enumeration module is the single
source of truth for "which disk is which," and the confirmation gate always
works from its output, never from operator memory or hand-typed serials.

## 2. Inventory contract (both sides)

`Get-DiskInventory.*` emits a JSON array, one object per physical disk:

```json
[
  {
    "id": 1,
    "dev": "/dev/sda",
    "model": "Samsung SSD 870 EVO 1TB",
    "serial": "S5YBNJ0R123456A",
    "size_bytes": 1000204886016,
    "size_human": "931.5 GiB",
    "transport": "SATA",
    "removable": false,
    "mounted": false,
    "media": "ssd"
  }
]
```

Rules:
- `serial` is the manufacturer's serial, verbatim (no trimming beyond
  whitespace/CR normalization). A disk with no readable serial is listed with
  `serial: null` and is **never a valid nuke target** (refused by the gate).
- `size_human` is exactly what the operator sees on the target card; the
  confirmation gate matches against it, so both sides must render it
  identically (one decimal, GiB — see `format_gib` in the implementations).
- Disks are ordered by transport bus, then size — deterministic, so row
  numbers are stable within one boot session.
- The boot USB and any disk with mounted partitions are listed with
  `"mounted": true` / flagged and are refused structurally (§6). Listing them
  (greyed out) is intentional: hiding them invites "where did my disk go?"
  workarounds; showing them as refused does not.

## 3. Typed-confirmation gate (interlock: serial + model)

Arming requires the operator to **type two exact tokens** from the printed
target card:

```
TARGET: [2] Samsung SSD 870 EVO 1TB  SN S5YBNJ0R123456A  931.5 GiB
Type the serial and model EXACTLY as shown to arm the wipe:
> S5YBNJ0R123456A Samsung SSD 870 EVO 1TB
```

or with the `NUKE` prefix (keeps `echo`-style muscle memory from arming
nothing — the prefix alone is not enough):

```
> NUKE S5YBNJ0R123456A Samsung SSD 870 EVO 1TB
```

Structural properties:
- **Two factors**: a slip that produces the wrong serial must *also* produce
  the wrong model to arm the wrong disk. Serial-only, model-only, Y/N,
  `yes`, and empty input are all refused.
- **Exact match**: case-sensitive, full string. Leading/trailing whitespace is
  trimmed; internal spacing must match the card exactly. (Serials are compared
  after CR-stripping — pty line discipline appends CR on Enter.)
- **TTY-only**: stdin must be a real terminal. Piped or redirected stdin
  (`echo "$serial $model" | Confirm-NukeTarget ...`) is refused with an
  explicit error. Scripting the confirmation is structurally impossible —
  this is the interlock that defeats copy-paste accidents from the wrong
  window and every "just pipe it in" shortcut.
- The accepted confirmation is logged (UTC timestamp, serial, model) to the
  USB state dir before any destructive call.

## 4. Analyze-first / fingerprint gate (interlock: no analyze, no nuke)

The boot menu's **Analyze** entry must run before Nuke unlocks. Concretely:

- Analyze runs `Get-DiskInventory.sh --save-state <usb>/phoenix-state/`,
  writing `disk-fingerprints.json`:

```json
{
  "schema_version": 1,
  "recorded_at": "2026-09-09T12:00:00Z",
  "recorded_by": "analyze",
  "disks": [
    {"serial": "S5YBNJ0R123456A", "model": "Samsung SSD 870 EVO 1TB",
     "size_bytes": 1000204886016, "transport": "SATA",
     "partition_hash": "sha256:…"}
  ]
}
```

- `partition_hash` is the SHA-256 of the first 1 MiB of the disk (Linux side;
  captures partition table + bootloader). A disk swapped *after* Analyze
  (same slot, different drive) fails the hash check at arm time. On the
  WinPE side the field is `null` — staging verification only.
- Before arming, `nuke_require_fingerprint` demands:
  1. the fingerprint file exists in the state dir;
  2. it was recorded by `analyze` (not hand-written — `recorded_by` check);
  3. it is not older than 24 hours (stale fingerprints fail closed);
  4. the target serial is present in it, with matching model, size, and
     (Linux side) partition hash.

  Any failure aborts with "run Analyze first," never with a bypass prompt.

## 5. Config allowlist gate (interlock: only pre-approved disks)

`phoenix-config.json`'s `target_disks` is an **allowlist of serials that may
be wiped** (see `docs/CONFIG-SCHEMA.md` §3). Before arming:

- `nuke_require_allowlist <serial> <config>` parses the config (stdlib
  python3 on the Linux side — the boot image ships it; PowerShell's
  `ConvertFrom-Json` on the WinPE side) and requires the target serial to
  appear verbatim in `target_disks`.
- The GUI copies serials into the config **from the enumeration table** —
  never hand-typed from memory (the config doc already mandates this).
- Empty `target_disks` = no disk may be nuked. The gate fails closed on a
  missing or unparseable config.

## 6. Boot-USB / mounted-disk guard

Inherited by every consumer of this library: the disk the boot environment
itself runs from, and any disk with mounted partitions, are refused
structurally — the gate exits, it does not warn-and-continue. Detection:
Linux side via `/proc/mounts` + `/proc/cmdline` root device; WinPE side via
the USB volume's disk number. (The sibling `Invoke-Nuke.sh` implements this
for the Linux runtime; this library documents the contract so any engine
built on it inherits the guard.)

## 7. The five deliberate steps (operator view)

1. Boot the Phoenix USB, choose **Analyze** — fingerprints are recorded.
2. Choose **Nuke** — the enumeration table prints; nothing is armed (dry run).
3. Pick a row — the target card prints with its serial and model.
4. **Type the serial and model exactly**, on a real terminal.
5. Final abort window (5 s countdown), then the engine runs.

Skipping any step is not possible: step 1 is enforced by the fingerprint
gate, step 4 by the TTY + two-factor gate, step 3 by the config allowlist.

## 8. Known residual risks

- **Firmware lies**: a counterfeit controller can report success without
  erasing. For adversarial threat models, Purge is followed by Destroy
  (physical). No software interlock fixes dishonest hardware.
- **Same serial+model, different disk**: the partition-hash check (§4)
  defeats a swap between Analyze and Nuke, but two identical drives swapped
  *before* Analyze are indistinguishable — the fingerprint records what's
  there, and the operator must still read the card.
- **The 24-hour window**: a fingerprint is fresh for 24 h. A disk swapped
  within the window after Analyze still passes the hash check only if the
  first 1 MiB is identical — practically, a different OS install on the
  same hardware.
- **WinPE side is staging-only**: `Confirm-NukeTarget.ps1` verifies the
  *flow* on a working machine (gate logic, config parsing) but never arms
  destruction — destruction cannot be armed from a live Windows session,
  and the interlocks must live where the destruction happens.
