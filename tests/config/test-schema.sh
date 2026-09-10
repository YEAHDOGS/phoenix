#!/usr/bin/env bash
# test-schema.sh — regression suite for the phoenix-config.json schema + validator.
# Run from the repo root:  bash tests/config/test-schema.sh
# Exit 0 = all pass; exit 1 = any failure. No network, no deps beyond bash + python3.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATOR="$REPO_ROOT/tools/Validate-UsbConfig.py"
SCHEMA="$REPO_ROOT/config/usb-config.schema.json"
FIX="$REPO_ROOT/tests/config/fixtures"

pass=0; fail=0

# expect_valid <fixture> <description>
expect_valid() {
  local out rc
  out="$(python3 "$VALIDATOR" --schema "$SCHEMA" "$FIX/$1" 2>&1)"; rc=$?
  if [[ $rc -eq 0 && $out == OK:* ]]; then
    pass=$((pass+1)); echo "PASS: $2"
  else
    fail=$((fail+1)); echo "FAIL: $2 (expected valid, rc=$rc)"; echo "$out" | sed 's/^/  /'
  fi
}

# expect_invalid <fixture> <description> <must-contain>
expect_invalid() {
  local out rc
  out="$(python3 "$VALIDATOR" --schema "$SCHEMA" "$FIX/$1" 2>&1)"; rc=$?
  if [[ $rc -eq 2 && $out == INVALID:* && $out == *"$3"* ]]; then
    pass=$((pass+1)); echo "PASS: $2"
  else
    fail=$((fail+1)); echo "FAIL: $2 (expected INVALID mentioning '$3', rc=$rc)"; echo "$out" | sed 's/^/  /'
  fi
}

echo "== phoenix-config schema regression suite =="

expect_valid   valid-full.json          "full valid config passes"
expect_valid   valid-minimal.json       "minimal config (nuke off, empty allowlist) passes"
expect_valid   valid-castle-smb.json    "castle-smb backup target with smb_path passes"

expect_invalid bad-enum.json           "unknown backup_target.kind rejected" "not in enum"
expect_invalid bad-serial.json         "malformed disk serial rejected" "pattern"
expect_invalid unknown-field.json      "unknown top-level field rejected" "unknown property"
expect_invalid castle-smb-no-path.json "castle-smb without smb_path rejected" "smb_path"

# Structural safety rules (docs/CONFIG-SCHEMA.md §6) — the JSON Schema alone can't express these.
expect_invalid nuke-without-image-proof.json "nuke with require_image_proof=false rejected" "require_image_proof"
expect_invalid nuke-no-allowlist.json        "nuke with empty target_disks allowlist rejected" "target_disks"

# Validator robustness: malformed JSON must be rejected, not crash.
out="$(python3 -c 'import sys; open(sys.argv[1],"w").write("{not json")' "$FIX/.tmp-badjson.json" 2>/dev/null; python3 "$VALIDATOR" "$FIX/.tmp-badjson.json" 2>&1)"; rc=$?
rm -f "$FIX/.tmp-badjson.json"
if [[ $rc -eq 2 && $out == INVALID:* ]]; then
  pass=$((pass+1)); echo "PASS: malformed JSON rejected without crash"
else
  fail=$((fail+1)); echo "FAIL: malformed JSON handling (rc=$rc)"; echo "$out" | sed 's/^/  /'
fi

echo "----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]