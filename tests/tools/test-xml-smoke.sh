#!/usr/bin/env bash
#===============================================================================
# test-xml-smoke.sh -- Linux-side smoke test for the answer-file generator
#
# tools/Test-UnattendXml.ps1 is the full validation suite but needs
# PowerShell, which this Linux VM does not have. This is the portable
# subset: XML well-formedness of the template + the last generated file,
# token-set parity between template and New-UnattendXml.ps1, and a
# token-free check on the generated file (no {{...}} left unfilled).
#
# Usage: bash tests/tools/test-xml-smoke.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

for f in win-install/autounattend.template.xml win-install/autounattend.xml; do
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$REPO/$f" 2>/dev/null; then
        pass "well-formed XML: $f"
    else
        fail "well-formed XML: $f"
    fi
done

# token-set parity: every {{TOKEN}} in the template must be produced by the generator and vice versa
mapfile -t TPL_TOKENS < <(grep -o '{{[A-Za-z0-9_]*}}' "$REPO/win-install/autounattend.template.xml" | sort -u)
mapfile -t GEN_TOKENS < <(grep -o '{{[A-Za-z0-9_]*}}' "$REPO/tools/New-UnattendXml.ps1" | sort -u)
if [[ "${TPL_TOKENS[*]}" == "${GEN_TOKENS[*]}" ]]; then
    pass "template/generator token sets match (${#TPL_TOKENS[@]} tokens)"
else
    fail "template/generator token parity" "template: ${TPL_TOKENS[*]} | generator: ${GEN_TOKENS[*]}"
fi

# the checked-in generated file must have no unfilled {{...}} tokens
if grep -q '{{[A-Za-z0-9_]*}}' "$REPO/win-install/autounattend.xml"; then
    fail "generated autounattend.xml is token-free" "unfilled {{...}} tokens remain"
else
    pass "generated autounattend.xml is token-free"
fi

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
