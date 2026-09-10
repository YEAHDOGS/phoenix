#!/usr/bin/env bash
#===============================================================================
# test-checksum-twins.sh -- regression for scripts/checksum/check.sh + compare.sh
#
# Contract under test: check.sh emits a CSV manifest (Path,Hash) where Hash is
# the SHA-256 of each file; compare.sh re-hashes and must fail closed on any
# tamper or missing file. Exit 0 = all green, 1 = regression.
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$REPO/scripts/checksum/check.sh"
COMPARE="$REPO/scripts/checksum/compare.sh"

PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/sub"
printf 'phoenix checksum fixture' > "$T/src/a.txt"
printf 'nested file' > "$T/src/sub/b.txt"
printf 'comma, in name' > "$T/src/c,d.txt"

#--- single file: hash must equal sha256sum ------------------------------------
expected="$(sha256sum "$T/src/a.txt" | cut -d' ' -f1)"
got="$("$CHECK" "$T/src/a.txt" | tail -1 | cut -d',' -f2 | tr -d '\r')"
[[ "$got" == "$expected" ]] \
    && pass "single-file hash matches sha256sum" \
    || fail "single-file hash matches sha256sum" "got=$got expected=$expected"

#--- directory walk: 3 rows, deterministic order --------------------------------
"$CHECK" "$T/src" --out "$T/manifest.csv" >/dev/null
rows=$(($(wc -l < "$T/manifest.csv") - 1))
[[ "$rows" -eq 3 ]] \
    && pass "directory walk emits 3 data rows" \
    || fail "directory walk emits 3 data rows" "rows=$rows"
second="$("$CHECK" "$T/src" | python3 -c 'import csv,sys; [print(r["Path"]) for r in csv.DictReader(sys.stdin)]')"
[[ "$second" == "$(printf '%s\n' "$second" | LC_ALL=C sort)" ]] \
    && pass "manifest rows are deterministically sorted" \
    || fail "manifest rows are deterministically sorted"

#--- comma in filename survives CSV round-trip ---------------------------------
"$COMPARE" "$T/manifest.csv" >/dev/null \
    && pass "manifest with comma-filename verifies" \
    || fail "manifest with comma-filename verifies"

#--- clean compare is green -----------------------------------------------------
out="$("$COMPARE" "$T/manifest.csv")"
[[ "$out" == *"-- 3/3 verified --"* ]] \
    && pass "clean compare reports 3/3 verified" \
    || fail "clean compare reports 3/3 verified" "out=$out"

#--- tamper is caught, exit 1, names the file ----------------------------------
printf 'tampered' >> "$T/src/sub/b.txt"
out="$("$COMPARE" "$T/manifest.csv" 2>&1)"; code=$?
[[ $code -eq 1 && "$out" == *"MISMATCH: $T/src/sub/b.txt"* ]] \
    && pass "tampered file -> exit 1 + MISMATCH" \
    || fail "tampered file -> exit 1 + MISMATCH" "code=$code out=$out"

#--- missing file is caught ------------------------------------------------------
rm "$T/src/a.txt"
out="$("$COMPARE" "$T/manifest.csv" 2>&1)"; code=$?
[[ $code -eq 1 && "$out" == *"MISSING : $T/src/a.txt"* ]] \
    && pass "deleted file -> exit 1 + MISSING" \
    || fail "deleted file -> exit 1 + MISSING" "code=$code out=$out"

#--- missing path fails ----------------------------------------------------------
"$CHECK" "$T/does-not-exist" >/dev/null 2>&1; code=$?
[[ $code -eq 1 ]] \
    && pass "missing path -> exit 1" \
    || fail "missing path -> exit 1" "code=$code"

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "Checksum twins regression green."
