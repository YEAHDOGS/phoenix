#!/usr/bin/env bash
#===============================================================================
# compare.sh -- Phoenix manifest integrity verifier (Linux side)
#
# Bash twin of scripts/checksum/compare.ps1's Confirm-Integrity. Re-hashes every
# file listed in a check.sh/check.ps1 manifest CSV and reports per-file status.
#
# USAGE:
#   compare.sh <manifest.csv>
#
# Exit 0 = every file VERIFIED. Exit 1 = any MISMATCH or MISSING file.
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"

[[ $# -eq 1 ]] || { echo "usage: $PROG <manifest.csv>" >&2; exit 2; }
MANIFEST="$1"
[[ -f "$MANIFEST" ]] || { echo "[$PROG] not found: $MANIFEST" >&2; exit 1; }

python3 - "$MANIFEST" <<'PY'
import csv, hashlib, os, sys

manifest = sys.argv[1]
bad = 0
total = 0
with open(manifest, newline="") as f:
    for row in csv.DictReader(f):
        path, expected = row["Path"], row["Hash"]
        total += 1
        if not os.path.isfile(path):
            print(f"MISSING : {path}")
            bad += 1
            continue
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        got = h.hexdigest()
        if got.lower() == expected.lower():
            print(f"VERIFIED: {path}")
        else:
            print(f"MISMATCH: {path}")
            print(f"  expected: {expected}")
            print(f"  found   : {got}")
            bad += 1

print(f"-- {total - bad}/{total} verified --")
sys.exit(1 if bad else 0)
PY
