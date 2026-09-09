#!/usr/bin/env bash
#===============================================================================
# test-app-picker.sh -- regression suite for the Phoenix app picker pair:
#   data/choco-install/apps.json   (the picker catalog)
#   tools/New-AppInstallScript.ps1 (the setup-time installer generator)
#
# The generator needs PowerShell; this Linux-portable suite validates the
# catalog schema, the generator's fail-closed guards, and the structure of
# the emitted script template (idempotent, logged, never blocks OOBE).
#
# Usage: bash tests/tools/test-app-picker.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CAT="$REPO/data/choco-install/apps.json"
GEN="$REPO/tools/New-AppInstallScript.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

if [[ ! -f "$CAT" ]]; then fail "catalog exists: $CAT"; else
  COUNT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d, list); print(len(d))" "$CAT" 2>/dev/null || echo 0)
  if (( COUNT >= 80 )); then
    pass "catalog parses as JSON array: $COUNT entries (>= 80)"
  else
    fail "catalog parses as JSON array" "got $COUNT"
  fi
fi

# --- catalog schema ---------------------------------------------------------
python3 - "$CAT" <<'EOF' > /tmp/phx_apppicker.json.$$ 2>/dev/null
import json, sys, re
d = json.load(open(sys.argv[1]))
errs = []
name_re = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
for i, e in enumerate(d):
    if not isinstance(e, dict): errs.append(f"entry {i} not an object"); continue
    for k in ("package", "description", "category"):
        if k not in e or not str(e[k]).strip(): errs.append(f"entry {i} missing/empty '{k}'")
    if "defaultSelected" in e and not isinstance(e["defaultSelected"], bool):
        errs.append(f"{e.get('package')}: defaultSelected not a bool")
    if e.get("source") == "manual" and not e.get("note"):
        errs.append(f"{e.get('package')}: manual source without note")
names = [e.get("package") for e in d if isinstance(e, dict)]
if len(names) != len(set(names)): errs.append("duplicate package names")
for n in names:
    if n and not name_re.match(n): errs.append(f"bad package name: {n}")
man = [e for e in d if e.get("source") == "manual"]
print("ERRS:" + ("NONE" if not errs else "; ".join(errs)))
print("DEFAULTS:" + str(sum(1 for e in d if isinstance(e, dict) and e.get("defaultSelected") is True)))
print("MANUAL:" + ",".join(e["package"] for e in man))
EOF
ERRS=$(grep '^ERRS:' /tmp/phx_apppicker.json.$$ | cut -c6- || echo NONE)
if [[ "$ERRS" == "NONE" ]]; then pass "catalog schema: objects, required fields, bool flags, unique names, manual entries carry notes"
else fail "catalog schema" "$ERRS"; fi
DEFAULTS=$(grep '^DEFAULTS:' /tmp/phx_apppicker.json.$$ | cut -c10-)
if (( DEFAULTS >= 30 )); then pass "catalog defaults: $DEFAULTS defaultSelected"
else fail "catalog defaults sanity" "only $DEFAULTS defaultSelected"; fi
rm -f /tmp/phx_apppicker.json.$$

# --- generator fail-closed guards (structural, PowerShell-free) ---------------
need() { if grep -qF "$2" "$GEN"; then pass "$1"; else fail "$1" "missing: $2"; fi; }
need "generator: mutual-exclusion guard (-Packages xor -UseDefaults)" "Use either -Packages or -UseDefaults"
need "generator: rejects suspicious package names" "Suspicious package name rejected"
need "generator: fails cleanly on empty selection" "No packages selected; nothing to emit"
need "generator: skips manual-source entries with a warning" "Skipping '"
need "generator: air-gap source override (-ChocoSource)" "ChocoSource"
need "generator: emitted script is idempotent" "already installed; skipping"
need "generator: emitted script logs everything" "Phoenix\Logs\app-install.log"
need "generator: emitted script never blocks OOBE (always exit 0)" "exit 0"

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
