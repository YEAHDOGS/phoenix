#!/usr/bin/env bash
# test-reinstall.sh -- regression suite for the Phoenix REINSTALL phase.
# Covers: reinstall_require_target_blank (all-zeros first-1MiB hash = the
# disk was nuked), reinstall_require_artifacts (answer file + ISO staged),
# reinstall_require_config_match (staged files agree with phoenix-config.json),
# reinstall_require_chain_of_custody (verified backup proof + completed nuke
# record for the same serial), and the flow's CLI contract.
# Run from the repo root:  bash tests/tools/test-reinstall.sh
# Exit 0 = all pass; exit 1 = any failure. No network, no real disks touched:
# enumeration is driven by PHOENIX_MOCK_LSBLK / PHOENIX_MOCK_MOUNTS /
# PHOENIX_MOCK_HASH (see Get-DiskInventory.sh).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENUM="$REPO_ROOT/tools/Get-DiskInventory.sh"
LIB="$REPO_ROOT/tools/lib/reinstall-gates.sh"
FLOW="$REPO_ROOT/tools/Reinstall-Windows.sh"
FIX="$REPO_ROOT/tests/tools/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# All-zeros first-1MiB hash: what the Nuke flow produces. Same constant as
# REINSTALL_BLANK_HASH in the gate library.
ZEROS="30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"

gate() { # <fn> [args...] -> rc ; sources the lib in a subshell
    bash -c "source \"$LIB\"; $*" >/dev/null 2>&1
}

# fixture inventories: id1=nvme WDCA9876543210 2TB, id2=sda Samsung
# S5YBNJ0R123456A 931.5GiB, id3=sdb serial-less USB.
# Fingerprints (partition_hash = first-1MiB probe) come from --save-state runs.
mk_fixtures() { # <dir> <mock-hash> <mock-mounts>
    mkdir -p "$1"
    PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_HASH="$2" \
        PHOENIX_MOCK_MOUNTS="$3" \
        "$ENUM" --save-state "$1" > "$1/inv.json" 2>/dev/null
}
mk_fixtures "$TMP/fx-blank" "$ZEROS" ""
mk_fixtures "$TMP/fx-live" aaabbb ""
mk_fixtures "$TMP/fx-mnt" "$ZEROS" "nvme0n1p1"
INV_BLANK="$TMP/fx-blank/inv.json"; FP_BLANK="$TMP/fx-blank/disk-fingerprints.json"
INV_LIVE="$TMP/fx-live/inv.json";   FP_LIVE="$TMP/fx-live/disk-fingerprints.json"
INV_MNT="$TMP/fx-mnt/inv.json";     FP_MNT="$TMP/fx-mnt/disk-fingerprints.json"

# --- 1. blank-target gate ------------------------------------------------------
echo "== blank-target gate =="

gate "reinstall_require_target_blank \"$INV_BLANK\" 1 \"$FP_BLANK\""; [[ $? -eq 0 ]] \
  && ok "zeroed disk accepted as reinstall target" || bad "zeroed disk REFUSED"

gate "reinstall_require_target_blank \"$INV_LIVE\" 1 \"$FP_LIVE\""; [[ $? -ne 0 ]] \
  && ok "disk with live partition metadata refused" || bad "LIVE disk ACCEPTED (danger)"

gate "reinstall_require_target_blank \"$INV_MNT\" 1 \"$FP_MNT\""; [[ $? -ne 0 ]] \
  && ok "mounted disk refused even with zeroed hash" || bad "mounted disk ACCEPTED"

gate "reinstall_require_target_blank \"$INV_BLANK\" 3 \"$FP_BLANK\""; [[ $? -ne 0 ]] \
  && ok "serial-less disk refused" || bad "serial-less disk ACCEPTED"

gate "reinstall_require_target_blank \"$INV_BLANK\" 99 \"$FP_BLANK\""; [[ $? -ne 0 ]] \
  && ok "unknown id refused" || bad "unknown id ACCEPTED"

# missing fingerprint file: no probe, no install
gate "reinstall_require_target_blank \"$INV_BLANK\" 1 \"$TMP/no-such-fp.json\""; [[ $? -ne 0 ]] \
  && ok "missing fingerprint file refused" || bad "missing fingerprints ACCEPTED"

# the constant in the lib is the true sha256 of 1 MiB of zeros (self-check)
python3 -c "
import hashlib
want = 'sha256:' + hashlib.sha256(b'\x00'*1048576).hexdigest()
got = [l for l in open('$LIB') if 'REINSTALL_BLANK_HASH=' in l][0].split('\"')[1]
assert got == want, f'{got} != {want}'
" \
  && ok "lib's all-zeros constant matches real sha256(1MiB zeros)" \
  || bad "lib's all-zeros constant is WRONG"

# --- 2. artifacts gate ---------------------------------------------------------
echo "== artifacts gate =="

echo "<xml/>" > "$TMP/autounattend.xml"
head -c 100 /dev/zero > "$TMP/win11.iso"
: > "$TMP/empty.xml"

gate "reinstall_require_artifacts \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -eq 0 ]] \
  && ok "staged answer file + ISO accepted" || bad "valid artifacts REFUSED"

gate "reinstall_require_artifacts \"$TMP/missing.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "missing answer file refused" || bad "missing answer file ACCEPTED"

gate "reinstall_require_artifacts \"$TMP/autounattend.xml\" \"$TMP/missing.iso\""; [[ $? -ne 0 ]] \
  && ok "missing ISO refused" || bad "missing ISO ACCEPTED"

gate "reinstall_require_artifacts \"$TMP/empty.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "empty answer file refused" || bad "empty answer file ACCEPTED"

gate "reinstall_require_artifacts \"$TMP/autounattend.xml\" \"$TMP/empty.xml\""; [[ $? -ne 0 ]] \
  && ok "empty ISO refused" || bad "empty ISO ACCEPTED"

# --- 3. config-consistency gate ------------------------------------------------
echo "== config-consistency gate =="

mkconfig() { # <file> <reinstall-enabled> <platform> <answer-file>
    # Schema-valid config (the flow's USB-config gate runs the full
    # validator; nuke is off in fixtures so no target_disks allowlist is
    # required by the cross-field rules).
    cat > "$1" <<EOF
{"schema_version": 1,
 "boot_entries": {"analyze": true, "backup": true, "nuke": false, "reinstall": $2},
 "reinstall": {"platform": "$3"},
 "unattend": {"answer_file": "$4"},
 "backup_target": {"kind": "direct-usb"},
 "safety": {"require_image_proof": true, "allow_skip_image_gate": false, "abort_countdown_seconds": 5},
 "target_disks": []}
EOF
}
mkconfig "$TMP/cfg-ok.json" true windows "/autounattend.xml"
mkconfig "$TMP/cfg-off.json" false windows "/autounattend.xml"
mkconfig "$TMP/cfg-linux.json" true linux "/autounattend.xml"
mkconfig "$TMP/cfg-stale.json" true windows "/other-answer.xml"
echo "not json" > "$TMP/cfg-bad.json"

gate "reinstall_require_config_match \"$TMP/cfg-ok.json\" \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -eq 0 ]] \
  && ok "consistent config accepted" || bad "consistent config REFUSED"

gate "reinstall_require_config_match \"$TMP/cfg-off.json\" \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "disabled reinstall entry refused" || bad "disabled entry ACCEPTED"

gate "reinstall_require_config_match \"$TMP/cfg-linux.json\" \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "non-windows platform refused" || bad "linux platform ACCEPTED"

gate "reinstall_require_config_match \"$TMP/cfg-stale.json\" \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "stale answer-file name refused" || bad "stale config ACCEPTED"

gate "reinstall_require_config_match \"$TMP/cfg-bad.json\" \"$TMP/autounattend.xml\" \"$TMP/win11.iso\""; [[ $? -ne 0 ]] \
  && ok "invalid JSON config refused" || bad "invalid JSON ACCEPTED"

# --- 4. chain-of-custody gate --------------------------------------------------
echo "== chain-of-custody gate =="

STATE="$TMP/state"; mkdir -p "$STATE"
cat > "$STATE/backup-image-proof.json" <<'EOF'
{"schema": "phoenix-image-proof/1", "serial": "WDCA9876543210",
 "verified": true, "sha256": "deadbeef"}
EOF
cat > "$STATE/nuke-completed.json" <<'EOF'
{"schema": "phoenix-nuke-completion/1", "serial": "WDCA9876543210",
 "completed_at": "2026-09-09T12:00:00Z"}
EOF

gate "reinstall_require_chain_of_custody \"$STATE\" WDCA9876543210"; [[ $? -eq 0 ]] \
  && ok "verified backup + completed nuke for serial accepted" || bad "valid chain REFUSED"

S2="$TMP/state2"; mkdir -p "$S2"
gate "reinstall_require_chain_of_custody \"$S2\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "state without backup proof refused" || bad "proof-less state ACCEPTED"

S3="$TMP/state3"; mkdir -p "$S3"
cp "$STATE/backup-image-proof.json" "$S3/"
gate "reinstall_require_chain_of_custody \"$S3\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "state without nuke record refused" || bad "nuke-less state ACCEPTED"

S4="$TMP/state4"; mkdir -p "$S4"
cp "$STATE/nuke-completed.json" "$S4/"
echo '{"schema": "phoenix-image-proof/1", "serial": "WDCA9876543210", "verified": false}' > "$S4/backup-image-proof.json"
gate "reinstall_require_chain_of_custody \"$S4\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "unverified backup proof refused" || bad "unverified proof ACCEPTED"

S5="$TMP/state5"; mkdir -p "$S5"
echo '{"schema": "phoenix-image-proof/1", "serial": "OTHER123", "verified": true}' > "$S5/backup-image-proof.json"
cp "$STATE/nuke-completed.json" "$S5/"
gate "reinstall_require_chain_of_custody \"$S5\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "backup proof for a different serial refused" || bad "wrong-serial proof ACCEPTED"

S6="$TMP/state6"; mkdir -p "$S6"
cp "$STATE/backup-image-proof.json" "$S6/"
echo '{"schema": "phoenix-nuke-completion/1", "serial": "OTHER123", "completed_at": "2026-09-09T12:00:00Z"}' > "$S6/nuke-completed.json"
gate "reinstall_require_chain_of_custody \"$S6\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "nuke record for a different serial refused" || bad "wrong-serial nuke ACCEPTED"

S7="$TMP/state7"; mkdir -p "$S7"
cp "$STATE/backup-image-proof.json" "$S7/"
echo '{"schema": "phoenix-nuke-completion/1", "serial": "WDCA9876543210"}' > "$S7/nuke-completed.json"
gate "reinstall_require_chain_of_custody \"$S7\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "nuke record without completed_at refused" || bad "timestamp-less nuke ACCEPTED"

# --- 5. flow CLI contract ------------------------------------------------------
echo "== flow CLI =="

"$FLOW" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" 1 >/dev/null 2>&1; [[ $? -eq 3 ]] \
  && ok "missing --config exits 3" || bad "missing --config did not exit 3"

"$FLOW" --config "$TMP/cfg-ok.json" --iso "$TMP/win11.iso" 1 >/dev/null 2>&1; [[ $? -eq 3 ]] \
  && ok "missing --unattend exits 3" || bad "missing --unattend did not exit 3"

"$FLOW" --config "$TMP/cfg-ok.json" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" --bogus 1 >/dev/null 2>&1; [[ $? -eq 3 ]] \
  && ok "unknown flag exits 3" || bad "unknown flag did not exit 3"

# --- 5b. USB-config (stick policy) gate ---------------------------------------
echo "== USB-config gate =="

"$FLOW" --config "$TMP/cfg-off.json" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" 1 >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && ok "stick with reinstall disabled exits 2" || bad "reinstall-disabled stick did not exit 2"

"$FLOW" --config "$TMP/cfg-off.json" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" 1 2>&1 | grep -q "disables the REINSTALL boot entry" \
  && ok "reinstall-disabled refusal names the stick policy" || bad "reinstall-disabled refusal is silent"

"$FLOW" --config "$TMP/cfg-bad.json" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" 1 >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && ok "invalid JSON config exits 2" || bad "invalid JSON config did not exit 2"

"$FLOW" --config "$TMP/cfg-linux.json" --unattend "$TMP/autounattend.xml" --iso "$TMP/win11.iso" 1 2>&1 | grep -q "only 'windows' is implemented" \
  && ok "linux platform refused at the stick-policy gate" || bad "linux platform not refused at stick policy"

# full happy path reaches the TTY gate (fails without a terminal -- gates 1-4 passed)
cp "$FP_BLANK" "$STATE/disk-fingerprints.json"
bash -c "printf '' | \"$FLOW\" --config \"$TMP/cfg-ok.json\" --unattend \"$TMP/autounattend.xml\" --iso \"$TMP/win11.iso\" --state \"$STATE\" --inventory \"$INV_BLANK\" 1" >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "happy-path flow reaches interactive confirmation (refused on piped stdin)" \
  || bad "happy-path flow did not reach confirmation"

# happy path with a live (non-blank) disk fails at gate 1, before artifacts
cp "$FP_LIVE" "$STATE/disk-fingerprints.json"
bash -c "printf '' | \"$FLOW\" --config \"$TMP/cfg-ok.json\" --unattend \"$TMP/autounattend.xml\" --iso \"$TMP/win11.iso\" --state \"$STATE\" --inventory \"$INV_LIVE\" 1" 2>&1 | grep -q "not all-zeros" \
  && ok "flow fails at the blank-target gate for a live disk" \
  || bad "flow did not fail closed on a live disk"

echo "----------------------------------------"
echo "RESULT: $pass PASS / $fail FAIL"
[[ $fail -eq 0 ]]
