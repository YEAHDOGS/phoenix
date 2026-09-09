#!/usr/bin/env bash
#===============================================================================
# test-phoenix-data-backup.sh -- regression suite for tools/phoenix-data-backup.sh
# (+ structural parity checks for the WinPE twin tools/New-PhoenixDataBackup.ps1)
#
# Builds a fake Windows volume tree in /tmp -- no block devices, no root,
# nothing leaves /tmp. Exit 0 = all green.
#
# Usage: bash tests/tools/test-phoenix-data-backup.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/phoenix-data-backup.sh"
TWIN="$REPO/tools/New-PhoenixDataBackup.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-databackup-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
chmod +x "$TOOL"

run() {  # run <name> <expected-exit> -- <cmd...>: records PASS/FAIL
    local name="$1" want="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == want )); then pass "$name (exit $rc)";
    else fail "$name" "want exit $want, got $rc :: $out"; fi
}

manifest_val() { grep -E "^$2=" "$1" | cut -d= -f2-; }

# --- fixture: fake Windows volume -----------------------------------------------
VOL="$TMP/vol"
mkdir -p "$VOL/Users/brandon/Documents" "$VOL/Users/brandon/Desktop" \
         "$VOL/Users/brandon/Downloads" "$VOL/Users/brandon/.ssh" \
         "$VOL/Users/Public/Documents" "$VOL/Users/brandon/Ableton Projects"
echo "resume text"    > "$VOL/Users/brandon/Documents/resume.txt"
echo "wallet export"  > "$VOL/Users/brandon/Desktop/wallet.txt"
echo "installer"      > "$VOL/Users/brandon/Downloads/setup.exe"
echo "screenshot"     > "$VOL/Users/brandon/Desktop/pic.png"
echo "private key"    > "$VOL/Users/brandon/.ssh/id_ed25519"
echo "loop stems"     > "$VOL/Users/brandon/Ableton Projects/stems.wav"
echo "shared file"    > "$VOL/Users/Public/Documents/shared.txt"
EXPECTED_COUNT=4   # resume, wallet, pic, id_ed25519 -- setup.exe skipped, Public filtered, extras need --extra

B() { "$TOOL" --source-dir "$VOL" --out "$1" --operator tester "${@:2}"; }

# T1: full run succeeds; manifest + hashes + dirty marker land --------------------
OUT1="$TMP/bak1"
run "full data backup exits 0" 0 -- B "$OUT1"
[[ -f "$OUT1/data-backup.manifest" ]] && pass "manifest written" || fail "manifest written"
[[ "$(manifest_val "$OUT1/data-backup.manifest" format)" == "phoenix-data-backup/1" ]] \
    && pass "manifest format tag" || fail "manifest format tag"
[[ "$(manifest_val "$OUT1/data-backup.manifest" verify)" == "PASS" ]] \
    && pass "manifest verify=PASS" || fail "manifest verify=PASS"
[[ "$(manifest_val "$OUT1/data-backup.manifest" contamination)" == "DIRTY" ]] \
    && pass "manifest contamination=DIRTY" || fail "manifest contamination=DIRTY"
[[ "$(manifest_val "$OUT1/data-backup.manifest" file_count)" == "$EXPECTED_COUNT" ]] \
    && pass "file_count=$EXPECTED_COUNT" || fail "file count"
[[ "$(manifest_val "$OUT1/data-backup.manifest" executables_skipped)" == "1" ]] \
    && pass "executables_skipped=1" || fail "executables skipped count"
[[ -f "$OUT1/DIRTY-NOT-FORENSIC-SAFE.txt" ]] \
    && pass "dirty marker file written" || fail "dirty marker file"
grep -q "setup.exe" "$OUT1/skipped-executables.txt" \
    && pass "setup.exe recorded in skipped-executables.txt" || fail "skipped-executables.txt"
[[ ! -e "$OUT1/Users/brandon/Downloads/setup.exe" ]] \
    && pass "setup.exe NOT copied" || fail "setup.exe must be skipped"

# T2: per-file hashes are real ----------------------------------------------------
while read -r h rel; do
    got="$(sha256sum "$OUT1/$rel" | cut -d' ' -f1)"
    [[ "$got" == "$h" ]] && pass "hash OK: $rel" || fail "hash mismatch: $rel"
done < "$OUT1/files.sha256"

# T3: --include-exe copies executables and flips the manifest ---------------------
OUT3="$TMP/bak3"
run "--include-exe exits 0" 0 -- B "$OUT3" --include-exe
[[ -f "$OUT3/Users/brandon/Downloads/setup.exe" ]] \
    && pass "setup.exe copied with --include-exe" || fail "--include-exe copy"
[[ "$(manifest_val "$OUT3/data-backup.manifest" include_exe)" == "1" ]] \
    && pass "manifest include_exe=1" || fail "include_exe manifest flag"

# T4: --profiles selects one profile; --extra adds paths ---------------------------
OUT4="$TMP/bak4"
run "profiles+extra exits 0" 0 -- B "$OUT4" --profiles brandon --extra "Users/brandon/Ableton Projects"
[[ -f "$OUT4/Users/brandon/Ableton Projects/stems.wav" ]] \
    && pass "extra path copied" || fail "extra path copy"
[[ ! -e "$OUT4/Users/Public/Documents/shared.txt" ]] \
    && pass "non-selected profile excluded" || fail "profile selection"

# T4b: Public is a system profile -- excluded by default, includable explicitly ----
OUT4B="$TMP/bak4b"
run "explicit Public profile exits 0" 0 -- B "$OUT4B" --profiles Public
[[ -f "$OUT4B/Users/Public/Documents/shared.txt" ]] \
    && pass "explicit --profiles Public includes it" || fail "explicit Public profile"
[[ ! -e "$OUT4B/Users/brandon/Documents/resume.txt" ]] \
    && pass "brandon excluded when only Public selected" || fail "Public-only profile selection"

# T5: fail-closed cases -------------------------------------------------------------
run "no source fails" 1 -- "$TOOL" --out "$TMP/x" --operator tester
run "non-Windows dir fails" 1 -- "$TOOL" --source-dir "$TMP" --out "$TMP/x" --operator tester
run "--out inside source fails" 1 -- B "$VOL/nested"
run "bad --extra escape fails" 1 -- B "$TMP/x5" --extra "../evil"

# T6: re-run over an existing backup is idempotent ------------------------------------
run "re-run over existing backup exits 0" 0 -- B "$OUT1"
[[ "$(manifest_val "$OUT1/data-backup.manifest" file_count)" == "$EXPECTED_COUNT" ]] \
    && pass "re-run file_count stable" || fail "re-run stability"

# T7: structural parity with the WinPE twin (no pwsh on this box -- grep contract) ---
[[ -f "$TWIN" ]] && pass "WinPE twin exists" || fail "WinPE twin exists"
for key in 'format=phoenix-data-backup/1' 'contamination=DIRTY' 'verify=PASS' \
           'file_count' 'executables_skipped' 'hash_algorithm=sha256' \
           'skipped-executables.txt' 'DIRTY-NOT-FORENSIC-SAFE.txt'; do
    grep -q -- "$key" "$TWIN" && pass "twin carries '$key'" || fail "twin carries '$key'"
done
for flag in '\-Source\b' '\-SourceDir\b' '\-Out\b' '\-Operator\b' '\-Profiles\b' '\-Extra\b' '\-IncludeExe\b'; do
    grep -qE -- "$flag" "$TWIN" && pass "twin exposes '$flag'" || fail "twin exposes '$flag'"
done
grep -q "robocopy" "$TWIN" && pass "twin copies via robocopy" || fail "twin robocopy"
grep -q "Get-FileHash.*SHA256" "$TWIN" && pass "twin hashes SHA-256" || fail "twin SHA-256"
grep -q "'Users'" "$TWIN" && pass "twin validates Users dir" || fail "twin Users validation"

# T8: secrets hygiene -- no credentials baked into tool/test ---------------------------
if grep -rEi '(password|passwd|secret|api[_-]?key|bearer)[[:space:]]*=[[:space:]]*["'\''][^"'\'']+["'\'']' \
        "$TOOL" "$TWIN" "$0" | grep -vi 'no password' >/dev/null; then
    fail "secrets hygiene" "credential-looking assignment found"
else
    pass "secrets hygiene (no credential literals)"
fi

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
