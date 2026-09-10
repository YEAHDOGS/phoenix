#!/usr/bin/env bash
#===============================================================================
# phoenix-quarantine-copy.sh -- Phoenix BACKUP phase Step 2.7: quarantine copy
#
# Copies a VERIFIED full-disk image to long-term storage (Castle's 10TB drive)
# from a CLEAN machine -- never from the infected laptop (runbook Step 2.7).
# The copy lands in a clearly-labeled QUARANTINE-INFECTED-<date>/ folder so
# the infected image is never mistaken for a restore source.
#
# Fail-closed contract:
#   - Refuses the copy unless there is machine-readable evidence the image was
#     VERIFIED: either a phoenix-backup/1 manifest with verify=PASS (the
#     scripted Step 2.3 path) or a phoenix-image-proof/1 file with
#     verified=YES (the Rescuezilla GUI path -- mint it with
#     tools/New-ImageProof.sh after the post-backup check passes).
#   - Refuses network-filesystem targets (nfs/cifs/smb/sshfs/9p/ceph/UNC):
#     the quarantine copy goes to a DIRECT-ATTACHED drive. The runbook is
#     explicit -- the infected machine stays air-gapped; this tool runs on
#     the clean side, but a network target here would reintroduce the exact
#     exposure Step 2.7 forbids.
#   - Refuses target == source, target inside source, source inside target.
#   - Fails the free-space preflight before copying a single byte.
#   - Re-verifies every chunk on the target after the copy (per-chunk SHA-512
#     from the backup state file when present; otherwise a decompress-and-
#     stream-hash of the whole image against the manifest, plus a byte-for-
#     byte source-vs-target check for proof-evidence images). The
#     quarantine-copy manifest is written verify=PASS ONLY after all checks
#     pass.
#   - Resumable: chunks already present on the target with matching hashes
#     are skipped; mismatched ones are re-copied.
#
# Layout written:
#   <target>/QUARANTINE-INFECTED-<date>/<image-name>/
#       chunk-00000.img.gz ...   (the image, exactly as backed up)
#       backup.manifest          (copied, when present)
#       .phoenix-backup.state    (copied, when present)
#       quarantine-copy.manifest (this tool's record, verify=PASS only on success)
#       <image-proof .proof>     (copied, when --image-proof was used)
#       copy.log                 (full run log)
#
# Twin: tools/New-PhoenixQuarantineCopy.ps1 -- the Windows/WinPE twin emits the
# identical quarantine-copy.manifest contract (same keys, same order), so a
# manifest written on Linux verifies identically on Windows and vice versa.
#
# USAGE:
#   phoenix-quarantine-copy.sh --source /media/usb-target/laptop-fulldisk-2026-09-09 \
#       --target /media/castle-10tb \
#       --date 2026-09-09 --operator brandon
#
#   phoenix-quarantine-copy.sh --source /media/usb-target/rescuezilla-img \
#       --target /media/castle-10tb \
#       --image-proof /media/phoenix-usb/phoenix-logs/image-proof-ABC123-*.proof
#
# Exit codes: 0 = copied, verified, manifest written
#             1 = usage/validation/preflight failure
#             2 = copy or verification failure (partial state kept, re-run resumes)
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"

SOURCE=""; TARGET=""; IMAGE_PROOF=""
QDATE="$(date -u +%F)"
OPERATOR="${USER:-unknown}"

usage() {
    sed -n '2,/^#==*$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die()  { echo "[$PROG] FATAL: $*" >&2; exit 1; }
die2() { echo "[$PROG] FATAL: $*" >&2; exit 2; }

while (( $# > 0 )); do
    case "$1" in
        --source)      SOURCE="${2:?}"; shift 2 ;;
        --target)      TARGET="${2:?}"; shift 2 ;;
        --image-proof) IMAGE_PROOF="${2:?}"; shift 2 ;;
        --date)        QDATE="${2:?}"; shift 2 ;;
        --operator)    OPERATOR="${2:?}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *)             die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- validation (fail closed) ----------------------------------------------------
[[ -n "$SOURCE" ]] || die "--source is required (the verified image directory)"
[[ -n "$TARGET" ]] || die "--target is required (direct-attached long-term storage)"
[[ "$QDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || die "--date must be YYYY-MM-DD (got '$QDATE')"
[[ -d "$SOURCE" ]] || die "--source '$SOURCE' is not a directory"
[[ -d "$TARGET" ]] || die "--target '$TARGET' is not a directory"

# canonicalize: every identity/path-containment check below uses these
canon() { realpath -m -- "$1" 2>/dev/null || readlink -f -- "$1"; }
CSRC="$(canon "$SOURCE")"; CTGT="$(canon "$TARGET")"
[[ "$CSRC" != "$CTGT" ]] \
    || die "--target is the same directory as --source -- refusing"
case "$CTGT" in "$CSRC"/*) die "--target sits INSIDE --source -- refusing" ;; esac
case "$CSRC" in "$CTGT"/*) die "--source sits INSIDE --target -- refusing" ;; esac

# network filesystems: refused -- direct-attached only (runbook Step 2.7)
case "$TARGET" in
    //*|\\\\*) die "--target looks like a UNC/network path -- refusing (direct-attached only)" ;;
esac
FS_TYPE="$(stat -f -c %T "$TARGET" 2>/dev/null || echo unknown)"
case "$FS_TYPE" in
    nfs|nfs4|cifs|smbfs|smb2|sshfs|fuse.sshfs|9p|ceph|cephfs|glusterfs|gluster)
        die "--target is on a network filesystem ($FS_TYPE) -- refusing (direct-attached only)" ;;
esac

# --- evidence: verified-image proof (fail closed) ---------------------------------
manifest_val() { grep -E "^$2=" "$1" | cut -d= -f2-; }

EVIDENCE=""; IMAGE_NAME="$(basename "$CSRC")"
SOURCE_SERIAL=""; STREAM_SHA=""; CONCAT_SHA=""; COMPRESSED_BYTES=""; MANIFEST_COMP=""
MAN_SRC="$SOURCE/backup.manifest"
if [[ -f "$MAN_SRC" ]]; then
    [[ "$(manifest_val "$MAN_SRC" format)" == "phoenix-backup/1" ]] \
        || die "backup.manifest has unknown format '$(manifest_val "$MAN_SRC" format)' -- refusing"
    [[ "$(manifest_val "$MAN_SRC" verify)" == "PASS" ]] \
        || die "backup.manifest verify != PASS -- the image is NOT verified, refusing the quarantine copy (run Step 2.4 first)"
    EVIDENCE="manifest"
    SOURCE_SERIAL="$(manifest_val "$MAN_SRC" source_serial)"
    STREAM_SHA="$(manifest_val "$MAN_SRC" stream_sha512)"
    CONCAT_SHA="$(manifest_val "$MAN_SRC" chunks_concat_sha256)"
    MANIFEST_COMP="$(manifest_val "$MAN_SRC" compressor)"
    IMAGE_NAME="$(manifest_val "$MAN_SRC" image_name)"
    [[ "$STREAM_SHA" =~ ^[0-9a-f]{128}$ ]] || die "backup.manifest has a bad stream_sha512 -- refusing"
    [[ "$CONCAT_SHA" =~ ^[0-9a-f]{64}$ ]]  || die "backup.manifest has a bad chunks_concat_sha256 -- refusing"
elif [[ -n "$IMAGE_PROOF" ]]; then
    [[ -f "$IMAGE_PROOF" ]] || die "--image-proof '$IMAGE_PROOF' does not exist"
    [[ "$(manifest_val "$IMAGE_PROOF" format)" == "phoenix-image-proof/1" ]] \
        || die "proof file has unknown format -- refusing"
    [[ "$(manifest_val "$IMAGE_PROOF" verified)" == "YES" ]] \
        || die "proof file is verified=NO -- the image is NOT verified, refusing (run Step 2.4 first)"
    EVIDENCE="proof"
    SOURCE_SERIAL="$(manifest_val "$IMAGE_PROOF" source_serial)"
else
    die "no verification evidence: '$SOURCE' has no backup.manifest with verify=PASS and no --image-proof was given -- refusing (verified image or no quarantine)"
fi

# --- chunk inventory --------------------------------------------------------------
# Chunk files, lexical order (chunk-%05d naming sorts correctly).
mapfile -t CHUNKS < <(cd "$SOURCE" && printf '%s\n' chunk-*.img.* 2>/dev/null | sort)
[[ "${CHUNKS[0]:-}" != "chunk-*.img.*" && -n "${CHUNKS[0]:-}" ]] \
    || die "no chunk-*.img.* files in --source '$SOURCE' -- refusing"
NCHUNKS="${#CHUNKS[@]}"
NEED=0
for c in "${CHUNKS[@]}"; do
    sz="$(stat -c %s "$SOURCE/$c")"
    [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt 0 ]] || die "chunk '$c' has zero/unreadable size -- refusing"
    NEED=$((NEED + sz))
done

# destination
QDIR="$CTGT/QUARANTINE-INFECTED-$QDATE"
DEST="$QDIR/$IMAGE_NAME"
LOG="$DEST/copy.log"
MANIFEST_OUT="$DEST/quarantine-copy.manifest"

mkdir -p "$DEST" || die "cannot create destination '$DEST'"
exec > >(tee -a "$LOG") 2>&1

echo "[$PROG] quarantine copy: $SOURCE -> $DEST"
echo "[$PROG] evidence=$EVIDENCE ($NCHUNKS chunks, ${NEED}B)"

# free-space preflight on the target filesystem (before a single byte is copied)
FREE_BYTES="$(df --output=avail -B1 "$DEST" 2>/dev/null | tail -1 | tr -d ' ')"
[[ "$FREE_BYTES" =~ ^[0-9]+$ ]] || die "cannot determine free space on target"
(( FREE_BYTES >= NEED + 1048576 )) \
    || die "target has ${FREE_BYTES}B free but the image needs ${NEED}B -- refusing"

# --- copy (resumable: skip chunks already present with matching hash) -------------
sha512_of() { sha512sum -- "$1" | cut -d' ' -f1; }

copy_chunk() {  # copy_chunk <name>: copies unless dest already hash-matches source
    local name="$1"
    local src="$SOURCE/$name"
    local dst="$DEST/$name"
    if [[ -f "$dst" ]]; then
        if [[ "$(sha512_of "$src")" == "$(sha512_of "$dst")" ]]; then
            echo "[$PROG] chunk $name already copied and hash-verified -- skipping"
            return 0
        fi
        echo "[$PROG] chunk $name present but HASH MISMATCH -- re-copying" >&2
    fi
    echo "[$PROG] copying chunk $name ..." >&2
    cp -f -- "$src" "$dst.tmp" || die2 "copy failed for chunk $name -- state kept, re-run to resume"
    mv -f -- "$dst.tmp" "$dst"
    [[ "$(sha512_of "$src")" == "$(sha512_of "$dst")" ]] \
        || die2 "post-copy hash mismatch on chunk $name -- target storage suspect, refusing"
}

for c in "${CHUNKS[@]}"; do copy_chunk "$c"; done

# copy the sidecar evidence files alongside the image (forensics paper trail)
[[ -f "$MAN_SRC" ]] && cp -f -- "$MAN_SRC" "$DEST/backup.manifest"
[[ -f "$SOURCE/.phoenix-backup.state" ]] && cp -f -- "$SOURCE/.phoenix-backup.state" "$DEST/.phoenix-backup.state"
if [[ -n "$IMAGE_PROOF" ]]; then
    cp -f -- "$IMAGE_PROOF" "$DEST/$(basename "$IMAGE_PROOF")" \
        || die2 "could not copy the image-proof file -- refusing"
fi

# --- verification -----------------------------------------------------------------
# Path A (scripted backup): per-chunk SHA-512 from the backup state file when
# present, then the whole-stream hash and the concatenated-chunk SHA-256 from
# the manifest. Path B (proof evidence): byte-for-byte source-vs-target check.
if [[ "$EVIDENCE" == "manifest" ]]; then
    if [[ -f "$DEST/.phoenix-backup.state" ]]; then
        declare -A WANT
        while IFS= read -r line; do
            case "$line" in
                chunk$'\t'*)
                    IFS=$'\t' read -r _tag idx cfile rsha csha rbytes cbytes <<<"$line"
                    bn="$(basename "$cfile")"
                    WANT["$bn"]="$csha" ;;
            esac
        done < "$DEST/.phoenix-backup.state"
        for c in "${CHUNKS[@]}"; do
            [[ -n "${WANT[$c]:-}" ]] || die2 "state file has no expected hash for chunk $c -- refusing"
            got="$(sha512_of "$DEST/$c")"
            [[ "$got" == "${WANT[$c]}" ]] \
                || die2 "target chunk $c fails per-chunk SHA-512 (expected ${WANT[$c]}, got $got) -- image corrupt on target"
        done
        echo "[$PROG] per-chunk SHA-512: $NCHUNKS/$NCHUNKS match"
    fi
    # whole-stream verification: decompress every target chunk in order and
    # hash the stream, exactly like phoenix-backup.sh's own verify pass.
    case "$MANIFEST_COMP" in
        zstd) command -v zstd >/dev/null 2>&1 || die2 "chunks are zstd-compressed but zstd is not installed -- cannot verify"
              decompress() { zstd -q -d -c -- "$1"; } ;;
        gzip) decompress() { gzip -q -d -c -- "$1"; } ;;
        none) decompress() { cat -- "$1"; } ;;
        *)    die2 "unknown compressor '$MANIFEST_COMP' in backup.manifest -- refusing" ;;
    esac
    VFIFO="$(mktemp -u)"; mkfifo "$VFIFO"
    sha512sum < "$VFIFO" > "$DEST/.stream.sha.tmp" &
    VHASH_PID=$!
    exec 9>"$VFIFO"
    trap 'exec 9>&- 2>/dev/null; kill "$VHASH_PID" 2>/dev/null; rm -f "$VFIFO"' EXIT
    for c in "${CHUNKS[@]}"; do
        if ! decompress "$DEST/$c" > "$VFIFO"; then
            PIPE0="${PIPESTATUS[0]:-1}"
            die2 "target chunk $c failed to decompress (exit $PIPE0) -- copy corrupt, re-run to re-copy it"
        fi
    done
    exec 9>&-
    wait "$VHASH_PID" 2>/dev/null || die2 "stream hash computation failed"
    trap - EXIT
    rm -f "$VFIFO"
    GOT_STREAM="$(cut -d' ' -f1 < "$DEST/.stream.sha.tmp")"; rm -f "$DEST/.stream.sha.tmp"
    [[ "$GOT_STREAM" == "$STREAM_SHA" ]] \
        || die2 "target stream SHA-512 mismatch (expected $STREAM_SHA, got $GOT_STREAM) -- copy corrupt"
    echo "[$PROG] stream SHA-512 matches manifest"
    GOT_CONCAT="$(for c in "${CHUNKS[@]}"; do cat "$DEST/$c"; done | sha256sum | cut -d' ' -f1)"
    [[ "$GOT_CONCAT" == "$CONCAT_SHA" ]] \
        || die2 "target chunk-set SHA-256 mismatch -- copy corrupt"
    echo "[$PROG] chunk-set SHA-256 matches manifest"
else
    # proof evidence: the operator asserted verification via the .proof file;
    # here we prove the COPY is byte-faithful, chunk by chunk.
    for c in "${CHUNKS[@]}"; do
        [[ "$(sha512_of "$SOURCE/$c")" == "$(sha512_of "$DEST/$c")" ]] \
            || die2 "target chunk $c differs from source -- copy corrupt"
    done
    echo "[$PROG] byte-for-byte source-vs-target: $NCHUNKS/$NCHUNKS match"
fi

# --- quarantine-copy manifest (written ONLY after verification passes) ------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
{
    echo "# phoenix quarantine-copy manifest -- written only after verification PASSES"
    echo "format=phoenix-quarantine-copy/1"
    echo "image_name=$IMAGE_NAME"
    echo "source_dir=$CSRC"
    echo "target_dir=$DEST"
    echo "quarantine_date=$QDATE"
    echo "evidence=$EVIDENCE"
    echo "source_serial=$SOURCE_SERIAL"
    echo "chunk_count=$NCHUNKS"
    echo "bytes_copied=$NEED"
    [[ "$EVIDENCE" == "manifest" ]] && echo "source_stream_sha512=$STREAM_SHA"
    [[ "$EVIDENCE" == "manifest" ]] && echo "source_chunks_concat_sha256=$CONCAT_SHA"
    [[ "$EVIDENCE" == "proof" ]]    && echo "image_proof=$(basename "$IMAGE_PROOF")"
    echo "target_fs_type=$FS_TYPE"
    echo "tool=phoenix-quarantine-copy.sh"
    echo "created_utc=$TS"
    echo "operator=$OPERATOR"
    echo "verify=PASS"
} > "$MANIFEST_OUT" || die2 "cannot write quarantine-copy manifest"

echo "[$PROG] DONE: verified quarantine copy at $DEST"
echo "[$PROG] The infected image is quarantined: never mount or boot it on a daily-driver machine."
