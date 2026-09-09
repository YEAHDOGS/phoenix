#!/usr/bin/env bash
# =============================================================================
# check.sh — Bash twin of check.ps1 (Phoenix checksum tools)
#
# Computes SHA256 metadata for a single file or an aggregate hash for a folder,
# mirroring the PowerShell original's logic:
#   * Single file        -> SHA256 of the file bytes (uppercase hex)
#   * Folder, 1 file     -> treated as that single file
#   * Folder, N files    -> SHA256 (Aggregate): SHA256 over the UTF-8 bytes of
#                           the concatenated per-file hashes, files sorted by
#                           full path for determinism
#   * Empty folder       -> warning + non-zero exit
#   * Missing path       -> error + non-zero exit
#
# Output is "Key: value" lines (Path, Algorithm, Hash, Size_KB, Created,
# LastModified, Owner) matching the .ps1's PSCustomObject fields.
#
# Extra machine flag: --hash-only prints just the hash (used by compare.sh).
# =============================================================================
set -uo pipefail

HASH_ONLY=0
PATH_ARG=""

for arg in "$@"; do
    case "$arg" in
        --hash-only) HASH_ONLY=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--hash-only] <path>"
            exit 0 ;;
        *) PATH_ARG="$arg" ;;
    esac
done

if [ -z "$PATH_ARG" ]; then
    echo "ERROR: A path is required. Usage: $(basename "$0") [--hash-only] <path>" >&2
    exit 1
fi

# Resolve like (Resolve-Path).Path
if ! RESOLVED="$(realpath -m "$PATH_ARG" 2>/dev/null)"; then
    RESOLVED="$PATH_ARG"
fi

if [ ! -e "$RESOLVED" ]; then
    echo "ERROR: The path '$PATH_ARG' does not exist." >&2
    exit 1
fi

# --- helpers ---------------------------------------------------------------
sha256_upper_file() { # $1 = file -> uppercase hex
    sha256sum < "$1" | cut -d' ' -f1 | tr 'a-f' 'A-F'
}

size_kb() { # $1 = bytes -> KB rounded to 2 decimals
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 }'
}

file_created() { # birth time if the FS tracks it, else "Unknown"
    local b
    b="$(stat -c '%w' "$1" 2>/dev/null)"
    if [ -z "$b" ] || [ "$b" = "-" ]; then echo "Unknown"; else echo "$b"; fi
}

file_modified() { stat -c '%y' "$1"; }
file_owner()    { stat -c '%U' "$1"; }

emit_single() { # $1 = file path (hash of THIS file), $2 = display path
    local f="$1" disp="$2"
    local h kb
    h="$(sha256_upper_file "$f")"
    kb="$(size_kb "$(stat -c '%s' "$f")")"
    if [ "$HASH_ONLY" -eq 1 ]; then
        printf '%s\n' "$h"
        return
    fi
    printf 'Path:         %s\n' "$disp"
    printf 'Algorithm:    SHA256\n'
    printf 'Hash:         %s\n' "$h"
    printf 'Size_KB:      %s\n' "$kb"
    printf 'Created:      %s\n' "$(file_created "$f")"
    printf 'LastModified: %s\n' "$(file_modified "$f")"
    printf 'Owner:        %s\n' "$(file_owner "$f")"
}

# --- single file -----------------------------------------------------------
if [ -f "$RESOLVED" ]; then
    emit_single "$RESOLVED" "$RESOLVED"
    exit 0
fi

# --- folder ----------------------------------------------------------------
if [ -d "$RESOLVED" ]; then
    echo "Calculating aggregate metadata for folder: $RESOLVED" >&2

    mapfile -d '' ALL_FILES < <(find "$RESOLVED" -type f -print0 | sort -z)
    if [ "${#ALL_FILES[@]}" -eq 0 ]; then
        echo "WARNING: The folder is empty or contains no files." >&2
        exit 1
    fi

    # Parallel per-file hashing (throttle 8, like the .ps1's -ThrottleLimit 8),
    # then re-sort by full path for deterministic aggregation.
    # TAB separates hash from path (handles spaces in names).
    HASH_LIST="$(printf '%s\0' "${ALL_FILES[@]}" \
        | xargs -0 -P8 -I{} sh -c 'printf "%s\t%s\n" "$(sha256sum < "$1" | cut -d" " -f1 | tr "a-f" "A-F")" "$1"' _ {} \
        | LC_ALL=C sort -t "$(printf '\t')" -k2)"

    FILE_COUNT="$(printf '%s\n' "$HASH_LIST" | wc -l)"

    # PURE LOGIC: 1 file -> treat folder as that file
    if [ "$FILE_COUNT" -eq 1 ]; then
        SINGLE="$(printf '%s\n' "$HASH_LIST" | cut -f2-)"
        emit_single "$SINGLE" "$RESOLVED"
        exit 0
    fi

    # AGGREGATE LOGIC: SHA256 over concatenated sorted per-file hashes
    COMBINED="$(printf '%s\n' "$HASH_LIST" | cut -f1 | tr -d '\n')"
    FINAL_HASH="$(printf '%s' "$COMBINED" | sha256sum | cut -d' ' -f1 | tr 'a-f' 'A-F')"

    TOTAL_BYTES=0
    LATEST=""
    while IFS=$'\t' read -r _h f; do
        TOTAL_BYTES=$((TOTAL_BYTES + $(stat -c '%s' "$f")))
        m="$(stat -c '%y' "$f")"
        if [ -z "$LATEST" ] || [[ "$m" > "$LATEST" ]]; then LATEST="$m"; fi
    done <<< "$HASH_LIST"

    if [ "$HASH_ONLY" -eq 1 ]; then
        printf '%s\n' "$FINAL_HASH"
        exit 0
    fi
    printf 'Path:         %s\n' "$RESOLVED"
    printf 'Algorithm:    SHA256 (Aggregate)\n'
    printf 'Hash:         %s\n' "$FINAL_HASH"
    printf 'Size_KB:      %s\n' "$(size_kb "$TOTAL_BYTES")"
    printf 'Created:      %s\n' "$(file_created "$RESOLVED")"
    printf 'LastModified: %s\n' "$LATEST"
    printf 'Owner:        %s\n' "$(file_owner "$RESOLVED")"
    exit 0
fi

echo "ERROR: The path '$PATH_ARG' is neither a file nor a directory." >&2
exit 1
