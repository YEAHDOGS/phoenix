# NUKE Interlocks — candidate enumeration + arming confirmation

The design contract behind `tools/lib/phoenix-disk-inventory.sh` (bash) and
its WinPE twin `tools/Get-PhoenixDiskInventory.ps1`. Read this before wiring
any NUKE-path tool to a disk.

## Principle

Wiping the wrong disk must be **structurally hard**, not merely discouraged.
The interlocks below are gates in code, not advice in a checklist: doing
nothing is the default, and arming a wipe takes deliberate transcription on
a real console.

## 1. Candidate enumeration (exclusion, not warning)

`pdi_enumerate` builds the candidate list and **excludes** three classes of
disk entirely — they never appear as candidates, so they can never be armed:

| Excluded | How it's detected |
|----------|-------------------|
| The booted Phoenix USB | kernel cmdline `root=`/`BOOT_IMAGE=` device, or any disk backing `/`, `/boot`, `/boot/efi` (`/proc/mounts`) |
| Mounted disks | any descendant partition with a mountpoint (`lsblk` per device) |
| Protected disks | serial or `/dev` path listed in `phoenix-config.json` → `"nuke": { "protectedDisks": [...] }` |

A summary line names every hidden disk with its reason (`BOOT-USB`,
`MOUNTED`, `PROTECTED(config)`) so the operator can see the exclusion
logic fired. loop/ram/dm/md devices are never enumerated at all.

**Protected disks** are declared at USB-build time with
`New-PhoenixConfig.sh --protect-disk <serial>` (repeatable; twin:
`-ProtectDisk`). Use them for the backup vault, the Castle drive, anything
irreplaceable — a protected disk cannot be armed, even with override
flags. The key lives in schema v1, which the boot side parses headless
without jq (flat-scalar JSON only — keep it that way).

## 2. Per-disk ARM CODE

Every candidate row carries an **ARM CODE**: the first 6 uppercase hex
chars of `sha256("phoenix-nuke-arm|<serial>|<model>|<size-bytes>")`.
It is deterministic (tests and the `.ps1` twin recompute it byte for
byte) and it is *not a secret* — it is a transcription challenge. Its job
is forcing the operator to read the enumeration row deliberately: you
cannot arm a disk you did not look at.

## 3. Typed confirmation gate

`pdi_confirm_armed <serial> <arm-code>` arms **one** disk when the
operator types its ARM CODE **or** its exact serial:

- **Real terminal only** — piped or redirected stdin is refused
  structurally (`echo $code | ...` can never arm). PowerShell twin uses
  `[Console]::IsInputRedirected`.
- **Exact match, case-sensitive** — no trimming, no `Y`/`N`, no default-yes,
  no single keystroke. Trailing spaces and lowercase both refuse.
- **No-serial disks can never be armed** — a serial of `(unknown)` or empty
  is refused before any prompt, so an unidentifiable disk is un-wipeable.

## 4. What this library does NOT do

It contains no destructive primitive — only reads (`lsblk`, `/proc/*`,
the config). It does not select a target, does not execute a wipe method,
and does not replace the image-proof gate (`Invoke-Nuke.sh`: no wipe
without a verified backup image bound to the target's serial). NUKE-path
tools (boot menu, `phoenix-nuke.sh`, `Invoke-PhoenixNuke.ps1`) call
`pdi_enumerate` → show the table → `pdi_confirm_armed` → hand the armed
device to the wipe engine. The existing tools predate this library and
embed their own enumeration; migrating them onto it is the consolidation
target (their interlocks stay in force meanwhile).

## 5. Testing

`tests/tools/test-disk-inventory.sh` — 49 cases, all with mocked data
sources (`PHOENIX_PDI_*` hooks), runnable on any machine: the boot USB,
config-protected (by serial and by `/dev` path), mounted, and loop
exclusions; hidden-summary reasons; `NO-SERIAL` flagging; hostile
firmware MODEL strings treated as data (eval-free `-P` parser); arm-code
determinism/format/uniqueness with an independent python3 cross-check of
the derivation formula; piped-input refusal and a real-pty accept/refuse
matrix for the confirmation gate; dry-run output. The suite fails if any
destructive-primitive token ever appears in the library. Destructive
paths themselves stay VM-only (see `NUKE-TEST-PLAN.md`).
