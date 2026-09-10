#!/usr/bin/env bash
#===============================================================================
# check.sh -- Phoenix SHA-256 file/folder hasher (Linux side)
#
# Bash twin of scripts/checksum/check.ps1 (Windows side). Both twins emit the
# same CSV contract so manifests are interchangeable:
#
#     Path,Hash
#     "/mnt/usb/laptop-fulldisk-2026-09-09/image.part1",3f2a...
#
# Hash algorithm: SHA-256 on BOTH twins (matches what Microsoft publishes for
# Windows 11 ISOs, and what sha256sum computes natively).
#
# USAGE:
#   check.sh <path>                 print manifest CSV to stdout
#   check.sh <path> --out FILE.csv  write manifest CSV to FILE.csv
#
# Exit 0 = all files hashed. Exit 1 = path missing/unreadable.
# No network, no installs -- uses sha256sum + python3 (both already on the box).
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
OUT=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PATH_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:?--out needs a file}"; shift 2;;
        --help|-h) usage 0;;
        -*) echo "[$PROG] unknown flag: $1" >&2; exit 2;;
        *) if [[ -n "$PATH_ARG" ]]; then echo "[$PROG] only one path argument" >&2; exit 2; fi
           PATH_ARG="$1"; shift;;
    esac
done

[[ -z "$PATH_ARG" ]] && { echo "[$PROG] missing path argument" >&2; usage 2; }
[[ -e "$PATH_ARG" ]] || { echo "[$PROG] not found: $PATH_ARG" >&2; exit 1; }

# --- collect absolute file list ------------------------------------------------
declare -a FILES=()
if [[ -f "$PATH_ARG" ]]; then
    FILES=("$PATH_ARG")
elif [[ -d "$PATH_ARG" ]]; then
    while IFS= read -r -d '' f; do FILES+=("$f"); done \
        < <(find "$PATH_ARG" -type f -print0 | LC_ALL=C sort -z)
    (( ${#FILES[@]} > 0 )) || { echo "[$PROG] WARNING: directory is empty: $PATH_ARG" >&2; exit 1; }
else
    echo "[$PROG] not a file or directory: $PATH_ARG" >&2; exit 1
fi

# --- hash every file, emit CSV -------------------------------------------------
# python3 does the CSV writing so commas/quotes in paths can't corrupt the
# manifest (the .ps1 twin reads the same file via Import-Csv).
emit_csv() {
    local pyfile
    pyfile="$(mktemp)"
    cat > "$pyfile" <<'PY'
import csv, hashlib, sys
w = csv.writer(sys.stdout)
w.writerow(["Path", "Hash"])
for path in sys.argv[1:]:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    w.writerow([path, h.hexdigest()])
PY
    python3 "$pyfile" "${FILES[@]}"
    rm -f "$pyfile"
}

if [[ -n "$OUT" ]]; then
    emit_csv > "$OUT"
    echo "[$PROG] manifest written: $OUT (${#FILES[@]} file(s))"
else
    emit_csv
fi
