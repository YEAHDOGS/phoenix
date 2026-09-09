#!/usr/bin/env bash
#===============================================================================
# phoenix-backup.sh -- Phoenix BACKUP phase: native chunked disk imager
# (Linux rescue side of the Phoenix USB)
#
# Streams a whole disk (/dev/nvme0n1, /dev/sda, ...) into compressed,
# individually-hashed chunks on a DIRECT-ATTACHED target (USB drive) with:
#   - progress (one line per chunk)
#   - resume (state file skips already-verified chunks)
#   - SHA-512 verification of every chunk AND of the whole uncompressed stream
#   - a phoenix-backup/1 manifest
#   - automatic minting of the nuke-gate proof via tools/New-ImageProof.sh
#     (the proof is only minted when verification PASSES -- verified image or
#     no wipe, enforced in code)
#
# AIR-GAP: this tool never touches the network. Image to a direct-attached
# USB drive. Copying the image to Castle's 10TB drive happens from a CLEAN
# machine (runbook Step 2.7) -- never from the infected laptop.
#
# Twin: tools/New-PhoenixBackup.ps1 (WinPE side -- dism WIM capture of the
# OS volume, same manifest/proof contract; raw whole-disk dd is not feasible
# from WinPE PowerShell, so the Linux rescue side is the whole-disk path).
#
# USAGE:
#   phoenix-backup.sh --source /dev/nvme0n1 --source-serial SATATEST001 \
#       --out /media/usb-target/laptop-fulldisk-2026-09-09 \
#       --operator brandon
#
#   phoenix-backup.sh --source /dev/nvme0n1 --source-serial X --out <dir> \
#       --chunk-mib 1024 --compressor zstd --proof-out /media/phoenix-usb/phoenix-logs
#
# Exit codes: 0 = imaged, verified, manifest + proof written
#             1 = usage/validation/preflight failure
#             2 = imaging or verification failure (chunks left for --resume)
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SOURCE=""; SOURCE_SERIAL=""; OUT=""
CHUNK_MIB=512
COMPRESSOR="auto"          # auto | zstd | gzip | none
ALLOW_FILE=0               # testing only: accept a regular file as --source
OPERATOR="${USER:-unknown}"
MINT_PROOF=1
PROOF_OUT=""
PROOF_WRITER="$SCRIPT_DIR/New-ImageProof.sh"
FRESH=0

usage() {
    sed -n '2,/^#==*$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die()  { echo "[$PROG] FATAL: $*" >&2; exit 1; }
die2() { echo "[$PROG] FATAL: $*" >&2; exit 2; }

while (( $# > 0 )); do
    case "$1" in
        --source)        SOURCE="${2:?}"; shift 2 ;;
        --source-serial) SOURCE_SERIAL="${2:?}"; shift 2 ;;
        --out)           OUT="${2:?}"; shift 2 ;;
        --chunk-mib)     CHUNK_MIB="${2:?}"; shift 2 ;;
        --compressor)    COMPRESSOR="${2:?}"; shift 2 ;;
        --allow-file)    ALLOW_FILE=1; shift ;;
        --operator)      OPERATOR="${2:?}"; shift 2 ;;
        --no-mint-proof) MINT_PROOF=0; shift ;;
        --proof-out)     PROOF_OUT="${2:?}"; shift 2 ;;
        --proof-writer)  PROOF_WRITER="${2:?}"; shift 2 ;;
        --fresh)         FRESH=1; shift ;;
        -h|--help)       usage 0 ;;
        *)               die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- validation (fail closed) ---------------------------------------------------
[[ -n "$SOURCE" ]]        || die "--source is required"
[[ -n "$SOURCE_SERIAL" ]] || die "--source-serial is required (binds the nuke-gate proof to this disk)"
[[ -n "$OUT" ]]           || die "--out is required"
[[ "$SOURCE_SERIAL" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
    || die "--source-serial must be 1-64 chars of [A-Za-z0-9_.-]"
[[ "$CHUNK_MIB" =~ ^[0-9]+$ && "$CHUNK_MIB" -gt 0 ]] \
    || die "--chunk-mib must be a positive integer"
case "$COMPRESSOR" in auto|zstd|gzip|none) ;; *) die "--compressor must be auto|zstd|gzip|none" ;; esac
[[ -e "$SOURCE" ]] || die "--source '$SOURCE' does not exist"
if [[ -b "$SOURCE" ]]; then
    : # block device -- the real path
elif [[ -f "$SOURCE" && "$ALLOW_FILE" -eq 1 ]]; then
    : # regular file -- test harness only
else
    die "--source '$SOURCE' is not a block device (pass --allow-file only for tests)"
fi
[[ -x "$PROOF_WRITER" || -f "$PROOF_WRITER" ]] || die "proof writer not found: $PROOF_WRITER"

# --- source size ----------------------------------------------------------------
if [[ -b "$SOURCE" ]]; then
    command -v blockdev >/dev/null 2>&1 || die "blockdev not found (needed to size a block device)"
    SRC_SIZE="$(blockdev --getsize64 "$SOURCE" 2>/dev/null)" || die "cannot size source device '$SOURCE'"
else
    SRC_SIZE="$(stat -c %s "$SOURCE")"
fi
[[ "$SRC_SIZE" =~ ^[0-9]+$ && "$SRC_SIZE" -gt 0 ]] || die "source has zero/unreadable size -- refusing"

# --- compressor -----------------------------------------------------------------
pick_compressor() {
    local c="$1"
    if [[ "$c" == "auto" ]]; then
        if command -v zstd >/dev/null 2>&1; then echo "zstd"
        elif command -v gzip >/dev/null 2>&1; then echo "gzip"
        else echo "none"; fi
    else echo "$c"; fi
}
COMP="$(pick_compressor "$COMPRESSOR")"
case "$COMP" in
    zstd) command -v zstd >/dev/null 2>&1 || die "zstd requested but not installed"; EXT="zst";;
    gzip) command -v gzip >/dev/null 2>&1 || die "gzip requested but not installed"; EXT="gz";;
    none) EXT="raw";;
esac

# --- output dir + state ----------------------------------------------------------
IMAGE_NAME="$(basename "$OUT")"
[[ -n "$IMAGE_NAME" && "$IMAGE_NAME" != "/" && "$IMAGE_NAME" != "." ]] \
    || die "--out must end in an image directory name"
STATE="$OUT/.phoenix-backup.state"
MANIFEST="$OUT/backup.manifest"
LOG="$OUT/backup.log"

if [[ -e "$OUT" && ! -d "$OUT" ]]; then die "--out '$OUT' exists and is not a directory"; fi
if (( FRESH == 1 )) && [[ -d "$OUT" ]]; then
    echo "[$PROG] --fresh: clearing previous run state in $OUT" >&2
    rm -f "$OUT"/chunk-*.img.* "$STATE" "$MANIFEST"
fi
mkdir -p "$OUT" || die "cannot create --out '$OUT'"

# free-space preflight: the compressed image is <= the raw source, so demanding
# a full raw-size of free space guarantees no mid-write ENOSPC. Fail closed.
FREE_BYTES="$(df --output=avail -B1 "$OUT" 2>/dev/null | tail -1 | tr -d ' ')"
[[ "$FREE_BYTES" =~ ^[0-9]+$ ]] || die "cannot determine free space on target"
(( FREE_BYTES >= SRC_SIZE )) \
    || die "target has ${FREE_BYTES}B free but source is ${SRC_SIZE}B -- refusing (need >= source size)"

# state file: header lines + one TAB-separated line per completed chunk:
#   idx \t chunk-file \t raw_sha512 \t comp_sha512 \t raw_bytes \t comp_bytes
declare -A ST_RAW ST_COMP
STATE_SRC_SIZE=""; STATE_SERIAL=""; STATE_COMP=""
if [[ -f "$STATE" ]]; then
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
            format=*)      continue ;;  # phoenix-backup-state/1 tag
            src_size=*)   STATE_SRC_SIZE="${line#src_size=}" ;;
            src_serial=*) STATE_SERIAL="${line#src_serial=}" ;;
            compressor=*) STATE_COMP="${line#compressor=}" ;;
            chunk_mib=*)  continue ;;  # informational only
            chunk$'\t'*)
                IFS=$'\t' read -r _tag idx cfile rsha csha rbytes cbytes <<<"$line"
                ST_RAW["$idx"]="$rsha"; ST_COMP["$idx"]="$cfile|$csha|$rbytes|$cbytes" ;;
            *) die "corrupt state file '$STATE' (bad line) -- refusing (use --fresh to restart)" ;;
        esac
    done < "$STATE"
    [[ "$STATE_SERIAL" == "$SOURCE_SERIAL" ]] \
        || die "state file is for serial '$STATE_SERIAL', not '$SOURCE_SERIAL' -- refusing (use --fresh)"
    [[ "$STATE_SRC_SIZE" == "$SRC_SIZE" ]] \
        || die "state file is for a ${STATE_SRC_SIZE}B source, current source is ${SRC_SIZE}B -- refusing (use --fresh)"
    [[ "$STATE_COMP" == "$COMP" ]] \
        || die "state file used compressor '$STATE_COMP', this run wants '$COMP' -- refusing (use --fresh)"
else
    {
        echo "# phoenix-backup state -- resume ledger (do not hand-edit)"
        echo "format=phoenix-backup-state/1"
        echo "src_serial=$SOURCE_SERIAL"
        echo "src_size=$SRC_SIZE"
        echo "compressor=$COMP"
        echo "chunk_mib=$CHUNK_MIB"
    } > "$STATE" || die "cannot write state file"
fi

CHUNK_COUNT=$(( (SRC_SIZE + CHUNK_MIB*1048576 - 1) / (CHUNK_MIB*1048576) ))
(( CHUNK_COUNT >= 1 )) || die "computed zero chunks -- refusing"

echo "[$PROG] imaging $SOURCE (${SRC_SIZE}B, serial $SOURCE_SERIAL) -> $OUT" | tee -a "$LOG"
echo "[$PROG] $CHUNK_COUNT chunk(s) x ${CHUNK_MIB}MiB, compressor=$COMP" | tee -a "$LOG"

# --- imaging ---------------------------------------------------------------------
compress_cmd() {
    case "$COMP" in
        zstd) zstd -q -T0 -c ;;
        gzip) gzip -q -c ;;
        none) cat ;;
    esac
}

chunk_file() { printf "%s/chunk-%05d.img.%s" "$OUT" "$1" "$EXT"; }

i=0
while (( i < CHUNK_COUNT )); do
    CF="$(chunk_file "$i")"
    if [[ -n "${ST_RAW[$i]:-}" && -f "$CF" ]]; then
        IFS='|' read -r sfile scsha srbytes scbytes <<<"${ST_COMP[$i]}"
        if [[ "$sfile" == "$CF" ]]; then
            actual="$(sha512sum "$CF" | cut -d' ' -f1)"
            if [[ "$actual" == "$scsha" ]]; then
                echo "[$PROG] chunk $((i+1))/$CHUNK_COUNT already verified -- skipping" | tee -a "$LOG"
                i=$((i+1)); continue
            fi
            echo "[$PROG] chunk $((i+1))/$CHUNK_COUNT hash mismatch on resume -- re-imaging" | tee -a "$LOG"
        fi
    fi
    echo "[$PROG] chunk $((i+1))/$CHUNK_COUNT: reading..." | tee -a "$LOG"
    RAWTMP="$OUT/.chunk.raw.tmp"
    # Stream through a temp raw copy: one deterministic pass, no background-
    # job races. Temp is bounded by one chunk and lives on the target FS
    # (covered by the free-space preflight), removed right after hashing.
    if ! dd if="$SOURCE" bs=1M skip=$((i*CHUNK_MIB)) count="$CHUNK_MIB" iflag=fullblock status=none 2>/dev/null \
        | tee "$RAWTMP" \
        | compress_cmd > "$CF.tmp"; then
        rm -f "$RAWTMP" "$CF.tmp"
        die2 "imaging failed at chunk $((i+1))/$CHUNK_COUNT -- state kept, re-run to resume"
    fi
    mv "$CF.tmp" "$CF"
    RAW_SHA="$(sha512sum "$RAWTMP" | cut -d' ' -f1)"
    RAW_BYTES="$(stat -c %s "$RAWTMP")"
    rm -f "$RAWTMP"
    [[ "$RAW_SHA" =~ ^[0-9a-f]{128}$ ]] || die2 "could not hash chunk $((i+1)) -- refusing"
    [[ "$RAW_BYTES" =~ ^[0-9]+$ && "$RAW_BYTES" -gt 0 ]] || die2 "chunk $((i+1)) read zero bytes -- refusing"
    COMP_SHA="$(sha512sum "$CF" | cut -d' ' -f1)"
    COMP_BYTES="$(stat -c %s "$CF")"
    printf 'chunk\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$CF" "$RAW_SHA" "$COMP_SHA" "$RAW_BYTES" "$COMP_BYTES" >> "$STATE"
    ST_RAW["$i"]="$RAW_SHA"; ST_COMP["$i"]="$CF|$COMP_SHA|$RAW_BYTES|$COMP_BYTES"
    echo "[$PROG] chunk $((i+1))/$CHUNK_COUNT done (${COMP_BYTES}B stored)" | tee -a "$LOG"
    i=$((i+1))
done

# --- verification: decompress every chunk, check hashes, stream hash ---------------
echo "[$PROG] verifying $CHUNK_COUNT chunk(s)..." | tee -a "$LOG"
decompress_cmd() {
    case "$COMP" in
        zstd) zstd -q -d -c -- "$1" ;;
        gzip) gzip -q -d -c -- "$1" ;;
        none) cat -- "$1" ;;
    esac
}
VFIFO="$(mktemp -u)"; mkfifo "$VFIFO"
sha512sum < "$VFIFO" > "$OUT/.stream.sha.tmp" &
VHASH_PID=$!
# Hold one write end open for the whole loop: without it the background
# sha512sum would see a spurious EOF between per-chunk writers and exit early.
exec 9>"$VFIFO"
trap 'exec 9>&- 2>/dev/null; kill "$VHASH_PID" 2>/dev/null; rm -f "$VFIFO"' EXIT
VRAWTMP="$OUT/.verify.raw.tmp"
i=0
while (( i < CHUNK_COUNT )); do
    CF="$(chunk_file "$i")"
    [[ -f "$CF" ]] || die2 "chunk file missing during verify: $CF"
    # One deterministic pass: decompressed bytes go to a temp raw copy (for
    # the per-chunk hash check) AND into the FIFO (for the cumulative stream
    # hash). No background-job races -- the pipeline completes before we hash.
    if ! decompress_cmd "$CF" | tee "$VRAWTMP" > "$VFIFO"; then
        PIPE0="${PIPESTATUS[0]:-1}"
        rm -f "$VRAWTMP"
        die2 "chunk $((i+1)) failed to decompress (exit $PIPE0) -- image corrupt, re-run to re-image it"
    fi
    GOT="$(sha512sum "$VRAWTMP" | cut -d' ' -f1)"
    rm -f "$VRAWTMP"
    [[ "$GOT" == "${ST_RAW[$i]}" ]] \
        || die2 "chunk $((i+1)) raw hash mismatch (expected ${ST_RAW[$i]}, got $GOT) -- image corrupt"
    echo "[$PROG] chunk $((i+1))/$CHUNK_COUNT verified" | tee -a "$LOG"
    i=$((i+1))
done
exec 9>&-   # last writer closes -> background sha512sum sees EOF and finishes
wait "$VHASH_PID" 2>/dev/null || die2 "stream hash computation failed"
trap - EXIT
rm -f "$VFIFO"
STREAM_SHA="$(cut -d' ' -f1 < "$OUT/.stream.sha.tmp")"; rm -f "$OUT/.stream.sha.tmp"
[[ "$STREAM_SHA" =~ ^[0-9a-f]{128}$ ]] || die2 "could not compute stream SHA-512 -- refusing"

# sha256 over the concatenated chunk FILES (the nuke-proof content binding)
CONCAT_SHA="$(for (( j=0; j<CHUNK_COUNT; j++ )); do cat "$(chunk_file "$j")"; done | sha256sum | cut -d' ' -f1)"
[[ "$CONCAT_SHA" =~ ^[0-9a-f]{64}$ ]] || die2 "could not compute chunk-set SHA-256 -- refusing"

COMP_TOTAL=0
i=0; while (( i < CHUNK_COUNT )); do IFS='|' read -r _ _ _ cb <<<"${ST_COMP[$i]}"; COMP_TOTAL=$((COMP_TOTAL+cb)); i=$((i+1)); done
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# --- manifest ----------------------------------------------------------------------
{
    echo "# phoenix backup manifest -- written only after verification PASSES"
    echo "format=phoenix-backup/1"
    echo "image_name=$IMAGE_NAME"
    echo "image_kind=raw-chunked"
    echo "source_dev=$SOURCE"
    echo "source_serial=$SOURCE_SERIAL"
    echo "source_size_bytes=$SRC_SIZE"
    echo "chunk_mib=$CHUNK_MIB"
    echo "chunk_count=$CHUNK_COUNT"
    echo "compressor=$COMP"
    echo "compressed_size_bytes=$COMP_TOTAL"
    echo "stream_sha512=$STREAM_SHA"
    echo "chunks_concat_sha256=$CONCAT_SHA"
    echo "tool=phoenix-backup.sh"
    echo "created_utc=$TS"
    echo "operator=$OPERATOR"
    echo "verify=PASS"
} > "$MANIFEST" || die2 "cannot write manifest"
echo "[$PROG] manifest written: $MANIFEST" | tee -a "$LOG"
echo "[$PROG] stream SHA-512: $STREAM_SHA" | tee -a "$LOG"

# --- mint the nuke-gate proof (fail closed: no proof without a verified image) ----
if (( MINT_PROOF == 1 )); then
    [[ -n "$PROOF_OUT" ]] || PROOF_OUT="$OUT"
    mkdir -p "$PROOF_OUT" || die2 "cannot create proof dir '$PROOF_OUT'"
    "$PROOF_WRITER" \
        --image-name "$IMAGE_NAME" \
        --image-path "$OUT" \
        --source-serial "$SOURCE_SERIAL" \
        --source-dev "$SOURCE" \
        --sha256 "$CONCAT_SHA" \
        --image-size-bytes "$COMP_TOTAL" \
        --verified --verified-by "$OPERATOR" \
        --out "$PROOF_OUT" >>"$LOG" 2>&1 \
        || die2 "proof minting failed -- image is verified but the nuke gate has no proof (re-run handles it)"
    echo "[$PROG] nuke-gate proof minted in $PROOF_OUT" | tee -a "$LOG"
fi

echo "[$PROG] DONE: verified image of $SOURCE (${SRC_SIZE}B) in $OUT" | tee -a "$LOG"
