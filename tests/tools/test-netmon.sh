#!/usr/bin/env bash
#===============================================================================
# test-netmon.sh -- fixture-based smoke test for scripts/tools/netmon.sh
#
# Mocks `ss` with a fixed fixture (one external peer, one LAN peer, one
# loopback peer) and asserts netmon.sh --snapshot classifies each into the
# right section with the process name resolved. Exit 0 = all green.
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NETMON="$REPO/scripts/tools/netmon.sh"
T="$(mktemp -d /tmp/phoenix-netmon-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

[[ -f "$NETMON" ]] || { echo "FATAL: $NETMON not found"; exit 1; }
bash -n "$NETMON" && pass "bash -n syntax check" || fail "bash -n syntax check"

#--- mock ss -------------------------------------------------------------------
mkdir -p "$T/mockbin"
cat > "$T/mockbin/ss" <<'MOCK'
#!/usr/bin/env bash
# Fixture: 203.0.113.7 = external "C2-ish" peer, 192.168.1.42 = LAN peer,
#          127.0.0.1 = loopback peer. No header quirk: real ss prints one.
echo 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process'
echo 'tcp   ESTAB  0      0      192.168.1.10:54321  203.0.113.7:443    users:(("evil-implant",pid=999,fd=9))'
echo 'tcp   ESTAB  0      0      192.168.1.10:54322  192.168.1.42:445   users:(("smbd",pid=111,fd=3))'
echo 'tcp   ESTAB  0      0      127.0.0.1:8080      127.0.0.1:41234    users:(("python3",pid=222,fd=5))'
MOCK
chmod +x "$T/mockbin/ss"

out="$(PATH="$T/mockbin:$PATH" bash "$NETMON" --snapshot 2>&1)"

#--- section classification ----------------------------------------------------
echo "$out" | awk '/EXTERNAL CONNECTIONS/{f=1} /LOCAL NETWORK PEERS/{f=0} f' \
    | grep -q '203.0.113.7' \
    && pass "external peer (203.0.113.7) in EXTERNAL section" \
    || fail "external peer (203.0.113.7) in EXTERNAL section" "$out"
echo "$out" | awk '/LOCAL NETWORK PEERS/{f=1} /external=/{f=0} f' \
    | grep -q '192.168.1.42' \
    && pass "LAN peer (192.168.1.42) in LOCAL section" \
    || fail "LAN peer (192.168.1.42) in LOCAL section" "$out"
echo "$out" | awk '/LOCAL NETWORK PEERS/{f=1} /external=/{f=0} f' \
    | grep -q '127.0.0.1' \
    && pass "loopback peer in LOCAL section" \
    || fail "loopback peer in LOCAL section" "$out"

#--- cross-contamination: external must NOT appear in LOCAL and vice versa -----
echo "$out" | awk '/LOCAL NETWORK PEERS/{f=1} /external=/{f=0} f' \
    | grep -q '203.0.113.7' \
    && fail "external peer absent from LOCAL section" \
    || pass "external peer absent from LOCAL section"
echo "$out" | awk '/EXTERNAL CONNECTIONS/{f=1} /LOCAL NETWORK PEERS/{f=0} f' \
    | grep -q '192.168.1.42' \
    && fail "LAN peer absent from EXTERNAL section" \
    || pass "LAN peer absent from EXTERNAL section"

#--- process names resolved ----------------------------------------------------
echo "$out" | grep -q 'evil-implant' \
    && pass "process name resolved for external peer" \
    || fail "process name resolved for external peer" "$out"

#--- summary counts ------------------------------------------------------------
echo "$out" | grep -q 'external=1 local=2' \
    && pass "summary counts external=1 local=2" \
    || fail "summary counts external=1 local=2" "$out"

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "All netmon smoke tests green."
