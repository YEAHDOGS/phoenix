#!/usr/bin/env bash
#===============================================================================
# Reinstall-Windows.sh -- Phoenix REINSTALL phase: arm an unattended Windows
# install onto a provably nuked disk (Linux / boot-environment side).
# Twin: tools/Reinstall-Windows.ps1 (WinPE side, same gate contract).
#
# Flow (mirrors docs/EMERGENCY-RUNBOOK.md Phase 4, manual mode):
#   0. USB-config stick-policy gate: phoenix-config.json is FULLY validated
#      by tools/Read-UsbConfig.py (same single reader the nuke/backup flows
#      use); the stick's reinstall lane must be enabled, platform windows.
#   1. Enumerate disks (tools/Get-DiskInventory.sh) -> numbered table.
#   2. Pick a row: the reinstall target. It MUST be blank (zeroed leading
#      sectors, no mounts, readable serial) -- otherwise the disk still
#      holds data and installing here is refused structurally.
#   3. Artifacts: staged autounattend.xml + Windows ISO exist and readable.
#   4. Config: staged files agree with phoenix-config.json (reinstall entry
#      enabled, platform windows, answer-file name matches).
#   5. Chain of custody: state dir holds a verified backup-image-proof.json
#      AND a nuke-completed.json for this exact serial.
#   6. Type the exact "SERIAL MODEL" pair on a real terminal.
#   7. Print the exact next command (Ventoy auto_install entry / Setup
#      invocation). THIS SCRIPT NEVER LAUNCHES SETUP ITSELF -- the gates
#      arm the install, the operator fires it after a final look.
#
# USAGE:
#   Reinstall-Windows.sh --config JSON --unattend FILE --iso FILE [--state DIR] [--inventory JSON] <disk-id>
#   Reinstall-Windows.sh --help
#
#   --config JSON    phoenix-config.json from the USB root
#   --unattend FILE  staged answer file (root-relative path on the USB)
#   --iso FILE       staged Windows ISO
#   --state DIR      USB state dir for logs/proof (default: ./phoenix-state)
#   --inventory JSON reuse an enumeration instead of re-scanning
#
# TESTING: PHOENIX_MOCK_LSBLK / PHOENIX_MOCK_MOUNTS / PHOENIX_MOCK_HASH (see
# Get-DiskInventory.sh). Gates read JSON fixtures only -- no real disks, no
# real installs. Typed confirmation needs a real TTY (like the nuke flow).
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENUM="$HERE/Get-DiskInventory.sh"
NUKE_LIB="$HERE/lib/nuke-interlock.sh"
LIB="$HERE/lib/reinstall-gates.sh"
CONFIG=""; UNATTEND=""; ISO=""; STATE=""; INV_FILE=""; DISK_ID=""

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="${2:?--config needs a file}"; shift 2;;
        --unattend) UNATTEND="${2:?--unattend needs a file}"; shift 2;;
        --iso) ISO="${2:?--iso needs a file}"; shift 2;;
        --state) STATE="${2:?--state needs a directory}"; shift 2;;
        --inventory) INV_FILE="${2:?--inventory needs a file}"; shift 2;;
        --help|-h) usage;;
        --*) echo "[$PROG] unknown argument: $1" >&2; exit 3;;
        *) [[ -z "$DISK_ID" ]] || { echo "[$PROG] unexpected argument: $1" >&2; exit 3; }
           DISK_ID="$1"; shift;;
    esac
done

[[ -n "$CONFIG" ]]   || { echo "[$PROG] --config is required." >&2; exit 3; }
[[ -n "$UNATTEND" ]] || { echo "[$PROG] --unattend is required." >&2; exit 3; }
[[ -n "$ISO" ]]      || { echo "[$PROG] --iso is required." >&2; exit 3; }
[[ -n "$DISK_ID" ]]  || { echo "[$PROG] <disk-id> is required." >&2; exit 3; }
[[ "$DISK_ID" =~ ^[0-9]+$ ]] || { echo "[$PROG] <disk-id> must be a row number." >&2; exit 3; }
[[ -z "$STATE" ]] && STATE="./phoenix-state"
mkdir -p "$STATE"

# USB-config gate (stick policy, same model as Invoke-Nuke.sh): the config
# is FULLY validated by Read-UsbConfig.py (JSON Schema + CONFIG-SCHEMA.md
# section 6) and the reinstall policy is loaded into CFG_* variables. A
# stick that disables the reinstall boot entry cannot arm a reinstall.
# Fail closed on EVERY problem: missing reader, unreadable config, invalid
# config (exit 2), or reinstall disabled.
reinstall_load_usb_config() {
    local reader="$HERE/Read-UsbConfig.py"
    local cfg_out
    [[ -f "$reader" ]] || { echo "[$PROG] REFUSED: --config requires tools/Read-UsbConfig.py next to Reinstall-Windows.sh (stick image incomplete)." >&2; exit 2; }
    cfg_out="$("$reader" --shell "$CONFIG" 2>"$STATE/reinstall-config.err")" \
        || { echo "[$PROG] REFUSED: invalid phoenix-config.json:" >&2; cat "$STATE/reinstall-config.err" >&2; exit 2; }
    # shellcheck disable=SC1090
    eval "$cfg_out"   # sets CFG_REINSTALL_ENABLED, CFG_REINSTALL_PLATFORM, CFG_UNATTEND_FILE, ...
    [[ -n "${CFG_REINSTALL_ENABLED:-}" ]] || { echo "[$PROG] REFUSED: config reader returned no reinstall policy." >&2; exit 2; }
    [[ "${CFG_REINSTALL_ENABLED:-0}" == "1" ]] || { echo "[$PROG] REFUSED: stick policy disables the REINSTALL boot entry (boot_entries.reinstall=false)." >&2; exit 2; }
    [[ "${CFG_REINSTALL_PLATFORM:-windows}" == "windows" ]] || { echo "[$PROG] REFUSED: stick policy selects platform '${CFG_REINSTALL_PLATFORM:-?}' (only 'windows' is implemented; linux is a future blade)." >&2; exit 2; }
    echo "[$PROG] stick policy: reinstall enabled, platform ${CFG_REINSTALL_PLATFORM:-windows}, answer file ${CFG_UNATTEND_FILE:-/autounattend.xml}."
}
reinstall_load_usb_config

# shellcheck disable=SC1090
source "$NUKE_LIB"
# shellcheck disable=SC1090
source "$LIB"

if [[ -z "$INV_FILE" ]]; then
    INV_FILE="$STATE/disk-inventory.json"
    "$ENUM" --save-state "$STATE" > "$INV_FILE"
fi

SERIAL="$(reinstall_target_field "$INV_FILE" "$DISK_ID" serial)"
[[ -n "$SERIAL" ]] || { echo "[$PROG] no disk with id $DISK_ID." >&2; exit 1; }
MODEL="$(reinstall_target_field "$INV_FILE" "$DISK_ID" model)"

reinstall_require_target_blank    "$INV_FILE" "$DISK_ID" "$STATE/disk-fingerprints.json"
reinstall_require_artifacts       "$UNATTEND" "$ISO"
reinstall_require_config_match    "$CONFIG" "$UNATTEND" "$ISO"
reinstall_require_chain_of_custody "$STATE" "$SERIAL"
nuke_require_tty
nuke_confirm_target               "$INV_FILE" "$DISK_ID" "$STATE"

reinstall_log "$STATE" "ARMED reinstall id=$DISK_ID serial=$SERIAL model=\"$MODEL\""

cat <<NEXT

[$PROG] ALL GATES PASSED -- install is ARMED, not launched.
Target: [$DISK_ID] $MODEL (serial $SERIAL)

Next -- the operator fires Setup manually after a final look at the card:
  Ventoy menu  : boot [4] REINSTALL -- Windows 11 (unattended)
                 (auto_install entry consumes $(basename "$UNATTEND"))
  ISO          : $ISO
  Answer file  : $UNATTEND

This script intentionally stops here. Typed confirmation is on record in
$STATE/reinstall-gates.log.
NEXT
