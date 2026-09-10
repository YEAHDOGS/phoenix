#!/usr/bin/env bash
#===============================================================================
# New-FileInventory.sh -- Phoenix utility: JSON inventory of a directory tree
#
# Give it a directory (or a single file); it walks the whole tree and writes
# a JSON array with one object per entry:
#
#   { "path": "/abs/path", "type": "file|directory|symlink|other",
#     "size_bytes": 1234, "modified_utc": "2026-09-09T20:30:00Z",
#     "created_utc": "2026-09-01T12:00:00Z" }
#
# Key order, ISO-8601 UTC timestamps, and path sorting are pinned -- the
# PowerShell twin (tools/New-FileInventory.ps1) emits the identical contract
# so inventories are comparable across Windows and Linux.
#
# created_utc is null on Linux: ext4/tmpfs birth time is not exposed through
# os.stat, so "created" is honestly reported as unknown rather than faked
# from ctime (which is change-time, not creation-time).
#
# The walk is best-effort: permission-denied subtrees are skipped, not fatal.
# Files that vanish mid-walk (TOCTOU) are skipped, not fatal.
#
# USAGE:
#   New-FileInventory.sh --path /media/usb-target/laptop-backup [--out inv.json]
#
# Exit codes: 0 = inventory written | 1 = usage/validation error |
#             2 = walk/serialization/write error
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

TARGET=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) TARGET="${2:-}"; shift 2 ;;
        --out)  OUT="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,/^#==*$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[[ -n "$TARGET" ]] || die "--path is required"
[[ -e "$TARGET" ]] || die "not found: $TARGET"

if [[ -z "$OUT" ]]; then
    base="$(basename "$TARGET")"
    [[ -n "$base" && "$base" != "/" ]] || base="root"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    OUT="./${base}-inventory-${stamp}.json"
fi

# --- walk (NUL-delimited) -> JSON via python3 stdlib ---------------------------
# find -print0 breaks on nothing except NUL in a name, which the kernel
# forbids -- so every legal filename round-trips exactly. find on a file
# target prints just the file; on a directory it recurses fully.
# (The NUL list goes through a temp file: a heredoc cannot share stdin with
# a pipe into the same python3 invocation.)
LIST="$(mktemp /tmp/phx-inventory.XXXXXX)"
trap 'rm -f "$LIST"' EXIT
find "$TARGET" -mindepth 0 -print0 2>/dev/null > "$LIST" \
    || { echo "[$PROG] FATAL: directory walk failed" >&2; exit 2; }

COUNT="$(python3 - "$OUT" "$LIST" <<'PYEOF'
import os, sys, json, stat, datetime

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

out_path, list_path = sys.argv[1], sys.argv[2]
entries = []
with open(list_path, 'rb') as lf:
    chunks = lf.read().split(b'\0')
for raw in chunks:
    if not raw:
        continue
    p = os.path.abspath(os.fsdecode(raw))
    try:
        st = os.lstat(p)
    except OSError:
        continue  # vanished mid-walk (TOCTOU); not fatal
    mode = st.st_mode
    if stat.S_ISLNK(mode):
        kind = 'symlink'
    elif stat.S_ISDIR(mode):
        kind = 'directory'
    elif stat.S_ISREG(mode):
        kind = 'file'
    else:
        kind = 'other'
    birth = getattr(st, 'st_birthtime', None)  # macOS/BSD only; None on Linux
    entries.append({
        'path': p,
        'type': kind,
        'size_bytes': st.st_size if kind == 'file' else None,
        'modified_utc': iso(st.st_mtime),
        'created_utc': iso(birth) if birth else None,
    })

entries.sort(key=lambda e: e['path'])
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(entries, f, indent=2, ensure_ascii=False)
    f.write('\n')
print(len(entries))
PYEOF
)" || { echo "[$PROG] FATAL: serialization failed" >&2; exit 2; }

echo "[$PROG] wrote $OUT ($COUNT entries)"
