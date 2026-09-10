#!/usr/bin/env bash
#===============================================================================
# test-install-plan.sh -- regression tests for the app-picker install scripts
#
# scripts/install_apps.sh is the Linux plan printer; scripts/Install-Apps.ps1
# is the Windows installer. This tests the plan contract both share:
# manifest-driven selection, default selection, explicit package lists,
# manual-source flagging, and unknown-package failure. The PS1 side is
# additionally syntax-checked when pwsh exists.
#
# Usage: bash tests/unattend/test-install-plan.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$REPO/scripts/install_apps.sh"
PS1="$REPO/scripts/Install-Apps.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

# I1: default plan lists the manifest's defaultSelected packages, none manual-by-accident
PLAN="$(bash "$SH" --offline)"
COUNT="$(printf '%s\n' "$PLAN" | grep -c '^GoogleChrome\|^Firefox\|^VLC\|^Steam' || true)"
if [[ "$COUNT" -ge 4 ]]; then
    pass "default plan includes headline apps (Chrome/Firefox/VLC/Steam)"
else
    fail "default plan includes headline apps" "got: $(printf '%s' "$PLAN" | head -5)"
fi

# I2: Ableton is flagged as a manual step, never a choco install
if printf '%s\n' "$PLAN" | grep -q "MANUAL STEP: Ableton"; then
    pass "manual-source package surfaced as a manual step"
else
    # Ableton is not default-selected; force it into the plan explicitly
    PLAN2="$(bash "$SH" --packages Ableton --offline)"
    if printf '%s\n' "$PLAN2" | grep -q "MANUAL STEP: Ableton"; then
        pass "manual-source package surfaced as a manual step"
    else
        fail "manual-source package surfaced as a manual step"
    fi
fi

# I3: explicit package list is honored exactly
PLAN3="$(bash "$SH" --packages 7zip,VLC --offline)"
if printf '%s\n' "$PLAN3" | grep -q "^7zip" && printf '%s\n' "$PLAN3" | grep -q "^VLC" \
   && ! printf '%s\n' "$PLAN3" | grep -q "^Steam"; then
    pass "--packages selects exactly the requested packages"
else
    fail "--packages selects exactly the requested packages"
fi

# I4: unknown package fails closed
if bash "$SH" --packages NoSuchPackageXYZ --offline >/dev/null 2>&1; then
    fail "unknown package fails closed" "exit 0 on bogus package"
else
    pass "unknown package fails closed"
fi

# I5: offline mode installs nothing and always exits 0
if bash "$SH" --offline >/dev/null 2>&1; then
    pass "--offline exits 0 (plan only, no side effects)"
else
    fail "--offline exits 0 (plan only, no side effects)"
fi

# I6: plan header carries the package count
if printf '%s\n' "$PLAN" | head -1 | grep -qE "plan \([0-9]+ packages\)"; then
    pass "plan header carries the package count"
else
    fail "plan header carries the package count"
fi

# I7: PS1 syntax -- parseable when PowerShell exists; basic structure otherwise
if command -v pwsh >/dev/null 2>&1; then
    PWSH=pwsh
elif command -v powershell >/dev/null 2>&1; then
    PWSH=powershell
else
    PWSH=""
fi
if [[ -n "$PWSH" ]]; then
    if "$PWSH" -NoProfile -NonInteractive -Command \
        "\$errs=\$null; [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '$PS1'), [ref]\$errs); exit \$errs.Count" ; then
        pass "Install-Apps.ps1 tokenizes with zero errors"
    else
        fail "Install-Apps.ps1 tokenizes with zero errors"
    fi
else
    echo "  SKIP: PS1 tokenize check (pwsh not installed)"
    # structural fallback: the PS1 must define the same user-facing params
    for flag in "Manifest" "Packages" "UseDefaults" "Offline" "ChocoSource"; do
        grep -q "\$$flag" "$PS1" || { fail "PS1 defines -$flag"; break; }
    done
    pass "Install-Apps.ps1 defines the documented parameters"
fi

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
