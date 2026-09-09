#!/usr/bin/env bash
#===============================================================================
# test-app-install-twin.sh -- regression suite for tools/New-AppInstallScript.sh
# (the bash twin of tools/New-AppInstallScript.ps1).
#
# The twin must be a drop-in replacement for the PowerShell generator:
#   - same catalog selection rules (--use-defaults: defaultSelected, minus
#     manual-source entries skipped with a warning)
#   - same fail-closed guards (mutual exclusion, empty selection, name regex)
#   - same emission rules (template extracted from the .ps1, CRLF-joined
#     package block, substituted choco source, "exit 0\r\n" ending)
#
# All generated files go to a temp dir -- NEVER the repo. The emitted script
# carries no credentials, but keep artifacts out of the tree anyway.
#
# Usage: bash tests/tools/test-app-install-twin.sh   (exit 0 = all green)
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TWIN="$REPO/tools/New-AppInstallScript.sh"
PSGEN="$REPO/tools/New-AppInstallScript.ps1"
CATALOG="$REPO/data/choco-install/apps.json"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-appinstall-twin.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

[[ -x "$TWIN" ]] || chmod +x "$TWIN"

# --- python reference port of the PS generation rules -------------------------
# Encodes the PS generator's behavior independently of the twin (mirrors
# tests/tools/test-xml-twin.sh's use of test-xml-gen-e2e.py as reference).
REFPY="$TMP/ref.py"
cat > "$REFPY" <<'PYEOF'
import json, sys, re
ps1, catalog, mode, choco_source, pkgs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
name_re = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')

if mode == "defaults":
    selected = []
    for e in json.load(open(catalog)):
        if not e.get("defaultSelected"): continue
        if e.get("source") == "manual": continue
        selected.append(e["package"])
elif mode == "packages":
    selected = [p for p in pkgs.split(",")]
else:
    sys.exit("bad mode")
if not selected:
    sys.exit("No packages selected; nothing to emit.")
for n in selected:
    if not name_re.match(n):
        sys.exit("Suspicious package name rejected: '%s'" % n)

lines = open(ps1, encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if l == "$script = @'")
end = next(i for i, l in enumerate(lines) if i > start and l == "'@")
template = "\n".join(lines[start + 1:end])
block = "\r\n".join("    '%s'," % p.replace("'", "''") for p in selected).rstrip(",")
out = (template
       .replace("@@PACKAGE_BLOCK@@", block)
       .replace("@@CHOCO_SOURCE@@", choco_source.replace("'", "''")))
sys.stdout.write(out.lstrip() + "\r\n")
PYEOF

# --- T1: parity -- explicit packages, byte-diff against reference ---------------
"$TWIN" --packages GoogleChrome,Steam,VLC --output "$TMP/twin-explicit.ps1" >/dev/null 2>&1 \
    && pass "twin generates from explicit package list" \
    || fail "twin generates from explicit package list"
python3 "$REFPY" "$PSGEN" "$CATALOG" packages "https://community.chocolatey.org/api/v2/" "GoogleChrome,Steam,VLC" > "$TMP/ref-explicit.ps1"
if diff "$TMP/ref-explicit.ps1" "$TMP/twin-explicit.ps1" >/dev/null 2>&1; then
    pass "explicit-package output byte-identical to reference port"
else
    fail "explicit-package output byte-identical to reference port" "$(diff "$TMP/ref-explicit.ps1" "$TMP/twin-explicit.ps1" | head -5)"
fi

# --- T2: parity -- --use-defaults, byte-diff against reference ------------------
"$TWIN" --use-defaults --output "$TMP/twin-defaults.ps1" 2>"$TMP/twin-warn.txt" \
    || fail "twin generates from catalog defaults"
python3 "$REFPY" "$PSGEN" "$CATALOG" defaults "https://community.chocolatey.org/api/v2/" "" > "$TMP/ref-defaults.ps1"
if diff "$TMP/ref-defaults.ps1" "$TMP/twin-defaults.ps1" >/dev/null 2>&1; then
    pass "defaults output byte-identical to reference port"
else
    fail "defaults output byte-identical to reference port" "$(diff "$TMP/ref-defaults.ps1" "$TMP/twin-defaults.ps1" | head -5)"
fi
# manual-source defaults are skipped with a stderr warning (parity with PS Write-Warning)
MANUALS="$(python3 -c "import json; print(sum(1 for e in json.load(open('$CATALOG')) if e.get('defaultSelected') and e.get('source')=='manual'))")"
SKIPPED="$(grep -c "WARNING: Skipping" "$TMP/twin-warn.txt" || true)"
if [[ "$SKIPPED" == "$MANUALS" ]]; then
    pass "manual-source defaults skipped with warning ($SKIPPED skipped of $MANUALS in catalog)"
else
    fail "manual-source defaults skipped with warning" "expected $MANUALS, saw $SKIPPED"
fi
# and no manual package name lands in the emitted $Packages block
if python3 - "$CATALOG" "$TMP/twin-defaults.ps1" <<'PYEOF'; then
import json, re, sys
manuals = {e["package"] for e in json.load(open(sys.argv[1])) if e.get("source") == "manual"}
block = open(sys.argv[2]).read().split("$Packages = @(")[1].split(")")[0]
bad = [m for m in manuals if re.search(r"^\s*'%s'," % re.escape(m), block, re.M)]
sys.exit(1 if bad else 0)
PYEOF
    pass "manual packages absent from emitted installer"
else
    fail "manual packages absent from emitted installer"
fi

# --- T3: emission rules --------------------------------------------------------
grep -q $'\r' "$TMP/twin-explicit.ps1" \
    && pass "emitted file uses CRLF at PS rule points" \
    || fail "emitted file uses CRLF at PS rule points"
# exactly: package-block joins + final line ending
python3 - "$TMP/twin-explicit.ps1" <<'PYEOF' \
    && pass "CRLF count matches PS rules (2 joins + trailing)" \
    || fail "CRLF count matches PS rules (2 joins + trailing)"
import sys
d = open(sys.argv[1], "rb").read()
n_cr = d.count(b"\r\n")
n_crlf_lines = sum(1 for l in d.split(b"\n") if l.endswith(b"\r"))
assert n_cr == 3 and d.endswith(b"exit 0\r\n"), "got %d CRLF, tail=%r" % (n_cr, d[-10:])
PYEOF
head -c 2 "$TMP/twin-explicit.ps1" | grep -q '^<#' \
    && pass "no leading whitespace (TrimStart parity)" \
    || fail "no leading whitespace (TrimStart parity)"
grep -q '@@PACKAGE_BLOCK@@\|@@CHOCO_SOURCE@@' "$TMP/twin-explicit.ps1" \
    && fail "no unsubstituted placeholders remain" \
    || pass "no unsubstituted placeholders remain"
grep -q "ChocoSource\|community.chocolatey.org/api/v2" "$TMP/twin-explicit.ps1" \
    && pass "choco source baked into emitted script" \
    || fail "choco source baked into emitted script"
# custom air-gap source lands in the emitted installer
"$TWIN" --packages 7zip --choco-source 'C:\Phoenix\Feed' --output "$TMP/twin-airgap.ps1" >/dev/null 2>&1
grep -qF "[string]\$Source = 'C:\\Phoenix\\Feed'" "$TMP/twin-airgap.ps1" \
    && pass "custom --choco-source overrides the default" \
    || fail "custom --choco-source overrides the default"

# --- T4: emitted installer keeps the fail-safe properties ----------------------
need() { if grep -qF "$2" "$TMP/twin-explicit.ps1"; then pass "$1"; else fail "$1" "missing: $2"; fi; }
need "emitted: idempotent per-package skip" "already installed; skipping"
need "emitted: logs everything" 'app-install.log'
need "emitted: log dir under Phoenix" 'Phoenix\Logs'
need "emitted: never blocks OOBE (exit 0)" "exit 0"

# --- T5: fail-closed guards -----------------------------------------------------
expect_fail() {
    local name="$1"; shift
    if "$TWIN" "$@" >/dev/null 2>&1; then fail "$name (accepted, should reject)"; else pass "$name"; fi
}
expect_fail "rejects --packages + --use-defaults together" --packages 7zip --use-defaults --output "$TMP/g1.ps1"
expect_fail "requires a selection mode" --output "$TMP/g2.ps1"
expect_fail "rejects empty package list" --packages "" --output "$TMP/g3.ps1"
expect_fail "rejects suspicious package name" --packages '7zip;rm -rf /' --output "$TMP/g4.ps1"
expect_fail "rejects path-traversal package name" --packages '../../evil' --output "$TMP/g5.ps1"
expect_fail "rejects missing catalog" --use-defaults --apps-json "$TMP/nope.json" --output "$TMP/g6.ps1"
expect_fail "rejects unknown flag" --bogus --output "$TMP/g7.ps1"

# --- T6: --output writes + reports; stdout when omitted -------------------------
"$TWIN" --packages VLC --output "$TMP/out.ps1" 2>/dev/null | grep -q "Wrote 1 packages to $TMP/out.ps1" \
    && pass "--output writes file and reports package count" \
    || fail "--output writes file and reports package count"
"$TWIN" --packages VLC 2>/dev/null | grep -q "^\$Packages = @(" \
    && pass "prints emitted script to stdout when --output omitted" \
    || fail "prints emitted script to stdout when --output omitted"

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
