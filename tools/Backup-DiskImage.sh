#!/usr/bin/env bash
#===============================================================================
# Backup-DiskImage.sh -- Phoenix BACKUP phase: full-disk image of the source
# drive with structural safety gates (Linux / boot-environment side).
# Twin: tools/Backup-DiskImage.ps1 (WinPE side).
#
# Flow (mirrors docs/EMERGENCY-RUNBOOK.md Phase 2, manual mode):
#   1. Enumerate disks (tools/Get-DiskInventory.sh) -> numbered table.
#   2. Pick a row: the source disk. Serial-less and mounted disks are refused.
#   3. Destination: direct-attached dir with >= full source size free, and NOT
#      on the source disk itself.
#   4. Type the exact "SERIAL MODEL" pair on a real terminal.
#   5. Image via dd, hash during write, verify the hash, record the manifest
#      and backup-image-proof.json (the nuke phase's image-proof gate
#      consumes this proof -- verified image or no wipe).
#
# USAGE:
#   Backup-DiskImage.sh --dest DIR [--state DIR] [--inventory JSON] <disk-id>
#   Backup-DiskImage.sh --help
#
#   --dest DIR       where the image + manifest + proof are written
#                    (direct-attached USB in the runbook's air-gapped mode)
#   --state DIR      USB state dir for logs/proof (default: <dest>/phoenix-state)
#   --inventory JSON reuse an enumeration instead of re-scanning
#
# TESTING: PHOENIX_MOCK_LSBLK / PHOENIX_MOCK_MOUNTS / PHOENIX_MOCK_HASH (see
# Get-DiskInventory.sh), PHOENIX_MOCK_DD=1, PHOENIX_MOCK_DF_AVAIL,
# PHOENIX_MOCK_DF_DEVICE (see tools/lib/backup-gates.sh). No real disks touched.
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENUM="$HERE/Get-DiskInventory.sh"
LIB="$HERE/lib/backup-gates.sh"
DEST=""; STATE=""; INV_FILE=""; DISK_ID=""

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST="${2:?--dest needs a directory}"; shift 2;;
        --state) STATE="${2:?--state needs a directory}"; shift 2;;
        --inventory) INV_FILE="${2:?--inventory needs a file}"; shift 2;;
        --help|-h) usage;;
        --*) echo "[$PROG] unknown argument: $1" >&2; exit 3;;
        *) [[ -z "$DISK_ID" ]] || { echo "[$PROG] unexpected argument: $1" >&2; exit 3; }
           DISK_ID="$1"; shift;;
    esac
done

[[ -n "$DEST" ]]   || { echo "[$PROG] --dest is required." >&2; exit 3; }
[[ -n "$DISK_ID" ]] || { echo "[$PROG] <disk-id> is required." >&2; exit 3; }
[[ "$DISK_ID" =~ ^[0-9]+$ ]] || { echo "[$PROG] <disk-id> must be a row number." >&2; exit 3; }
[[ -z "$STATE" ]] && STATE="$DEST/phoenix-state"
mkdir -p "$STATE"

# shellcheck disable=SC1090
source "$LIB"

# --- 1. enumerate ---------------------------------------------------------------
if [[ -n "$INV_FILE" ]]; then
    INV="$INV_FILE"
else
    INV="$STATE/disk-inventory.json"
    "$ENUM" > "$INV"
fi
echo "[$PROG] disk inventory:"
python3 - "$INV" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["disks"]:
    flag = " [MOUNTED - refused]" if d["mounted"] else ""
    serial = d["serial"] or "(no serial - refused)"
    print(f'  [{d["id"]}] {d["model"]}  SN {serial}  {d["size_human"]}{flag}')
EOF

# --- 2. source gate -------------------------------------------------------------
backup_require_source "$INV" "$DISK_ID"

# --- 3. destination gate --------------------------------------------------------
backup_require_destination "$DEST" "$BACKUP_SIZE_BYTES" "$BACKUP_DEV"

# --- 4. typed confirmation (TTY only, serial+model exact) -----------------------
nuke_confirm_target "$INV" "$DISK_ID" "$STATE"

# --- 5. image ------------------------------------------------------------------
LABEL="phoenix-image-$(date -u +%Y-%m-%d)-${BACKUP_SERIAL}"
backup_image_disk "$BACKUP_DEV" "$DEST" "$LABEL" "$STATE"

# --- 6. proof -------------------------------------------------------------------
backup_require_image_proof "$STATE" "$BACKUP_SERIAL"

echo "[$PROG] BACKUP COMPLETE: $BACKUP_IMG_PATH"
echo "[$PROG] sha256: $BACKUP_IMG_SHA256"
echo "[$PROG] proof: $STATE/backup-image-proof.json  (the nuke phase must consume this before any wipe)"
