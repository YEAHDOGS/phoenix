#!/usr/bin/env bash
#===============================================================================
# test-phoenix-menu.sh -- regression harness for the Phoenix menu pair:
#   tools/phoenix-menu.sh       (Linux rescue side)
#   tools/Invoke-PhoenixMenu.ps1 (WinPE side, contract parity with the .sh)
#
# The menu is never destructive: it prints guidance and dispatches. The
# suite covers the headless phoenix-config.json read (no jq), the choice
# handlers, the Nuke dispatch path (TESTMODE hook + fail-closed missing
# tool), the password redaction guarantee, and static parity of the .ps1
# (pwsh is not installed here, so the .ps1 is checked structurally --
# same convention as the other suites).
#
# Coverage:
#   - bash -n syntax on the .sh; .ps1 exists with the same -Config/-Choice
#     params, -- arg split, Choice-* handler functions, TESTMODE hook,
#     $PSScriptRoot-relative nuke tool, and no .credentials reads.
#   - config discovery: explicit --config parses schemaVersion/computerName/
#     os.family; malformed JSON warns but continues; no config on the
#     machine warns (unconfigured mode) and still exits 0.
#   - REDACTION: a config containing credentials.password is parsed but
#     the password value NEVER appears in menu output (banner or choices).
#   - choices 1/2/4/q print their sections and exit 0; unknown choice
#     exits 1; bad flag exits 1; --help exits 0.
#   - choice 3 in TESTMODE=1 prints the dispatch line (tool path + forwarded
#     args) and never execs; choice 3 with the nuke tool missing fails
#     closed with a clear message.
#   - interactive loop: piped stdin ("q", "1 then q") works and exits 0.
#   - unit: jget (sourced from the real script, `main` stripped) extracts
#     string and numeric scalars, returns empty for absent keys.
#
# Usage: bash tests/tools/test-phoenix-menu.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$REPO/tools/phoenix-menu.sh"
PS1F="$REPO/tools/Invoke-PhoenixMenu.ps1"
T="$(mktemp -d /tmp/phoenix-menu-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- preflight -----------------------------------------------------------------
echo "== preflight =="
[[ -f "$SH" ]] || { echo "FATAL: $SH not found"; exit 1; }
[[ -f "$PS1F" ]] || { echo "FATAL: $PS1F not found"; exit 1; }
bash -n "$SH" && pass "bash -n syntax check (phoenix-menu.sh)" || fail "bash -n syntax check (phoenix-menu.sh)"
for p in /mnt/phoenix-config.json /media/phoenix-config.json /run/media/phoenix-config.json; do
    if [[ -f "$p" ]]; then echo "FATAL: host has $p -- test would not exercise unconfigured mode"; exit 1; fi
done
pass "preflight: no phoenix-config.json on common mounts (unconfigured mode is testable)"

#--- fixture config (contains a fake password -- must never leak) --------------
cat > "$T/fx-config.json" <<'JSON'
{
  "schemaVersion": 2,
  "machine": { "computerName": "TESTBOX-9", "timezone": "Central Standard Time" },
  "credentials": { "username": "brandon", "password": "S3CR3T-PASSWORD-MUST-NOT-LEAK" },
  "os": { "family": "linux", "edition": "Pro", "productKey": null,
          "answerFile": { "disableWPBT": true, "partitionLayout": "gpt-uefi" } },
  "apps": [ { "id": "googlechrome", "source": "choco" } ]
}
JSON

# run_menu always returns 0 (set -e would otherwise kill the harness on the
# expected-failure cases); the real exit code lands in MENU_RC and the
# captured output in $T/out.txt (command substitution would run the
# function in a subshell and lose MENU_RC).
MENU_RC=0
run_menu() { MENU_RC=0; (cd "$T" && bash "$SH" "$@" >"$T/out.txt" 2>&1) || MENU_RC=$?; return 0; }
menu_out() { cat "$T/out.txt"; }
# run_cap: run the menu, capture output into OUT, keep MENU_RC.
OUT=""
run_cap() { run_menu "$@"; OUT="$(menu_out)"; }


#--- basic choice behavior ------------------------------------------------------
echo "== choices =="
run_cap --choice 1 --config "$T/fx-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "--choice 1 exits 0" || fail "--choice 1 exits 0" "rc=$rc"
echo "$out" | grep -q "\[1\] ANALYZE" && pass "choice 1 prints ANALYZE section" || fail "choice 1 prints ANALYZE section"

run_cap --choice 2 --config "$T/fx-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "--choice 2 exits 0" || fail "--choice 2 exits 0" "rc=$rc"
echo "$out" | grep -q "Verified backup or no wipe" && pass "choice 2 prints backup guidance" || fail "choice 2 prints backup guidance"
echo "$out" | grep -q "New-ImageProof" && pass "choice 2 references the image-proof minter" || fail "choice 2 references the image-proof minter"

run_cap --choice 4 --config "$T/fx-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "--choice 4 exits 0" || fail "--choice 4 exits 0" "rc=$rc"
echo "$out" | grep -q "\[4\] REINSTALL" && pass "choice 4 prints REINSTALL section" || fail "choice 4 prints REINSTALL section"
echo "$out" | grep -q "TESTBOX-9" && pass "choice 4 names the configured machine" || fail "choice 4 names the configured machine"

run_cap --choice q --config "$T/fx-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "--choice q exits 0" || fail "--choice q exits 0" "rc=$rc"

run_cap --choice 9 --config "$T/fx-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 1 ]] && pass "unknown choice exits 1" || fail "unknown choice exits 1" "rc=$rc"
echo "$out" | grep -q "unknown choice" && pass "unknown choice message" || fail "unknown choice message"

run_cap --bogus-flag; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 1 ]] && pass "bad flag exits 1" || fail "bad flag exits 1" "rc=$rc"

run_cap --help; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "--help exits 0" || fail "--help exits 0" "rc=$rc"

#--- config discovery + parsing -------------------------------------------------
echo "== config =="
run_cap --choice q --config "$T/fx-config.json"; out="$OUT"
echo "$out" | grep -q "schema 2" && pass "banner shows parsed schemaVersion" || fail "banner shows parsed schemaVersion"
echo "$out" | grep -q "machine: TESTBOX-9" && pass "banner shows parsed computerName" || fail "banner shows parsed computerName"
echo "$out" | grep -q "os.family: linux" && pass "banner shows parsed os.family" || fail "banner shows parsed os.family"
echo "$out" | grep -q "config: $T/fx-config.json" && pass "banner shows which config was used" || fail "banner shows which config was used"

echo '{ not valid json' > "$T/bad-config.json"
run_cap --choice q --config "$T/bad-config.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "malformed config warns but continues (rc=0)" || fail "malformed config warns but continues" "rc=$rc"
echo "$out" | grep -q "does not look like a phoenix-config.json" && pass "malformed config warning" || fail "malformed config warning"

run_cap --choice 9 --config "$T/nope.json"; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 1 ]] && pass "missing --config path is fatal (rc=1)" || fail "missing --config path is fatal" "rc=$rc"

#--- unconfigured mode: this machine has no config on common mounts -------------
run_cap --choice q; out="$OUT"
echo "$out" | grep -q "config: NOT FOUND" && pass "unconfigured mode warns, does not fail" || fail "unconfigured mode warns, does not fail"
echo "$out" | grep -q "\[4\] REINSTALL" || fail "unconfigured mode still shows menu"

#--- redaction: the password must NEVER appear ----------------------------------
echo "== redaction =="
out="$(run_menu --choice 1 --config "$T/fx-config.json"; run_menu --choice 2 --config "$T/fx-config.json"; run_menu --choice 4 --config "$T/fx-config.json")"
if echo "$out" | grep -q "S3CR3T-PASSWORD-MUST-NOT-LEAK"; then
    fail "password never appears in menu output"
else
    pass "password never appears in menu output"
fi
pw_lines="$(grep -n "password" "$SH" || true)"
pw_code="$(echo "$pw_lines" | grep -v '^[0-9]*:.*#' | grep -v 'install-time password' || true)"
if [[ -z "$pw_code" ]]; then
    pass ".sh mentions 'password' in code only as the 'install-time password' doc phrase"
else
    fail ".sh mentions 'password' in code beyond the doc phrase" "$pw_code"
fi
if grep -q "jget.*password" "$SH"; then fail ".sh never jget's the password"; else pass ".sh never jget's the password"; fi

#--- choice 3: dispatch (TESTMODE), missing tool fail-closed ----------------------
echo "== nuke dispatch =="
PHOENIX_MENU_TEST=1 run_cap --choice 3 -- --nuke 2 --log-dir /tmp/x; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "choice 3 TESTMODE exits 0" || fail "choice 3 TESTMODE exits 0" "rc=$rc"
echo "$out" | grep -q "would exec" && pass "choice 3 TESTMODE prints dispatch line" || fail "choice 3 TESTMODE prints dispatch line"
echo "$out" | grep -q "phoenix-nuke.sh --nuke 2 --log-dir /tmp/x" && pass "dispatch line carries forwarded args" || fail "dispatch line carries forwarded args"
echo "$out" | grep -q "NUKE-SAFETY" && pass "choice 3 prints the safety pointer before handoff" || fail "choice 3 prints the safety pointer before handoff"

mkdir -p "$T/lonely" && cp "$SH" "$T/lonely/phoenix-menu.sh"
lonely_rc=0
(cd "$T/lonely" && PHOENIX_MENU_TEST=1 bash phoenix-menu.sh --choice 3 >"$T/out.txt" 2>&1) || lonely_rc=$?
out="$(cat "$T/out.txt")"; rc=$lonely_rc
[[ $rc -eq 1 ]] && pass "missing nuke tool fails closed (rc=1)" || fail "missing nuke tool fails closed" "rc=$rc"
echo "$out" | grep -q "nuke tool not found" && pass "missing nuke tool message" || fail "missing nuke tool message"

#--- interactive loop via piped stdin --------------------------------------------
echo "== interactive loop =="
printf 'q\n' | run_cap; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "piped 'q' quits the loop (rc=0)" || fail "piped 'q' quits the loop" "rc=$rc"
printf '1\nq\n' | run_cap; out="$OUT"
echo "$out" | grep -q "\[1\] ANALYZE" && pass "loop runs a choice then quits" || fail "loop runs a choice then quits"
printf '9\nq\n' | run_cap; out="$OUT"; rc=$MENU_RC
[[ $rc -eq 0 ]] && pass "loop survives a bad choice (rc=0)" || fail "loop survives a bad choice" "rc=$rc"

#--- unit: jget -------------------------------------------------------------------
echo "== unit: jget =="
src="$T/menu-src.sh"
grep -v '^main "$@"$' "$SH" > "$src"
# shellcheck disable=SC1090
source "$src"
[[ "$(jget "$T/fx-config.json" computerName)" == "TESTBOX-9" ]] && pass "jget extracts a string scalar" || fail "jget extracts a string scalar"
[[ "$(jget "$T/fx-config.json" schemaVersion)" == "2" ]] && pass "jget extracts a numeric scalar" || fail "jget extracts a numeric scalar"
[[ "$(jget "$T/fx-config.json" family)" == "linux" ]] && pass "jget extracts nested-key scalar" || fail "jget extracts nested-key scalar"
[[ -z "$(jget "$T/fx-config.json" noSuchKey)" ]] && pass "jget returns empty for absent keys" || fail "jget returns empty for absent keys"
[[ -z "$(jget "$T/nope.json" computerName)" ]] && pass "jget returns empty for missing file" || fail "jget returns empty for missing file"

#--- .ps1 parity (static; pwsh not installed here) --------------------------------
echo "== ps1 parity (static) =="
grep -q '\[string\]$Config' "$PS1F" && pass ".ps1 has -Config param" || fail ".ps1 has -Config param"
grep -q '\[string\]$Choice' "$PS1F" && pass ".ps1 has -Choice param" || fail ".ps1 has -Choice param"
grep -q '"--"' "$PS1F" && pass ".ps1 splits args after bare --" || fail ".ps1 splits args after bare --"
for fn in Choice-Analyze Choice-Backup Choice-Nuke Choice-Reinstall; do
    grep -q "function $fn" "$PS1F" && pass ".ps1 defines $fn" || fail ".ps1 defines $fn"
done
grep -q 'PHOENIX_MENU_TEST' "$PS1F" && pass ".ps1 has the TESTMODE hook" || fail ".ps1 has the TESTMODE hook"
grep -q 'Join-Path $PSScriptRoot "Invoke-PhoenixNuke.ps1"' "$PS1F" && pass ".ps1 dispatches to the nuke tool relative to PSScriptRoot" || fail ".ps1 dispatches to the nuke tool relative to PSScriptRoot"
if grep -n "credentials" "$PS1F" | grep -v '^\s*#' | grep -v '#'; then
    fail ".ps1 never touches .credentials outside comments"
else
    pass ".ps1 never touches .credentials outside comments"
fi
grep -q "schemaVersion" "$PS1F" && grep -q "computerName" "$PS1F" && grep -q "os.family\|os\.family" "$PS1F" \
    && pass ".ps1 parses the same three non-sensitive fields" || fail ".ps1 parses the same three non-sensitive fields"
grep -q "Exit codes: 0 = ok" "$PS1F" && pass ".ps1 documents the same exit-code contract" || fail ".ps1 documents the same exit-code contract"
grep -q "Get-PSDrive" "$PS1F" && pass ".ps1 scans mounted volumes for the config" || fail ".ps1 scans mounted volumes for the config"

#--- summary ----------------------------------------------------------------------
echo ""
echo "== summary =="
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    echo "FAILED:"
    printf '  - %s\n' "${FAILED_CASES[@]}"
    exit 1
fi
echo "ALL GREEN"
