#!/usr/bin/env bash
#===============================================================================
# test-chain-of-custody.sh -- producer/consumer contract for the Phoenix
# chain of custody: BACKUP emits proof -> NUKE writes completion -> REINSTALL
# consumes both.
#
# Every record is produced by the REAL writer (tools/New-ImageProof.sh for the
# backup side, write_nuke_completion sourced from tools/Invoke-Nuke.sh for the
# nuke side) and consumed by the REAL reinstall gate
# (tools/lib/reinstall-gates.sh). Nothing here touches a real disk; no wipe
# ever executes. Exit 0 = all pass; exit 1 = any failure.
#
# What this proves that the per-phase suites cannot: the records one phase
# writes are the records the next phase's gate actually accepts -- the two
# historically-broken handshakes were (1) the new backup line's proof never
# reaching the reinstall gate in a consumable form, and (2) nuke-completed.json
# having no writer at all.
#===============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROOF_WRITER="$REPO_ROOT/tools/New-ImageProof.sh"
NUKE="$REPO_ROOT/tools/Invoke-Nuke.sh"
LIB="$REPO_ROOT/tools/lib/reinstall-gates.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SERIAL="CHAINTEST0001"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# --- 1. backup proof: JSON sibling the reinstall gate consumes ---------------
echo "== backup proof =="

STATE="$TMP/state"; mkdir -p "$STATE"
echo "imgdata" > "$TMP/fake.img"

"$PROOF_WRITER" --image-name chain-test --image-path "$TMP/fake.img" \
    --source-serial "$SERIAL" --source-dev /dev/sda --sha256 "$SHA" \
    --verified --verified-by chain-suite --out "$STATE" --json-out "$STATE" \
    >/dev/null 2>&1
[[ -f "$STATE/backup-image-proof.json" ]] \
  && ok "proof writer emits backup-image-proof.json" || bad "no backup-image-proof.json"

python3 - "$STATE/backup-image-proof.json" <<'EOF' >/dev/null 2>&1
import json, sys
p = json.load(open(sys.argv[1]))
assert p["schema"] == "phoenix-image-proof/1", p.get("schema")
assert p["serial"] == "CHAINTEST0001", p.get("serial")
assert p["verified"] is True, p.get("verified")
assert p["sha256"] == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
EOF
[[ $? -eq 0 ]] && ok "proof JSON has the chain schema fields" || bad "proof JSON fields wrong"

# chain gate must ACCEPT the producer's output (with a nuke record present)
# write a real nuke completion record via the real function from Invoke-Nuke.sh
SRC_STRIPPED="$TMP/invoke-nuke-src.sh"
grep -v '^main "\$@"$' "$NUKE" > "$SRC_STRIPPED"
export PHOENIX_TOOLS_DIR="$REPO_ROOT/tools"
# shellcheck disable=SC1090
source "$SRC_STRIPPED" >/dev/null 2>&1
set +e   # the sourced script carries `set -e`; our negative tests need nonzero exits
write_nuke_completion "$STATE" "$SERIAL" "/dev/sda" "Test Disk" \
    "zero" "NIST 800-88: Purge" "" >/dev/null 2>&1
[[ -f "$STATE/nuke-completed.json" ]] \
  && ok "write_nuke_completion writes nuke-completed.json" || bad "no nuke-completed.json"

python3 - "$STATE/nuke-completed.json" <<'EOF' >/dev/null 2>&1
import json, sys
n = json.load(open(sys.argv[1]))
assert n["schema"] == "phoenix-nuke-completion/1", n.get("schema")
assert n["serial"] == "CHAINTEST0001", n.get("serial")
assert n["completed_at"], "no completed_at"
assert n["method"] == "zero", n.get("method")
EOF
[[ $? -eq 0 ]] && ok "nuke completion record has the chain schema fields" || bad "nuke completion fields wrong"

# the full chain: backup proof + nuke record -> reinstall gate accepts
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$STATE\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -eq 0 ]] \
  && ok "reinstall chain gate accepts both producer records" \
  || bad "reinstall chain gate REFUSED both producer records"

# --- 2. unverified proof refuses ----------------------------------------------
echo "== negative: unverified proof =="

S2="$TMP/state2"; mkdir -p "$S2"
"$PROOF_WRITER" --image-name chain-test --image-path "$TMP/fake.img" \
    --source-serial "$SERIAL" --source-dev /dev/sda --sha256 "$SHA" \
    --verified-by chain-suite --out "$S2" --json-out "$S2" >/dev/null 2>&1
write_nuke_completion "$S2" "$SERIAL" "/dev/sda" "Test Disk" "zero" \
    "NIST 800-88: Purge" "" >/dev/null 2>&1
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$S2\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "unverified backup proof refuses the chain" \
  || bad "unverified proof ACCEPTED by chain gate"

# --- 3. serial mismatch refuses ------------------------------------------------
echo "== negative: serial mismatch =="

S3="$TMP/state3"; mkdir -p "$S3"
"$PROOF_WRITER" --image-name chain-test --image-path "$TMP/fake.img" \
    --source-serial "OTHERDISK0002" --source-dev /dev/sda --sha256 "$SHA" \
    --verified --verified-by chain-suite --out "$S3" --json-out "$S3" >/dev/null 2>&1
write_nuke_completion "$S3" "$SERIAL" "/dev/sda" "Test Disk" "zero" \
    "NIST 800-88: Purge" "" >/dev/null 2>&1
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$S3\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "backup proof bound to another serial refuses" \
  || bad "wrong-serial proof ACCEPTED by chain gate"

S4="$TMP/state4"; mkdir -p "$S4"
cp "$STATE/backup-image-proof.json" "$S4/"
write_nuke_completion "$S4" "OTHERDISK0002" "/dev/sda" "Test Disk" "zero" \
    "NIST 800-88: Purge" "" >/dev/null 2>&1
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$S4\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "nuke record for another serial refuses" \
  || bad "wrong-serial nuke record ACCEPTED by chain gate"

# --- 4. missing record refuses --------------------------------------------------
echo "== negative: missing records =="

S5="$TMP/state5"; mkdir -p "$S5"
cp "$STATE/backup-image-proof.json" "$S5/"
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$S5\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "state without nuke record refuses" \
  || bad "proof-without-nuke ACCEPTED by chain gate"

S6="$TMP/state6"; mkdir -p "$S6"
cp "$STATE/nuke-completed.json" "$S6/"
bash -c "source \"$LIB\"; reinstall_require_chain_of_custody \"$S6\" \"$SERIAL\"" \
    >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "state without backup proof refuses" \
  || bad "nuke-without-proof ACCEPTED by chain gate"

echo "----------------------------------------"
echo "RESULT: $pass PASS / $fail FAIL"
[[ $fail -eq 0 ]]
