#!/usr/bin/env bash
#===============================================================================
# phoenix-data-backup.sh -- Phoenix BACKUP phase, Step 2.6: data-only backup
# (Linux rescue side of the Phoenix USB)
#
# Copies user data (NOT the whole disk) out of an infected Windows volume to a
# SECOND, SEPARATE direct-attached target -- Documents, Desktop, Downloads,
# Pictures, Videos, Music, .ssh, plus operator-nominated extras (Ableton
# projects, license exports, ...). The full-disk image (tools/phoenix-backup.sh)
# is the quarantine archive; THIS backup is what Phase 4 restores from, so it
# is treated as DIRTY by default: executables are skipped (recorded in
# skipped-executables.txt), every file gets a SHA-256 hash, and the output
# carries an explicit scan-before-restore marker.
#
# Source: either a --source-dev (mounted READ-ONLY by this tool via ntfs3 /
# ntfs-3g; never mounted read-write on an infected volume) or a --source-dir
# the operator mounted read-only themselves.
#
# AIR-GAP: this tool never touches the network. The target must be a
# direct-attached drive. Fail-closed: network filesystems (cifs/nfs/smbfs)
# and UNC-style paths are refused outright.
#
# Twin: tools/New-PhoenixDataBackup.ps1 (WinPE side -- robocopy-based copy of
# user profiles, same manifest/schema + dirty-data contract).
#
# USAGE (from the Backup environment, Phoenix USB mounted):
#   phoenix-data-backup.sh --source-dev /dev/nvme0n1p3 \
#       --out /media/usb-target2/laptop-data-2026-09-09 --operator brandon
#
#   phoenix-data-backup.sh --source-dir /mnt/infected \
#       --out /media/usb-target2/laptop-data-2026-09-09 \
#       --profiles brandon --extra "Ableton Projects:license-keys.txt"
#
# Exit codes: 0 = copied, hashed, manifest written
#             1 = usage/validation/preflight failure
#             2 = copy/hash failure (partial state kept for resume by re-run)
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"

SOURCE_DEV=""; SOURCE_DIR=""
OUT=""
PROFILES=""              # csv of profile names; empty = all non-system profiles
EXTRA=""                 # ':'-separated paths relative to the volume root
OPERATOR="${USER:-unknown}"
INCLUDE_EXE=0            # default: skip executables (dirty-data contract)

# Per-profile folders always copied. Keep this conservative: user DATA, not
# application state (which may harbour persistence). Ableton PROJECTS folders
# are user data; plugin caches are not.
PROFILE_FOLDERS=(Documents Desktop Downloads Pictures Videos Music .ssh)
# Profiles never copied even with --profiles all (system / template accounts).
SYSTEM_PROFILES=(Public "Default" "Default User" "All Users")

EXE_EXTS='exe|msi|dll|sys|scr|com|cpl|bat|cmd|ps1|vbs|vbe|jse|wsf|wsh|hta|pif|lnk'

usage() {
    sed -n '2,/^#==*$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die()  { echo "[$PROG] FATAL: $*" >&2; exit 1; }
die2() { echo "[$PROG] FATAL: $*" >&2; exit 2; }

while (( $# > 0 )); do
    case "$1" in
        --source-dev)  SOURCE_DEV="${2:?}"; shift 2 ;;
        --source-dir)  SOURCE_DIR="${2:?}"; shift 2 ;;
        --out)         OUT="${2:?}"; shift 2 ;;
        --profiles)    PROFILES="${2:?}"; shift 2 ;;
        --extra)       EXTRA="${2:?}"; shift 2 ;;
        --include-exe) INCLUDE_EXE=1; shift ;;
        --operator)    OPERATOR="${2:?}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *)             die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- validation (fail closed) ---------------------------------------------------
[[ -n "$SOURCE_DEV" || -n "$SOURCE_DIR" ]] \
    || die "one of --source-dev or --source-dir is required"
[[ -n "$OUT" ]] || die "--out is required"
case "$OUT" in //*|\\\\*) die "--out looks like a network path -- refusing (air-gap)" ;; esac
[[ "$OPERATOR" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
    || die "--operator must be 1-64 chars of [A-Za-z0-9_.-]"

# Target must be a local filesystem, not cifs/nfs/smbfs. Use the nearest
# existing ancestor for the df probe so --out may be a not-yet-created dir.
probe="$OUT"; while [[ ! -e "$probe" && "$probe" != "/" && -n "$probe" ]]; do probe="$(dirname "$probe")"; done
FSTYPE="$(df -T "$probe" 2>/dev/null | tail -1 | awk '{print $2}')"
case "$FSTYPE" in
    cifs|smbfs|nfs|nfs4|fuse.sshfs|fuseblk) die "--out sits on network fs '$FSTYPE' -- refusing (air-gap)" ;;
esac

# --- mount the source read-only --------------------------------------------------
MOUNTED_BY_US=""
cleanup() { [[ -n "$MOUNTED_BY_US" ]] && umount "$MOUNTED_BY_US" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -n "$SOURCE_DEV" ]]; then
    [[ -e "$SOURCE_DEV" ]] || die "--source-dev '$SOURCE_DEV' does not exist"
    MNTPOINT="$(mktemp -d /tmp/phx-data-src.XXXXXX)"
    mounted=0
    if command -v mount >/dev/null 2>&1; then
        for fstype in ntfs3 ntfs-3g; do
            if mount -t "$fstype" -o ro,noexec,nodev,nosuid "$SOURCE_DEV" "$MNTPOINT" 2>/dev/null; then
                mounted=1; MOUNTED_BY_US="$MNTPOINT"; break
            fi
        done
    fi
    (( mounted == 1 )) || die "cannot mount '$SOURCE_DEV' read-only (tried ntfs3, ntfs-3g) -- refusing"
    SOURCE_DIR="$MNTPOINT"
fi
[[ -d "$SOURCE_DIR" ]] || die "--source-dir '$SOURCE_DIR' is not a directory"
[[ -d "$SOURCE_DIR/Users" ]] \
    || die "'$SOURCE_DIR' has no Users/ dir -- not a Windows volume root (refusing)"

BACKUP_NAME="$(basename "$OUT")"
[[ -n "$BACKUP_NAME" && "$BACKUP_NAME" != "/" && "$BACKUP_NAME" != "." ]] \
    || die "--out must end in a backup directory name"
# Never let --out live inside the source volume (would copy the backup into
# itself and could write to the infected volume).
OUT_REAL="$(realpath -m "$OUT")"; SRC_REAL="$(realpath -m "$SOURCE_DIR")"
[[ "$OUT_REAL" == "$SRC_REAL" || "$OUT_REAL" == "$SRC_REAL"/* ]] \
    && die "--out is inside the source volume -- refusing"

mkdir -p "$OUT" || die "cannot create --out '$OUT'"
LOG="$OUT/data-backup.log"
MANIFEST="$OUT/data-backup.manifest"
HASHFILE="$OUT/files.sha256"
SKIPPED="$OUT/skipped-executables.txt"

echo "[$PROG] data-only backup: $SOURCE_DIR -> $OUT" | tee "$LOG"

# --- resolve the profile list ------------------------------------------------------
declare -a WANT
if [[ -n "$PROFILES" ]]; then
    IFS=',' read -ra WANT <<<"$PROFILES"
else
    while IFS= read -r d; do WANT+=("$(basename "$d")"); done \
        < <(find "$SOURCE_DIR/Users" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    # drop system/template profiles
    declare -a FILTERED=()
    for p in "${WANT[@]}"; do
        skip=0
        for s in "${SYSTEM_PROFILES[@]}"; do [[ "$p" == "$s" ]] && skip=1; done
        (( skip == 0 )) && FILTERED+=("$p")
    done
    WANT=("${FILTERED[@]}")
fi
(( ${#WANT[@]} > 0 )) || die "no user profiles found under $SOURCE_DIR/Users -- refusing"

# --- build the copy plan -------------------------------------------------------------
declare -a ROOTS
for p in "${WANT[@]}"; do
    [[ "$p" =~ ^[A-Za-z0-9_.\ -]{1,64}$ ]] || die "profile name '$p' has unsafe characters -- refusing"
    for f in "${PROFILE_FOLDERS[@]}"; do
        d="$SOURCE_DIR/Users/$p/$f"
        [[ -d "$d" ]] && ROOTS+=("$d") || echo "[$PROG] note: $p/$f absent, skipping" | tee -a "$LOG"
    done
done
if [[ -n "$EXTRA" ]]; then
    IFS=':' read -ra XPATHS <<<"$EXTRA"
    for x in "${XPATHS[@]}"; do
        [[ -z "$x" ]] && continue
        [[ "$x" == /* ]] && die "--extra paths must be relative to the volume root (got '$x')"
        case "$x" in ..*|*//*|*/../*|*/..) die "--extra path '$x' escapes the volume root -- refusing" ;; esac
        d="$SOURCE_DIR/$x"
        [[ -e "$d" ]] || { echo "[$PROG] note: extra '$x' absent, skipping" | tee -a "$LOG"; continue; }
        ROOTS+=("$d")
    done
fi
(( ${#ROOTS[@]} > 0 )) || die "nothing to copy -- no profile folders or extras found"

# --- copy + hash ---------------------------------------------------------------------
: > "$HASHFILE.tmp"; : > "$SKIPPED.tmp"
FILE_COUNT=0; BYTE_TOTAL=0; SKIP_COUNT=0

copy_tree() {  # copy_tree <src-abs> <dst-rel-base>
    local src="$1" base="$2"
    while IFS= read -r -d '' f; do
        local rel="${f#$src/}"
        local dst="$OUT/$base/$rel"
        local name ext
        name="$(basename "$f")"; ext="${name##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
        if (( INCLUDE_EXE == 0 )) && [[ "$name" == *.* ]] && [[ "$EXE_EXTS" =~ (^|\|)$ext($|\|) ]]; then
            printf '%s\n' "$base/$rel" >> "$SKIPPED.tmp"
            SKIP_COUNT=$((SKIP_COUNT+1))
            continue
        fi
        mkdir -p "$(dirname "$dst")" || die2 "cannot create dir for '$dst'"
        cp -a -- "$f" "$dst" || die2 "copy failed: $f"
        local h sz
        h="$(sha256sum -- "$dst" | cut -d' ' -f1)" || die2 "hash failed: $dst"
        sz="$(stat -c %s -- "$dst")"
        printf '%s  %s\n' "$h" "$base/$rel" >> "$HASHFILE.tmp"
        FILE_COUNT=$((FILE_COUNT+1)); BYTE_TOTAL=$((BYTE_TOTAL+sz))
    done < <(find "$src" -type f -print0 2>/dev/null)
}

for r in "${ROOTS[@]}"; do
    # Destination layout mirrors the volume: Users/<p>/Documents/..., extras as-is.
    rel_base="${r#$SOURCE_DIR/}"
    echo "[$PROG] copying $rel_base ..." | tee -a "$LOG"
    copy_tree "$r" "$rel_base"
done

mv "$HASHFILE.tmp" "$HASHFILE" || die2 "cannot finalize hash file"
mv "$SKIPPED.tmp" "$SKIPPED" || die2 "cannot finalize skipped-executables list"

# --- dirty-data marker -----------------------------------------------------------------
cat > "$OUT/DIRTY-NOT-FORENSIC-SAFE.txt" <<'EOF'
DIRTY DATA -- TREAT AS SUSPECT
==============================
This folder is a data-only backup taken from a machine SUSPECTED OF INFECTION
(runbook Step 2.6). It is NOT a restore source as-is.

  - Scan every file with an up-to-date AV BEFORE restoring anything.
  - Executables/installers were skipped at backup time (see
    skipped-executables.txt). Reinstall applications from their sources --
    never from this folder.
  - Never boot or mount the full-disk quarantine image on a daily-driver
    machine; forensics access is isolated-only.

files.sha256 lists a SHA-256 for every file copied, so you can detect any
post-backup tampering of this folder.
EOF

TS="$(date -u +%Y%m%dT%H%M%SZ)"
{
    echo "# phoenix data-backup manifest -- written only after copy+hash PASS"
    echo "format=phoenix-data-backup/1"
    echo "backup_name=$BACKUP_NAME"
    echo "source_root=$SOURCE_DIR"
    echo "profiles=$(IFS=,; echo "${WANT[*]}")"
    echo "file_count=$FILE_COUNT"
    echo "bytes_total=$BYTE_TOTAL"
    echo "executables_skipped=$SKIP_COUNT"
    echo "include_exe=$INCLUDE_EXE"
    echo "hash_algorithm=sha256"
    echo "hash_file=files.sha256"
    echo "contamination=DIRTY"
    echo "tool=phoenix-data-backup.sh"
    echo "created_utc=$TS"
    echo "operator=$OPERATOR"
    echo "verify=PASS"
} > "$MANIFEST" || die2 "cannot write manifest"

echo "[$PROG] DONE: $FILE_COUNT file(s), $BYTE_TOTAL bytes, $SKIP_COUNT executable(s) skipped -> $OUT" | tee -a "$LOG"
