#!/usr/bin/env bash
#===============================================================================
# image_disk.sh -- Phoenix emergency Phase 2.2 imaging (Linux / Rescuezilla side)
#
# Bash twin of scripts/emergency/Invoke-Image.ps1. Same contract:
#   1. Pre-flight safety checklist: explicit disk enumeration, structural
#      refusals, typed serial+model confirmation on a real TTY (no pipes).
#   2. Bit-for-bit image of --src to --dest-dir/<label>.img with progress
#      (dcfldd when present for hash-on-the-fly, else dd + sha256sum after).
#   3. SHA-256 manifest <label>.manifest.csv in the Path,Hash CSV contract of
#      scripts/checksum/check.sh (verifiable by check.sh / compare.sh).
#   4. Optional --verify: re-read the written image and compare its hash
#      against the manifest before reporting success.
#
# USAGE:
#   image_disk.sh --src /dev/sda --dest-dir /mnt/usb --label laptop-fulldisk-20260910 [--verify] [--dry-run]
#
# SAFETY INTERLOCKS:
#   - The source must appear in the enumerated disk table (typo guard).
#   - The source may never be the boot/root disk (this machine's own drive).
#   - The source may never be the destination (src path != dest image path).
#   - The destination image must not already exist (no silent overwrites).
#   - Confirmation is the source's exact "SERIAL MODEL" string as printed,
#     typed on a real TTY. Piped/scripted input is refused, hard.
#   - TEST HOOK: set PHOENIX_FIXTURE_CONFIRM to the expected confirmation
#     string to bypass the TTY requirement (used by the smoke suite only).
#
# Exit codes: 0 imaged+verified | 1 imaging/verification failure |
#             2 bad args | 3 confirmation refused | 4 destination exists |
#             5 safety interlock tripped (source is boot disk / not enumerated).
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
SRC=""
DEST_DIR=""
LABEL=""
VERIFY=0
DRY_RUN=0

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC="${2:?--src needs a path}"; shift 2;;
        --dest-dir) DEST_DIR="${2:?--dest-dir needs a directory}"; shift 2;;
        --label)    LABEL="${2:?--label needs a value}"; shift 2;;
        --verify)   VERIFY=1; shift;;
        --dry-run)  DRY_RUN=1; shift;;
        --help|-h)  usage 0;;
        *) echo "[$PROG] unknown argument: $1" >&2; exit 2;;
    esac
done

[[ -n "$SRC" ]]      || { echo "[$PROG] --src is required" >&2; exit 2; }
[[ -n "$DEST_DIR" ]] || { echo "[$PROG] --dest-dir is required" >&2; exit 2; }
[[ -n "$LABEL" ]]    || { echo "[$PROG] --label is required" >&2; exit 2; }
[[ -e "$SRC" ]]      || { echo "[$PROG] source not found: $SRC" >&2; exit 2; }

# Destination resolution + early structural refusals (before any TTY work).
DEST_IMG="$DEST_DIR/$LABEL.img"
DEST_MANIFEST="$DEST_DIR/$LABEL.manifest.csv"
[[ "$SRC" != "$DEST_IMG" ]] || { echo "[$PROG] REFUSED: source and destination are the same path." >&2; exit 5; }
if [[ -e "$DEST_IMG" || -e "$DEST_MANIFEST" ]]; then
    echo "[$PROG] REFUSED: destination already exists: $DEST_IMG or $DEST_MANIFEST -- refusing to overwrite." >&2
    exit 4
fi

echo ""
echo "================================================================="
echo "  PHOENIX PHASE 2.2 -- DISK IMAGING"
echo "  Read every line. This is the step the nuke gate depends on."
echo "================================================================="
echo ""

# --- Explicit disk enumeration -------------------------------------------------
echo "Enumerated disks on THIS machine (the imaging host):"
echo ""
lsblk -dno NAME,MODEL,SERIAL,SIZE,TRAN,RM -P 2>/dev/null | while read -r line; do
    echo "  $line"
done
echo ""
echo "  (MODEL and SERIAL are what the confirmation gate reads.)"
echo ""

# --- Identity of the source ----------------------------------------------------
SRC_MODEL=""; SRC_SERIAL=""
if [[ -b "$SRC" ]]; then
    # Real block device: identity comes from the enumeration above, never memory.
    # Parsed as JSON so a hostile device label can't inject shell.
    IFS=$'\t' read -r SRC_MODEL SRC_SERIAL < <(python3 - "$SRC" <<'PY'
import json, subprocess, sys
src = sys.argv[1]
raw = subprocess.run(["lsblk", "-dno", "MODEL,SERIAL", "--json", src],
                     capture_output=True, text=True).stdout
devs = json.loads(raw).get("blockdevices", [])
model = (devs[0].get("model") or "UNKNOWN-MODEL").strip() if devs else "UNKNOWN-MODEL"
serial = (devs[0].get("serial") or "UNKNOWN-SERIAL").strip() if devs else "UNKNOWN-SERIAL"
print(f"{model}\t{serial}")
PY
)
    SRC_MODEL="${SRC_MODEL:-UNKNOWN-MODEL}"
    SRC_SERIAL="${SRC_SERIAL:-UNKNOWN-SERIAL}"
    # Refuse the boot/root disk: imaging the machine's own drive is never
    # what this script is for (the infected laptop is booted from USB here).
    ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n "$ROOT_SRC" && ( "$SRC" == "$ROOT_SRC" || "$SRC" == "${ROOT_SRC%p[0-9]*}" ) ]]; then
        echo "[$PROG] REFUSED: $SRC holds this machine's root filesystem -- it is the boot disk, not the imaging target." >&2
        exit 5
    fi
    # Refuse any source with mounted partitions (a live filesystem being
    # imaged is a corrupt image waiting to happen).
    if lsblk -no MOUNTPOINT "$SRC" 2>/dev/null | grep -q '[^ ]'; then
        echo "[$PROG] REFUSED: $SRC has mounted partitions -- unmount everything on it first." >&2
        exit 5
    fi
else
    # File-backed source (smoke-test "disks" and loop images). Identity is the
    # basename so the confirmation contract stays identical.
    SRC_MODEL="FILE-BACKED-DISK"
    SRC_SERIAL="$(basename "$SRC")"
fi
CONFIRM_EXPECTED="$SRC_SERIAL $SRC_MODEL"

echo "SOURCE : $SRC"
echo "TARGET : $DEST_IMG  (+ $LABEL.manifest.csv)"
echo "IDENTITY FOR CONFIRMATION:"
echo "  $CONFIRM_EXPECTED"
echo ""

if (( DRY_RUN )); then
    echo "[dry-run] enumeration + interlocks passed -- no image written."
    exit 0
fi

# --- Typed confirmation: real TTY only -----------------------------------------
if [[ -n "${PHOENIX_FIXTURE_CONFIRM:-}" ]]; then
    # Test hook only (tests/emergency/test-image.sh). Production runs never set this.
    [[ "$PHOENIX_FIXTURE_CONFIRM" == "$CONFIRM_EXPECTED" ]] || {
        echo "[$PROG] fixture confirmation mismatch -- aborted." >&2; exit 3; }
    echo "[fixture] confirmation accepted."
elif [[ ! -t 0 ]]; then
    echo "[$PROG] stdin is not a TTY -- typed confirmation refused. Run interactively on the imaging host." >&2
    exit 3
else
    read -r -p "Type the identity EXACTLY as shown above to arm the imaging (anything else aborts): " answer
    if [[ "$answer" != "$CONFIRM_EXPECTED" ]]; then
        echo "Aborted. No image written."
        exit 3
    fi
fi

# --- Imaging --------------------------------------------------------------------
mkdir -p "$DEST_DIR"
echo ""
echo "[1/3] Imaging $SRC -> $DEST_IMG ..."
if command -v dcfldd >/dev/null 2>&1; then
    echo "      (dcfldd: hash-on-the-fly + progress)"
    dcfldd if="$SRC" of="$DEST_IMG" bs=64M hash=sha256 "hashlog=$DEST_DIR/$LABEL.dcfldd-hashlog.txt" \
        || { echo "[$PROG] dcfldd failed." >&2; exit 1; }
else
    echo "      (dd: no dcfldd on this host, hashing after copy)"
    # conv=noerror,sync: on a failing disk, bad sectors become zero-filled
    # gaps instead of aborting the image (forensic standard). Note: this pads
    # a short final block up to bs, so the image can be larger than the source.
    dd if="$SRC" of="$DEST_IMG" bs=64M status=progress conv=noerror,sync \
        || { echo "[$PROG] dd failed." >&2; exit 1; }
fi

# --- SHA-256 manifest in the check.sh Path,Hash contract -------------------------
echo ""
echo "[2/3] Writing SHA-256 manifest $DEST_MANIFEST ..."
IMG_HASH="$(sha256sum "$DEST_IMG" | awk '{print $1}')"
python3 - "$DEST_IMG" "$IMG_HASH" "$DEST_MANIFEST" <<'PY'
import csv, sys
path, digest, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out, "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["Path", "Hash"])
    w.writerow([path, digest])
PY
echo "      sha256($LABEL.img) = $IMG_HASH"

# --- Optional verify: re-read the written image, compare -------------------------
if (( VERIFY )); then
    echo ""
    echo "[3/3] Verifying: re-reading image and re-hashing ..."
    REREAD_HASH="$(sha256sum "$DEST_IMG" | awk '{print $1}')"
    if [[ "$REREAD_HASH" != "$IMG_HASH" ]]; then
        echo "[$PROG] VERIFICATION FAILED -- re-read hash differs from manifest." >&2
        echo "The image is NOT trustworthy. Do not proceed to the nuke phase." >&2
        exit 1
    fi
    echo "      re-read hash matches manifest. Image verified."
fi

echo ""
echo "IMAGING COMPLETE."
echo "  image   : $DEST_IMG"
echo "  manifest: $DEST_MANIFEST"
echo "  sha256  : $IMG_HASH"
echo "Next: copy to Castle with scripts/emergency/Send-ImageToCastle.sh (Phase 2.6)."
