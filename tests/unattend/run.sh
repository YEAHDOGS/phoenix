#!/usr/bin/env bash
#===============================================================================
# run.sh -- run every unattend/app-picker regression test
# Usage: bash tests/unattend/run.sh   (exit 0 = all green)
#===============================================================================
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
run() {
    echo "--- $1"
    if bash "$D/$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "SUITE FAILED: $1"; fi
}
run test-ps1-py-parity.sh
run test-install-plan.sh
echo "--- test-generate-unattend.py"
if python3 "$D/test-generate-unattend.py"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "SUITE FAILED: test-generate-unattend.py"; fi
echo "--- test-apps-manifest.py"
if python3 "$D/test-apps-manifest.py"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "SUITE FAILED: test-apps-manifest.py"; fi
echo ""
echo "suites green: $PASS  failed: $FAIL"
(( FAIL == 0 ))
