#!/usr/bin/env bash
#===============================================================================
# Send-ImageToCastle.sh -- Phoenix emergency Phase 2.6 (Linux / clean machine)
#
# Bash twin of scripts/emergency/Send-ImageToCastle.ps1. Same contract:
#   1. SHA-256 tree fingerprint of the image directory.
#   2. Copy to the Castle quarantine target (rsync, no --delete).
#   3. Re-fingerprint the copy; FAIL CLOSED on any mismatch.
#   4. Write image-proof.txt next to the copy (evidence for the nuke gate).
#
# USAGE:
#   Send-ImageToCastle.sh -i IMAGE_DIR [-t TARGET] [-l LABEL] [--dry-run]
#
#   TARGET defaults to $PHOENIX_CASTLE_TARGET (e.g. /mnt/castle/quarantine).
#   LABEL  defaults to QUARANTINE-INFECTED-<yyyy-MM-dd>.
#
# Exit codes: 0 verified copy | 1 verification failure | 2 bad args |
#             3 not on clean machine (typed confirmation failed) |
#             4 dest exists | 5 rsync failure.
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
IMAGE_DIR=""
TARGET="${PHOENIX_CASTLE_TARGET:-}"
LABEL="QUARANTINE-INFECTED-$(date +%F)"
DRY_RUN=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--image-dir) IMAGE_DIR="${2:?needs a directory}"; shift 2;;
        -t|--target)    TARGET="${2:?needs a directory}"; shift 2;;
        -l|--label)     LABEL="${2:?needs a label}"; shift 2;;
        --dry-run)      DRY_RUN=1; shift;;
        --help|-h)      usage 0;;
        *) echo "[$PROG] unknown argument: $1" >&2; exit 2;;
    esac
done

[[ -n "$IMAGE_DIR" ]] || { echo "[$PROG] -i IMAGE_DIR is required" >&2; exit 2; }
[[ -d "$IMAGE_DIR" ]] || { echo "[$PROG] not a directory: $IMAGE_DIR" >&2; exit 2; }
[[ -n "$TARGET" ]] || { echo "[$PROG] no Castle target: pass -t or set PHOENIX_CASTLE_TARGET" >&2; exit 2; }

echo ""
echo "================================================================="
echo "  PHOENIX PHASE 2.6 -- IMAGE TO CASTLE QUARANTINE"
echo "  THIS MUST RUN ON THE CLEAN MACHINE."
echo "  Never run this on the infected laptop."
echo "================================================================="
echo ""

# Typed confirmation on a real TTY only -- piped input can never confirm.
if [[ ! -t 0 ]]; then
    echo "[$PROG] stdin is not a TTY -- confirmation refused. Run interactively on the clean machine." >&2
    exit 3
fi
read -r -p "Type CLEAN to confirm you are on the clean machine (anything else aborts): " answer
if [[ "$answer" != "CLEAN" ]]; then
    echo "Aborted. Run this from the clean machine only."
    exit 3
fi

# --- SHA-256 tree fingerprint: SHA256( sorted "relpath:sha256" lines ) --------
tree_fingerprint() { # $1 = root dir ; prints "<filecount> <fingerprint>"
    local root="$1"
    python3 - "$root" <<'PY'
import hashlib, os, sys
root = os.path.abspath(sys.argv[1])
entries = []
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        h = hashlib.sha256()
        with open(full, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        entries.append(f"{rel}:{h.hexdigest()}")
if not entries:
    print("EMPTY", file=sys.stderr); sys.exit(1)
entries.sort()
tree = hashlib.sha256("\n".join(entries).encode("utf-8")).hexdigest()
print(f"{len(entries)} {tree}")
PY
}

DEST="$TARGET/$LABEL"
echo "Source : $IMAGE_DIR"
echo "Target : $DEST"
echo ""

echo "[1/3] Fingerprinting source image..."
read -r SRC_COUNT SRC_FP < <(tree_fingerprint "$IMAGE_DIR")
echo "      $SRC_COUNT file(s), tree fingerprint: $SRC_FP"

if (( DRY_RUN )); then
    echo "[dry-run] would copy $SRC_COUNT file(s) to $DEST -- no writes made."
    exit 0
fi

echo "[2/3] Copying to Castle (rsync, archive, no --delete)..."
if [[ -e "$DEST" ]]; then
    echo "[$PROG] destination already exists: $DEST -- refusing to merge into an existing quarantine folder." >&2
    exit 4
fi
mkdir -p "$DEST"
rsync -a --info=progress2 "$IMAGE_DIR/" "$DEST/" || { echo "[$PROG] rsync failed." >&2; exit 5; }

echo "[3/3] Re-fingerprinting the copy..."
read -r DST_COUNT DST_FP < <(tree_fingerprint "$DEST")
echo "      $DST_COUNT file(s), tree fingerprint: $DST_FP"

if [[ "$DST_FP" != "$SRC_FP" || "$DST_COUNT" != "$SRC_COUNT" ]]; then
    echo "[$PROG] COPY VERIFICATION FAILED -- fingerprints differ." >&2
    echo "The Castle copy is NOT trustworthy. Investigate before proceeding to Phase 3." >&2
    exit 1
fi

cat > "$DEST/image-proof.txt" <<EOF
Phoenix image proof (Phase 2.6)
label=$LABEL
source_fingerprint=$SRC_FP
copy_fingerprint=$DST_FP
file_count=$SRC_COUNT
verified_utc=$(date -u +%FT%TZ)
algorithm=SHA-256 tree fingerprint (relpath:sha256 per file, sorted, hashed)
EOF

echo ""
echo "COPY VERIFIED -- $SRC_COUNT file(s), fingerprint match."
echo "Proof written to: $DEST/image-proof.txt"
echo "Quarantine label: $LABEL -- never mount this on a daily-driver machine."
