#!/usr/bin/env bash
# test-nuke-interlock.sh — regression suite for the Phoenix nuke interlocks.
# Covers: Get-DiskInventory.sh enumeration (mocked lsblk), the typed
# confirmation gate, the Analyze fingerprint gate, and the config allowlist
# gate in tools/lib/nuke-interlock.sh.
# Run from the repo root:  bash tests/tools/test-nuke-interlock.sh
# Exit 0 = all pass; exit 1 = any failure. No network, no real disks touched:
# enumeration is driven by PHOENIX_MOCK_LSBLK, confirmation by a pty (script).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENUM="$REPO_ROOT/tools/Get-DiskInventory.sh"
LIB="$REPO_ROOT/tools/lib/nuke-interlock.sh"
FIX="$REPO_ROOT/tests/tools/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures -----------------------------------------------------------------
mkdir -p "$FIX"
cat > "$FIX/mock-lsblk.txt" <<'EOF'
NAME="sda" MODEL="Samsung SSD 870 EVO 1TB" SERIAL="S5YBNJ0R123456A" SIZE="1000204886016" TRAN="sata" RM="0"
NAME="sdb" MODEL="USB Flash Drive" SERIAL="" SIZE="32010928128" TRAN="usb" RM="1"
NAME="nvme0n1" MODEL="WD Black SN850X 2TB" SERIAL="WDCA9876543210" SIZE="2000398934016" TRAN="nvme" RM="0"
EOF

# --- 1. enumeration (mocked) ---------------------------------------------------
echo "== enumeration (mocked lsblk) =="

INV_JSON="$(PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="sdb1" \
            PHOENIX_MOCK_HASH=aaabbb "$ENUM")"
echo "$INV_JSON" > "$TMP/inv.json"

py() { python3 -c "$1" "$TMP/inv.json"; }

n="$(py 'import json,sys; print(len(json.load(open(sys.argv[1]))["disks"]))')"
[[ "$n" == "3" ]] && ok "enumerates 3 mocked disks" || bad "expected 3 disks, got $n"

first="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][0]["dev"])')"
[[ "$first" == "/dev/nvme0n1" ]] && ok "deterministic order (transport, then size)" || bad "order wrong: $first"

serial2="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][1]["serial"])')"
[[ "$serial2" == "S5YBNJ0R123456A" ]] && ok "serial reported verbatim" || bad "serial wrong: $serial2"

noserial="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][2]["serial"])')"
[[ "$noserial" == "None" ]] && ok "serial-less disk -> null serial" || bad "serial-less handling: $noserial"

mounted="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][2]["mounted"])')"
[[ "$mounted" == "True" ]] && ok "mounted partition detected on sdb" || bad "mounted detection: $mounted"

human="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][1]["size_human"])')"
[[ "$human" == "931.5 GiB" ]] && ok "size_human renders one-decimal GiB" || bad "size_human: $human"

# fingerprint recording (the Analyze step)
PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="" PHOENIX_MOCK_HASH=aaabbb \
  "$ENUM" --save-state "$TMP/state" >/dev/null 2>&1
[[ -f "$TMP/state/disk-fingerprints.json" ]] && ok "Analyze records disk-fingerprints.json" || bad "fingerprint file missing"
by="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["recorded_by"])' "$TMP/state/disk-fingerprints.json")"
[[ "$by" == "analyze" ]] && ok "fingerprint stamped recorded_by=analyze" || bad "recorded_by: $by"
ph="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["disks"][0]["partition_hash"])' "$TMP/state/disk-fingerprints.json")"
[[ "$ph" == "sha256:aaabbb" ]] && ok "partition hash recorded in fingerprint" || bad "partition_hash: $ph"

# --- 2. typed confirmation gate -----------------------------------------------
echo "== typed confirmation gate =="

# run_confirm <answer> -- runs nuke_confirm_target for disk id 2 (Samsung,
# serial S5YBNJ0R123456A) on a real pty; stdin is the pty, NOT a pipe.
run_confirm() { # <answer> <state-dir> [extra-env...]
    local answer="$1" sdir="$2"
    mkdir -p "$sdir"
    printf '%s\n' "$answer" | script -qec \
      "bash -c 'source \"$LIB\"; nuke_confirm_target \"$TMP/inv.json\" 2 \"$sdir\"'" \
      /dev/null >/dev/null 2>&1
}

run_confirm "S5YBNJ0R123456A Samsung SSD 870 EVO 1TB" "$TMP/c-ok"
[[ $? -eq 0 && -f "$TMP/c-ok/nuke-interlock.log" ]] && ok "exact serial+model accepted and logged" \
  || bad "exact pair rejected"

run_confirm "NUKE S5YBNJ0R123456A Samsung SSD 870 EVO 1TB" "$TMP/c-nuke"
[[ $? -eq 0 ]] && ok "NUKE-prefixed pair accepted" || bad "NUKE-prefixed pair rejected"

run_confirm "WRONGSERIAL Samsung SSD 870 EVO 1TB" "$TMP/c-ws"
[[ $? -ne 0 ]] && ok "wrong serial refused" || bad "wrong serial ACCEPTED (danger)"

run_confirm "S5YBNJ0R123456A WD Black SN850X 2TB" "$TMP/c-wm"
[[ $? -ne 0 ]] && ok "wrong model refused" || bad "wrong model ACCEPTED (danger)"

run_confirm "S5YBNJ0R123456A" "$TMP/c-so"
[[ $? -ne 0 ]] && ok "serial-only refused" || bad "serial-only ACCEPTED (danger)"

run_confirm "Samsung SSD 870 EVO 1TB" "$TMP/c-mo"
[[ $? -ne 0 ]] && ok "model-only refused" || bad "model-only ACCEPTED (danger)"

run_confirm "yes" "$TMP/c-yes"
[[ $? -ne 0 ]] && ok "Y/N refused" || bad "'yes' ACCEPTED (danger)"

run_confirm "" "$TMP/c-empty"
[[ $? -ne 0 ]] && ok "empty input refused" || bad "empty input ACCEPTED (danger)"

run_confirm "s5ybnj0r123456a Samsung SSD 870 EVO 1TB" "$TMP/c-case"
[[ $? -ne 0 ]] && ok "case-differing serial refused (exact match)" || bad "case-insensitive ACCEPTED"

# piped stdin must be refused structurally, even with the correct answer
printf 'S5YBNJ0R123456A Samsung SSD 870 EVO 1TB\n' | \
  bash -c "source \"$LIB\"; nuke_confirm_target \"$TMP/inv.json\" 2 \"$TMP/c-pipe\"" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "piped stdin refused even with correct answer" \
  || bad "piped stdin ACCEPTED (scripting interlock broken)"

# serial-less disk (id 3) can never be a target
run_confirm "anything at all" "$TMP/c-noserial-tmp"  # placeholder state dir
printf 'USB Flash Drive\n' | script -qec \
  "bash -c 'source \"$LIB\"; nuke_confirm_target \"$TMP/inv.json\" 3 \"$TMP/c-noserial\"'" \
  /dev/null >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "serial-less disk refused as target" || bad "serial-less disk ACCEPTED"

# mounted disk (id 3 = sdb, mocked mounted) can never be a target
[[ "$(python3 -c 'import json; print(json.load(open("'"$TMP/inv.json"'"))["disks"][2]["mounted"])')" == "True" ]] \
  && ok "mounted disk refused (guard confirmed by fixture)" || bad "mounted fixture wrong"

# --- 3. fingerprint gate -------------------------------------------------------
echo "== analyze-first fingerprint gate =="

gate_fp() { # <state-dir> <serial> -> rc
    bash -c "source \"$LIB\"; nuke_require_fingerprint \"$1\" \"$2\"" >/dev/null 2>&1
}

gate_fp "$TMP/state" "S5YBNJ0R123456A"; [[ $? -eq 0 ]] \
  && ok "fresh Analyze fingerprint unlocks the recorded disk" || bad "valid fingerprint refused"

gate_fp "$TMP/state" "NOTINSERIAL"; [[ $? -ne 0 ]] \
  && ok "unrecorded serial refused (not in fingerprint)" || bad "unrecorded serial ACCEPTED"

gate_fp "$TMP/nostate" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "missing fingerprint file refused (run Analyze first)" || bad "missing fingerprint ACCEPTED"

# stale fingerprint (> 24h)
mkdir -p "$TMP/stale"
python3 - "$TMP/state/disk-fingerprints.json" "$TMP/stale/disk-fingerprints.json" <<'EOF'
import json, sys
fp = json.load(open(sys.argv[1])); fp["recorded_at"] = "2020-01-01T00:00:00Z"
json.dump(fp, open(sys.argv[2], "w"), indent=2)
EOF
gate_fp "$TMP/stale" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "stale fingerprint refused (re-run Analyze)" || bad "stale fingerprint ACCEPTED"

# forged fingerprint (not recorded by analyze)
mkdir -p "$TMP/forged"
python3 - "$TMP/state/disk-fingerprints.json" "$TMP/forged/disk-fingerprints.json" <<'EOF'
import json, sys
fp = json.load(open(sys.argv[1])); fp["recorded_by"] = "hand"
json.dump(fp, open(sys.argv[2], "w"), indent=2)
EOF
gate_fp "$TMP/forged" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "hand-written fingerprint refused" || bad "forged fingerprint ACCEPTED"

# --- 4. config allowlist gate --------------------------------------------------
echo "== config target_disks allowlist gate =="

cat > "$TMP/config.json" <<'EOF'
{"target_disks": [{"serial": "S5YBNJ0R123456A", "model": "Samsung SSD 870 EVO 1TB"}]}
EOF

gate_al() { # <config> <serial> -> rc
    bash -c "source \"$LIB\"; nuke_require_allowlist \"$1\" \"$2\"" >/dev/null 2>&1
}

gate_al "$TMP/config.json" "S5YBNJ0R123456A"; [[ $? -eq 0 ]] \
  && ok "allowlisted serial passes" || bad "allowlisted serial refused"

gate_al "$TMP/config.json" "WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "non-allowlisted serial refused" || bad "non-allowlisted serial ACCEPTED"

gate_al "$TMP/missing.json" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "missing config fails closed" || bad "missing config ACCEPTED"

echo '{not json' > "$TMP/bad.json"
gate_al "$TMP/bad.json" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "unparseable config fails closed" || bad "bad config ACCEPTED"

echo '{"target_disks": []}' > "$TMP/empty.json"
gate_al "$TMP/empty.json" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "empty allowlist = no disk may be nuked" || bad "empty allowlist ACCEPTED"

# --- 4b. allowlist serial normalization (docs/NUKE-SAFETY.md interlock 12) -----
echo "== allowlist serial normalization =="

cat > "$TMP/config-messy.json" <<'EOF'
{"target_disks": [{"serial": "  s5ybnj0r123456a  ", "model": "Samsung SSD 870 EVO 1TB"}]}
EOF

gate_al "$TMP/config-messy.json" "S5YBNJ0R123456A"; [[ $? -eq 0 ]] \
  && ok "lowercase+padded allowlist entry matches" || bad "normalized serial refused"

gate_al "$TMP/config.json" "  s5ybnj0r123456a  "; [[ $? -eq 0 ]] \
  && ok "lowercase+padded target serial matches" || bad "padded target serial refused"

cat > "$TMP/config-space.json" <<'EOF'
{"target_disks": [{"serial": "S5YBNJ0R1234 56A", "model": "Samsung SSD 870 EVO 1TB"}]}
EOF
gate_al "$TMP/config-space.json" "S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "internal whitespace still refused (not collapsed)" || bad "internal-whitespace serial ACCEPTED"

gate_al "$TMP/config.json" ""; [[ $? -ne 0 ]] \
  && ok "empty serial fails closed" || bad "empty serial ACCEPTED"

echo "----------------------------------------"
echo "RESULT: $pass PASS / $fail FAIL"
[[ $fail -eq 0 ]]
