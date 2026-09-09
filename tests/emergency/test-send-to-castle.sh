#!/usr/bin/env bash
#===============================================================================
# test-send-to-castle.sh -- regression for scripts/emergency/Send-ImageToCastle.sh
#
# Contract under test (runbook Phase 2.6):
#   * piped/non-TTY stdin can NEVER confirm (exit 3) -- the CLEAN-machine
#     confirmation requires a real terminal, same philosophy as the nuke
#     interlock's typed confirmation.
#   * --dry-run fingerprints but writes nothing.
#   * a real run copies and writes image-proof.txt with matching
#     source/copy fingerprints.
#   * re-running into an existing quarantine folder is refused (exit 4).
# Exit 0 = all green, 1 = regression.
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SEND="$REPO/scripts/emergency/Send-ImageToCastle.sh"

PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

command -v script >/dev/null || { echo "FATAL: 'script' (util-linux) needed for pty tests"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/img/sub" "$T/target"
head -c 65536 /dev/urandom > "$T/img/image.part1"
printf 'second part' > "$T/img/sub/image.part2"

#--- 1. piped stdin is refused, even with the right answer -----------------------
code=0
printf 'CLEAN\n' | "$SEND" -i "$T/img" -t "$T/target" >/dev/null 2>&1 || code=$?
[[ $code -eq 3 ]] \
    && pass "piped confirmation refused (exit 3)" \
    || fail "piped confirmation refused (exit 3)" "code=$code"

#--- 2. dry-run writes nothing ----------------------------------------------------
code=0
printf 'CLEAN\n' | script -qec "$SEND -i $T/img -t $T/target --dry-run" /dev/null >/dev/null 2>&1 || code=$?
dest_count=$(find "$T/target" -mindepth 1 | wc -l)
[[ $code -eq 0 && "$dest_count" -eq 0 ]] \
    && pass "dry-run exits 0 and writes nothing" \
    || fail "dry-run exits 0 and writes nothing" "code=$code files=$dest_count"

#--- 3. real run: verified copy + proof file -------------------------------------
code=0
printf 'CLEAN\n' | script -qec "$SEND -i $T/img -t $T/target" /dev/null >/dev/null 2>&1 || code=$?
PROOF="$T/target/QUARANTINE-INFECTED-$(date +%F)/image-proof.txt"
[[ $code -eq 0 && -f "$PROOF" ]] \
    && pass "full run exits 0 and writes image-proof.txt" \
    || fail "full run exits 0 and writes image-proof.txt" "code=$code proof=$PROOF"

src_fp="$(grep '^source_fingerprint=' "$PROOF" | cut -d= -f2)"
cpy_fp="$(grep '^copy_fingerprint=' "$PROOF" | cut -d= -f2)"
[[ -n "$src_fp" && "$src_fp" == "$cpy_fp" ]] \
    && pass "proof fingerprints match (source == copy)" \
    || fail "proof fingerprints match (source == copy)" "src=$src_fp copy=$cpy_fp"

#--- 4. second run into the same label is refused ---------------------------------
code=0
printf 'CLEAN\n' | script -qec "$SEND -i $T/img -t $T/target" /dev/null >/dev/null 2>&1 || code=$?
[[ $code -eq 4 ]] \
    && pass "existing quarantine folder refused (exit 4)" \
    || fail "existing quarantine folder refused (exit 4)" "code=$code"

#--- 5. fingerprint is deterministic across runs ----------------------------------
fp1="$(printf 'CLEAN\n' | script -qec "$SEND -i $T/img -t $T/target --dry-run" /dev/null 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
fp2="$(printf 'CLEAN\n' | script -qec "$SEND -i $T/img -t $T/target --dry-run" /dev/null 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
[[ -n "$fp1" && "$fp1" == "$fp2" ]] \
    && pass "tree fingerprint deterministic across runs" \
    || fail "tree fingerprint deterministic across runs" "fp1=$fp1 fp2=$fp2"

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "Send-to-Castle regression green."
