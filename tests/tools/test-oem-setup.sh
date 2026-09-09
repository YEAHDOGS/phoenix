#!/usr/bin/env bash
# Regression suite: Phoenix $OEM$ unattended post-install hooks.
#
# Asserts:
#   - oem/$OEM$/$$/Setup/Scripts/{Specialize,DefaultUser,FirstLogon}.ps1 exist
#   - filenames match what win-install/autounattend.xml invokes
#   - OOBE-safety: scripts never fail setup (exit 0, guarded steps)
#   - air-gap: Specialize/DefaultUser make zero network calls;
#     FirstLogon only networks under explicit -AllowOnline opt-in
#   - no credentials / machine-specific paths committed
#   - the USB stagers copy the $OEM$ tree (fail-closed if missing)
#
# Static analysis only -- no pwsh on this box; PowerShell parse checks happen
# on the Windows test path (docs/NUKE-TEST-PLAN.md).

set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OEM="$REPO/oem/\$OEM\$/\$\$/Setup/Scripts"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- 1. required files exist -------------------------------------------------
for f in Specialize.ps1 DefaultUser.ps1 FirstLogon.ps1; do
    if [ -f "$OEM/$f" ]; then ok "oem tree contains $f"; else bad "oem tree missing $f"; fi
done
[ -f "$REPO/oem/README.md" ] && ok "oem/README.md exists" || bad "oem/README.md missing"

# --- 2. filenames match the answer file's invocations ------------------------
for f in Specialize.ps1 DefaultUser.ps1 FirstLogon.ps1; do
    if grep -Fq "C:\\Windows\\Setup\\Scripts\\$f" "$REPO/win-install/autounattend.xml"; then
        ok "autounattend.xml invokes $f"
    else
        bad "autounattend.xml does not invoke $f (rename drift?)"
    fi
done

# --- 3. OOBE safety: always exit 0, never bare-throw out ----------------------
for f in Specialize.ps1 DefaultUser.ps1 FirstLogon.ps1; do
    p="$OEM/$f"
    [ -f "$p" ] || continue
    if grep -Eq '^[[:space:]]*exit 0[[:space:]]*$' "$p"; then
        ok "$f ends with explicit 'exit 0'"
    else
        bad "$f missing terminal 'exit 0' (OOBE must never fail)"
    fi
    if grep -Eq '\$ErrorActionPreference *= *"Stop"' "$p"; then
        bad "$f sets ErrorActionPreference=Stop (unguarded throw can fail setup)"
    else
        ok "$f does not set ErrorActionPreference=Stop"
    fi
    if grep -Eq '^[[:space:]]*throw[[:space:]]' "$p"; then
        bad "$f contains a bare 'throw' at statement start (unguarded)"
    else
        ok "$f has no bare top-level throw"
    fi
done

# --- 4. air-gap: no network calls in Specialize/DefaultUser -------------------
NETCALLS='Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|Net\.WebClient|curl|wget'
for f in Specialize.ps1 DefaultUser.ps1; do
    p="$OEM/$f"
    [ -f "$p" ] || continue
    if grep -Ei "$NETCALLS" "$p" >/dev/null; then
        bad "$f contains a network call (air-gap violation)"
    else
        ok "$f makes no network calls"
    fi
done
# FirstLogon may only network behind the explicit opt-in flag.
p="$OEM/FirstLogon.ps1"
if [ -f "$p" ]; then
    if grep -Fq "AllowOnline" "$p"; then
        ok "FirstLogon gates any online path behind -AllowOnline"
    else
        bad "FirstLogon missing -AllowOnline opt-in gate"
    fi
fi

# --- 5. hygiene: no credentials, no Brandon-specific paths -------------------
SECRETS='password[[:space:]]*=|passwd|api[_-]?key|secret[[:space:]]*=|bearer[[:space:]]'
PERSONAL='[Cc]:\\Users\\[Bb]rando|[Cc]:\\Users\\brandowellacruz'
for f in Specialize.ps1 DefaultUser.ps1 FirstLogon.ps1; do
    p="$OEM/$f"
    [ -f "$p" ] || continue
    if grep -Ei "$SECRETS" "$p" >/dev/null; then
        bad "$f appears to contain a credential"
    else
        ok "$f has no credential-shaped assignments"
    fi
    if grep -E "$PERSONAL" "$p" >/dev/null; then
        bad "$f hardcodes a personal user path"
    else
        ok "$f has no personal user paths"
    fi
done

# --- 6. DefaultUser touches only the mounted default hive --------------------
p="$OEM/DefaultUser.ps1"
if [ -f "$p" ]; then
    if grep -Eq 'HKU\\\\DefaultUser|HKUDef' "$p"; then
        ok "DefaultUser.ps1 targets the mounted default hive"
    else
        bad "DefaultUser.ps1 does not reference HKU\\DefaultUser"
    fi
    if grep -Eq 'HKLM|HKEY_LOCAL_MACHINE' "$p"; then
        bad "DefaultUser.ps1 touches HKLM (out of scope for the default-profile hook)"
    else
        ok "DefaultUser.ps1 leaves HKLM alone"
    fi
fi

# --- 7. marker contract: each script writes its run marker -------------------
for pair in "Specialize.ps1:specialize.done" "DefaultUser.ps1" "FirstLogon.ps1:firstlogon.done"; do
    f="${pair%%:*}"; m="${pair##*:}"
    p="$OEM/$f"; [ -f "$p" ] || continue
    if [ "$f" = "DefaultUser.ps1" ]; then
        ok "DefaultUser.ps1 exempt from marker contract (logs to DefaultUser.log)"
    elif grep -Fq "$m" "$p"; then
        ok "$f writes run marker $m"
    else
        bad "$f does not write run marker $m"
    fi
done

# --- 8. stagers copy the $OEM$ tree -------------------------------------------
if grep -Fq '$OEM$' "$REPO/tools/Build-PhoenixUsb.ps1"; then
    ok "Build-PhoenixUsb.ps1 stages the \$OEM\$ tree"
else
    bad "Build-PhoenixUsb.ps1 does not stage the \$OEM\$ tree"
fi
if grep -Fq '$OEM$' "$REPO/tools/Build-PhoenixUsb.sh"; then
    ok "Build-PhoenixUsb.sh stages the \$OEM\$ tree"
else
    bad "Build-PhoenixUsb.sh does not stage the \$OEM\$ tree"
fi

# --- 9. PHOENIX-OEM provenance marker -----------------------------------------
for f in Specialize.ps1 DefaultUser.ps1 FirstLogon.ps1; do
    p="$OEM/$f"; [ -f "$p" ] || continue
    if grep -Fq "PHOENIX-OEM" "$p"; then ok "$f carries PHOENIX-OEM marker"; else bad "$f missing PHOENIX-OEM marker"; fi
done

echo ""
echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All \$OEM\$ hook regression tests green." || echo "REGRESSIONS FOUND."
exit "$FAIL"
