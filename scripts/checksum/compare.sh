#!/usr/bin/env bash
# =============================================================================
# compare.sh — Bash twin of compare.ps1 / Confirm-Integrity (Phoenix)
#
# Verifies a stored baseline CSV against live hashes. The CSV must have a
# header row containing "Path" and "Hash" columns (any order), e.g.:
#
#   Path,Hash
#   /srv/iso/win11.iso,9F2A...C41D
#   "C:\path,with,commas\file.bin",AB12...EF34
#
# For each entry, the sibling check.sh (--hash-only) recomputes the live hash
# and it is compared case-insensitively (PowerShell -ne is case-insensitive).
# Prints "Verified:" (green) or "ALERT: Hash mismatch" (red) per entry, then a
# summary. Exits non-zero if any entry mismatches or is unreadable.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

usage() { echo "Usage: $(basename "$0") <baseline.csv>"; exit 1; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; }
[ $# -eq 1 ] || usage

CSV="$1"
if [ ! -f "$CSV" ]; then
    echo "${RED}ERROR: Baseline CSV not found: $CSV${NC}" >&2
    exit 1
fi

# Sibling check.sh lives next to this script (mirrors compare.ps1 calling .\check.ps1)
CHECK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check.sh"
if [ ! -x "$CHECK_SH" ]; then
    echo "${RED}ERROR: Sibling check.sh not found/executable at $CHECK_SH${NC}" >&2
    exit 1
fi

verified=0; alerts=0; skipped=0

# Robust CSV parsing via python3 (system awk is mawk: no FPAT). Emits
# TAB-separated path/hash pairs; header row must contain Path and Hash columns.
ROWS="$(python3 - "$CSV" <<'EOF'
import csv, sys
with open(sys.argv[1], newline='', encoding='utf-8-sig') as fh:
    reader = csv.DictReader((l for l in fh if l.strip()))
    cols = { (k or '').strip().lower(): k for k in (reader.fieldnames or []) }
    if 'path' not in cols or 'hash' not in cols:
        sys.exit("CSV header must contain Path and Hash columns.")
    for row in reader:
        p = (row.get(cols['path']) or '').strip()
        h = (row.get(cols['hash']) or '').strip()
        if p:
            print(p + '\t' + h)
EOF
)"
if [ $? -ne 0 ]; then
    echo "${RED}ERROR: $ROWS${NC}" >&2
    exit 1
fi

while IFS=$'\t' read -r entry_path entry_hash; do
    [ -z "$entry_path" ] && continue

    if ! live="$("$CHECK_SH" --hash-only "$entry_path" 2>/dev/null)"; then
        echo "${YELLOW}SKIP: could not hash $entry_path${NC}"
        skipped=$((skipped+1))
        continue
    fi

    if [ "${live^^}" != "${entry_hash^^}" ]; then
        echo "${RED}ALERT: Hash mismatch for $entry_path!${NC}"
        echo "Expected: $entry_hash"
        echo "Found:    $live"
        alerts=$((alerts+1))
    else
        echo "${GREEN}Verified: $entry_path${NC}"
        verified=$((verified+1))
    fi
done <<< "$ROWS"

echo "----------------------------------------"
echo "Verified: $verified | Alerts: $alerts | Skipped: $skipped"
[ "$alerts" -eq 0 ]
