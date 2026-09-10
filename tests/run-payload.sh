#!/usr/bin/env bash
#===============================================================================
# run-payload.sh -- one harness for the whole unified Phoenix payload line.
#
# Runs every payload test suite (Analyze / Backup / Nuke / Reinstall /
# Restore + the chain-of-custody contract + the config-schema regression +
# the answer-file suites) and reports per-suite pass/fail plus a grand total.
# Exit 0 = everything green; exit 1 = any suite red.
#
# Run from the repo root:  bash tests/run-payload.sh
# Read-only w.r.t. real hardware: every suite mocks disks / uses fixtures.
# The PowerShell twins (.ps1) cannot run on this box -- verified by symmetry
# review only (see docs).
#===============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SUITES=(
    "tests/tools/test-analyze-payload.sh"
    "tests/tools/test-backup-interlocks.sh"
    "tests/tools/test-nuke-interlocks.sh"
    "tests/tools/test-reinstall.sh"
    "tests/tools/test-chain-of-custody.sh"
    "scripts/backup/test-restore.sh"
    "scripts/backup/test-profiles.sh"
    "tests/config/test-schema.sh"
    "tests/tools/test-analyze.sh"
    "tests/tools/test-backup.sh"
    "tests/tools/test-nuke-interlock.sh"
    "tests/tools/test-xml-smoke.sh"
)

grand_pass=0; grand_fail=0; red=0
declare -a red_suites=()

echo "Phoenix payload test line — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"

for suite in "${SUITES[@]}"; do
    path="$REPO_ROOT/$suite"
    out="$(bash "$path" 2>&1)"
    rc=$?
    # Individual result lines are "PASS: <name>" / "ok: <name>" (some suites
    # indent them); "FAIL" at line start is always a real failure. Summary
    # lines like "PASS: 116  FAIL: 0" are subtracted back out.
    p="$(printf '%s\n' "$out" | grep -cE '^\s*(PASS|ok): ')"
    s="$(printf '%s\n' "$out" | grep -cE '^\s*PASS: [0-9]+  FAIL: [0-9]+$')"
    p=$((p - s))
    f="$(printf '%s\n' "$out" | grep -cE '^\s*FAIL')"
    grand_pass=$((grand_pass + p))
    grand_fail=$((grand_fail + f))
    if [[ $rc -ne 0 || $f -ne 0 ]]; then
        echo "RED   $suite  (rc=$rc, $p pass / $f fail)"
        red=1; red_suites+=("$suite")
    else
        echo "GREEN $suite  ($p pass / $f fail)"
    fi
done

# The XML generator e2e is python; run it separately (same contract).
py="tests/tools/test-xml-gen-e2e.py"
out="$(python3 "$REPO_ROOT/$py" 2>&1)"
rc=$?
p="$(printf '%s\n' "$out" | grep -cE '^\s*PASS: ')"
f="$(printf '%s\n' "$out" | grep -cE '^\s*FAIL')"
grand_pass=$((grand_pass + p))
grand_fail=$((grand_fail + f))
if [[ $rc -ne 0 || $f -ne 0 ]]; then
    echo "RED   $py  (rc=$rc, $p pass / $f fail)"
    red=1; red_suites+=("$py")
else
    echo "GREEN $py  ($p pass / $f fail)"
fi

echo "================================================================"
echo "GRAND TOTAL: $grand_pass PASS / $grand_fail FAIL across $(( ${#SUITES[@]} + 1 )) suites"
if [[ $red -ne 0 ]]; then
    echo "RED SUITES: ${red_suites[*]}"
    exit 1
fi
echo "ALL GREEN"
