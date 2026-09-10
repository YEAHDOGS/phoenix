#!/usr/bin/env bash
#===============================================================================
# New-ImageProof.sh -- Phoenix BACKUP phase: write an image-proof manifest
#
# After Rescuezilla (or equivalent) finishes a full-disk image AND its
# post-backup integrity check passes, this tool records the proof that the
# Nuke phase demands: tools/Invoke-Nuke.sh --image-proof <file> refuses to
# arm without a VALID manifest (format phoenix-image-proof/1, verified=YES,
# 64-hex sha256, positive size, source_serial bound to the nuke target).
#
# The proof is a plain key=value text file -- no jq needed in the boot image.
# Keep it on the Phoenix USB (next to the nuke logs) so the Nuke phase can
# read it.
#
# USAGE:
#   New-ImageProof.sh --image-name laptop-fulldisk-2026-09-09 \
#       --image-path /media/usb-target/laptop-fulldisk-2026-09-09 \
#       --source-serial SATATEST001 --source-dev /dev/nvme0n1 \
#       --sha256 <64-hex of the image checksum file> \
#       --verified --verified-by brandon
#
#   --verified asserts YOU watched the backup tool's integrity check pass.
#   Without it the manifest records verified=NO and the nuke gate rejects it.
#
# Exit codes: 0 = proof written | 1 = usage/validation error
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"

IMAGE_NAME=""; IMAGE_PATH=""; SOURCE_SERIAL=""; SOURCE_DEV=""
SHA256=""; SIZE_BYTES=""; VERIFIED_BY=""; OUT_DIR="."; JSON_OUT=""; VERIFIED=0

usage() {
    cat <<EOF
Phoenix image-proof writer (Backup phase).

Usage:
  $PROG --image-name <name> --image-path <dir-or-file> \\
        --source-serial <serial> --sha256 <64-hex> --verified \\
        [--source-dev /dev/nvme0n1] [--image-size-bytes N]
        [--verified-by <who>] [--out <dir>] [--json-out <dir>]

  --image-name        label, e.g. laptop-fulldisk-2026-09-09
  --image-path        where the image lives (dir or file); size is read
                      from it when --image-size-bytes is omitted
  --source-serial     serial of the disk that was imaged (binds the proof
                      to the nuke target -- must match exactly)
  --source-dev        /dev node of the source disk (recorded for forensics)
  --sha256            64-hex checksum of the image (from the backup tool's
                      own checksum file -- do NOT invent one)
  --verified          REQUIRED: asserts the backup tool's post-backup
                      integrity check passed. Without it the proof is
                      written verified=NO and the nuke gate rejects it.
  --verified-by       operator name (default: \$USER)
  --image-size-bytes  override the size read from --image-path
  --out               directory for the .proof file (default: .)
  --json-out DIR      ALSO write backup-image-proof.json (schema
                      phoenix-image-proof/1) into DIR -- the JSON sibling
                      the REINSTALL chain-of-custody gate consumes. Without
                      it the proof exists only for the Nuke --image-proof
                      gate.
EOF
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

while (( $# > 0 )); do
    case "$1" in
        --image-name)       IMAGE_NAME="${2:?}"; shift 2 ;;
        --image-path)       IMAGE_PATH="${2:?}"; shift 2 ;;
        --source-serial)    SOURCE_SERIAL="${2:?}"; shift 2 ;;
        --source-dev)       SOURCE_DEV="${2:?}"; shift 2 ;;
        --sha256)           SHA256="${2:?}"; shift 2 ;;
        --image-size-bytes) SIZE_BYTES="${2:?}"; shift 2 ;;
        --verified-by)      VERIFIED_BY="${2:?}"; shift 2 ;;
        --out)              OUT_DIR="${2:?}"; shift 2 ;;
        --json-out)         JSON_OUT="${2:?}"; shift 2 ;;
        --verified)         VERIFIED=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ -n "$IMAGE_NAME" ]]    || die "--image-name is required"
[[ -n "$IMAGE_PATH" ]]    || die "--image-path is required"
[[ -n "$SOURCE_SERIAL" ]] || die "--source-serial is required"
[[ -n "$SHA256" ]]        || die "--sha256 is required"
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 must be 64 hex chars"
[[ -e "$IMAGE_PATH" ]]    || die "--image-path '$IMAGE_PATH' does not exist"
[[ -d "$OUT_DIR" ]]       || die "--out '$OUT_DIR' is not a directory"

if [[ -z "$SIZE_BYTES" ]]; then
    if [[ -d "$IMAGE_PATH" ]]; then
        SIZE_BYTES="$(du -sb "$IMAGE_PATH" | cut -f1)"
    else
        SIZE_BYTES="$(stat -c %s "$IMAGE_PATH")"
    fi
fi
[[ "$SIZE_BYTES" =~ ^[0-9]+$ && "$SIZE_BYTES" -gt 0 ]] || \
    die "could not determine a positive image size from '$IMAGE_PATH'"

VERIFIED_BY="${VERIFIED_BY:-${USER:-unknown}}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/image-proof-${SOURCE_SERIAL}-${TS}.proof"

{
    echo "# phoenix image-proof manifest -- written by $PROG"
    echo "# keep on the Phoenix USB; pass to Invoke-Nuke.sh --image-proof"
    echo "format=phoenix-image-proof/1"
    echo "image_name=$IMAGE_NAME"
    echo "image_path=$IMAGE_PATH"
    echo "source_serial=$SOURCE_SERIAL"
    echo "source_dev=$SOURCE_DEV"
    echo "image_size_bytes=$SIZE_BYTES"
    echo "sha256=$SHA256"
    echo "created_utc=$TS"
    if (( VERIFIED == 1 )); then
        echo "verified=YES"
    else
        echo "verified=NO"
    fi
    echo "verified_by=$VERIFIED_BY"
} > "$OUT"

echo "Proof written: $OUT"
# JSON sibling for the REINSTALL chain-of-custody gate (schema
# phoenix-image-proof/1). The Nuke phase consumes the .proof file; the
# Reinstall phase consumes this JSON. Both are written from the same
# source data so they cannot disagree about serial/hash/verified.
if [[ -n "$JSON_OUT" ]]; then
    [[ -d "$JSON_OUT" ]] || die "--json-out '$JSON_OUT' is not a directory"
    export PHOENIX_PROOF_SERIAL="$SOURCE_SERIAL" \
        PHOENIX_PROOF_SHA256="$SHA256" PHOENIX_PROOF_IMAGE_PATH="$IMAGE_PATH" \
        PHOENIX_PROOF_IMAGE_NAME="$IMAGE_NAME" PHOENIX_PROOF_TS="$TS" \
        PHOENIX_PROOF_VERIFIED_BY="$VERIFIED_BY"
    if (( VERIFIED == 1 )); then PHOENIX_PROOF_VERIFIED=YES; else PHOENIX_PROOF_VERIFIED=NO; fi
    export PHOENIX_PROOF_VERIFIED
    python3 - "$JSON_OUT" <<'PYEOF'
import json, os, sys
ver = os.environ.get("PHOENIX_PROOF_VERIFIED", "NO")
data = {
    "schema": "phoenix-image-proof/1",
    "serial": os.environ["PHOENIX_PROOF_SERIAL"],
    "verified": ver == "YES",
    "sha256": os.environ["PHOENIX_PROOF_SHA256"],
    "image": os.environ["PHOENIX_PROOF_IMAGE_PATH"],
    "image_name": os.environ["PHOENIX_PROOF_IMAGE_NAME"],
    "created_utc": os.environ["PHOENIX_PROOF_TS"],
    "verified_by": os.environ["PHOENIX_PROOF_VERIFIED_BY"],
}
open(os.path.join(sys.argv[1], "backup-image-proof.json"), "w").write(json.dumps(data, indent=2) + "\n")
PYEOF
    echo "JSON proof written: $JSON_OUT/backup-image-proof.json"
fi
if (( VERIFIED == 0 )); then
    echo "NOTE: verified=NO -- the nuke image-proof gate will REJECT this proof."
    echo "Re-run with --verified only after the backup tool's integrity check passes."
fi
