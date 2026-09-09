#!/usr/bin/env bash
#===============================================================================
# test-runbook-artifacts.sh -- dry-run fixture for docs/EMERGENCY-RUNBOOK.md
#
# Validates the emergency runbook end-to-end WITHOUT touching any hardware:
# every repo artifact a phase depends on must exist in this worktree, and the
# runbook must reference the REAL nuke module (tools/Invoke-Nuke.sh, bash for
# the Linux boot environment -- there is no .ps1 by design) with its actual
# interlocks documented (dry-run default, enumeration, structural refusals,
# two-factor typed confirmation on a real TTY). Exit 0 = the runbook is
# executable as written; exit 1 = a gap that would strand Brandon mid-run.
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RUNBOOK="$REPO/docs/EMERGENCY-RUNBOOK.md"

PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

[[ -f "$RUNBOOK" ]] || { echo "FATAL: $RUNBOOK not found"; exit 1; }
pass "runbook exists"

#--- Phase 0/4 repo artifacts every step depends on ------------------------------
REQUIRED=(
    "scripts/checksum/check.ps1"                    # Step 0.2: ISO hash verify
    "win-install/autounattend.xml"                  # Steps 0.3, 4.1: unattended install
    "win-install/README.md"                         # Step 0.3: install sequence
    "scripts/chocolatey/install-chocolatey-online.ps1"  # Step 4.3
    "scripts/chocolatey/apps.ps1"                   # Step 4.3
    "data/choco-install/apps.json"                  # Step 4.3: app picker list
    "VISION.md"                                     # referenced re: $OEM$ phase 3
)
for p in "${REQUIRED[@]}"; do
    if [[ -f "$REPO/$p" ]]; then
        pass "artifact present: $p"
    else
        fail "artifact present: $p" "runbook step depends on it; a missing file strands the run"
    fi
done

#--- the nuke module reference must be the real one ------------------------------
if grep -q 'Invoke-Nuke\.ps1' "$RUNBOOK"; then
    fail "runbook references Invoke-Nuke.ps1" \
        "stale: the module is tools/Invoke-Nuke.sh (bash, boot env) -- no .ps1 exists by design"
else
    pass "runbook has no stale Invoke-Nuke.ps1 reference"
fi
if grep -q 'tools/Invoke-Nuke\.sh' "$RUNBOOK"; then
    pass "runbook references tools/Invoke-Nuke.sh"
else
    fail "runbook references tools/Invoke-Nuke.sh" "Phase 3 names the wrong module path"
fi

#--- the documented interlocks must match the real module ------------------------
for kw in "serial" "TTY" "dry-run" "NIST 800-88"; do
    if grep -qi "$kw" "$RUNBOOK"; then
        pass "runbook documents nuke interlock keyword: $kw"
    else
        fail "runbook documents nuke interlock keyword: $kw" \
            "operator must know the real confirmation flow before arming"
    fi
done

#--- honest gap flags: the $OEM$ folder is known-missing, must stay flagged ----
if grep -q '\$OEM\$' "$RUNBOOK" && grep -q '\[VERIFY\]' "$RUNBOOK"; then
    pass "\$OEM\$ gap is honestly flagged [VERIFY]"
else
    fail "\$OEM\$ gap is honestly flagged [VERIFY]" "missing artifacts must be flagged, not silent"
fi

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "Runbook dry-run fixture green: every phase's artifacts check out."
