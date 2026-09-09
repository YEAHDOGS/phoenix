#!/usr/bin/env bash
#===============================================================================
# Reinstall-Windows.sh -- Phoenix REINSTALL phase: arm an unattended Windows
# install onto a provably nuked disk (Linux / boot-environment side).
# Twin: tools/Reinstall-Windows.ps1 (WinPE side, same gate contract).
#
# Flow (mirrors docs/EMERGENCY-RUNBOOK.md Phase 4, manual mode):
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
