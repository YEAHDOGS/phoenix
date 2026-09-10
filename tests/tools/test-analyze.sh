#!/usr/bin/env bash
# test-analyze.sh -- regression suite for the Phoenix ANALYZE phase.
# Covers: read-only self-check (clean tools pass, dirty file fails closed),
# partition inventory (mocked), report-dir gate, heuristic scans on a fake
# filesystem tree, report shape/verdict logic, and the end-to-end triage flow.
# Run from the repo root:  bash tests/tools/test-analyze.sh
# Exit 0 = all pass; exit 1 = any failure. No network, no real disks touched:
# enumeration is driven by PHOENIX_MOCK_* fixtures and fake scan trees.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/tools/lib/analyze-gates.sh"
FLOW="$REPO_ROOT/tools/Analyze-DiskTriage.sh"
PS1_TWIN="$REPO_ROOT/tools/Analyze-DiskTriage.ps1"
ENUM="$REPO_ROOT/tools/Get-DiskInventory.sh"
FIX="$REPO_ROOT/tests/tools/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gate() { # <fn> [args...] -> rc ; sources the lib in a subshell
    bash -c "source \"$LIB\"; $*" >/dev/null 2>&1
}

# fixture inventory (committed): id1=nvme WDCA9876543210 2TB,
# id2=sda Samsung S5YBNJ0R123456A 931.5GiB, id3=sdb serial-less USB (mounted sdb1)
INV="$TMP/inv.json"
PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="sdb1" \
    PHOENIX_MOCK_HASH=aaabbb "$ENUM" > "$INV"

# --- 1. read-only self-check ----------------------------------------------------
echo "== read-only self-check =="

gate "analyze_assert_readonly \"$LIB\" \"$FLOW\" \"$PS1_TWIN\""; [[ $? -eq 0 ]] \
  && ok "clean Analyze toolchain passes the self-check" || bad "clean toolchain FAILED the self-check"

printf '# doc only\n# mkfs is mentioned in a comment only\n' > "$TMP/comment.sh"
gate "analyze_assert_readonly \"$TMP/comment.sh\""; [[ $? -eq 0 ]] \
  && ok "comment-only mention of a pattern does not trip the check" || bad "comment-only mention TRIPPED the check"

printf 'mkfs.ext4 /dev/sda1\n' > "$TMP/dirty-mkfs.sh"
gate "analyze_assert_readonly \"$TMP/dirty-mkfs.sh\""; [[ $? -ne 0 ]] \
  && ok "file with mkfs write fails closed" || bad "mkfs write NOT caught"

printf 'dd if=/dev/sda of=/dev/sdb bs=4M\n' > "$TMP/dirty-dd.sh"
gate "analyze_assert_readonly \"$TMP/dirty-dd.sh\""; [[ $? -ne 0 ]] \
  && ok "file with dd of=/dev fails closed" || bad "dd of=/dev NOT caught"

printf 'mount -o rw /dev/sda1 /mnt\n' > "$TMP/dirty-mount.sh"
gate "analyze_assert_readonly \"$TMP/dirty-mount.sh\""; [[ $? -ne 0 ]] \
  && ok "file with mount -o rw fails closed" || bad "mount -o rw NOT caught"

printf 'lsblk 2>/dev/null | head\n' > "$TMP/clean-null.sh"
gate "analyze_assert_readonly \"$TMP/clean-null.sh\""; [[ $? -eq 0 ]] \
  && ok "stderr redirect to /dev/null is not a write pattern" || bad "/dev/null redirect TRIPPED the check"

printf 'Format-Volume -DriveLetter D\n' > "$TMP/dirty-ps1.txt"
gate "analyze_assert_readonly \"$TMP/dirty-ps1.txt\""; [[ $? -ne 0 ]] \
  && ok "PowerShell Format-Volume fails closed" || bad "Format-Volume NOT caught"

gate "analyze_assert_readonly \"$TMP/does-not-exist\""; [[ $? -ne 0 ]] \
  && ok "missing tool file fails closed" || bad "missing file ACCEPTED"

# --- 2. partition inventory ------------------------------------------------------
echo "== partition inventory =="

export PHOENIX_MOCK_PARTITIONS="$FIX/mock-partitions.txt"
PARTS_SDA="$TMP/parts-sda.json"
bash -c "source \"$LIB\"; analyze_partition_inventory /dev/sda \"$PARTS_SDA\"" >/dev/null
python3 - "$PARTS_SDA" <<'EOF' >/dev/null 2>&1 || exit 1
import json, sys
parts = json.load(open(sys.argv[1]))
assert len(parts) == 3, f"expected 3 sda partitions, got {len(parts)}"
by = {p["name"]: p for p in parts}
assert by["sda2"]["fstype"] == "ntfs" and by["sda2"]["label"] == "Windows"
assert by["sda3"]["fstype"] is None, "sda3 should have no fstype"
assert by["sda1"]["size_bytes"] == 524288000
assert all(p["dev"].startswith("/dev/") for p in parts)
EOF
[[ $? -eq 0 ]] && ok "mocked partition inventory: names, sizes, fstype" \
              || bad "partition inventory wrong"

PARTS_NVME="$TMP/parts-nvme.json"
bash -c "source \"$LIB\"; analyze_partition_inventory /dev/nvme0n1 \"$PARTS_NVME\"" >/dev/null
[[ "$(python3 -c 'import json; print(len(json.load(open("'"$PARTS_NVME"'"))))')" == "1" ]] \
  && ok "nvme partition filtered by device prefix" || bad "nvme partition filter wrong"

export PHOENIX_MOCK_PARTITIONS="$TMP/does-not-exist"
gate "analyze_partition_inventory /dev/sda \"$TMP/x.json\""; [[ $? -ne 0 ]] \
  && ok "unreadable mock partition file fails cleanly" || bad "unreadable mock ACCEPTED"
unset PHOENIX_MOCK_PARTITIONS

# --- 3. report-dir gate -----------------------------------------------------------
echo "== report-dir gate =="

gate "analyze_require_report_dir / \"$INV\""; [[ $? -ne 0 ]] \
  && ok "report dir / refused" || bad "report dir / ACCEPTED"

PHOENIX_MOCK_REPORT_DEVICE=/dev/sda1 \
  gate "analyze_require_report_dir \"$TMP/r1\" \"$INV\""; [[ $? -ne 0 ]] \
  && ok "report dir on a triaged disk refused" || bad "report dir on target disk ACCEPTED"

PHOENIX_MOCK_REPORT_DEVICE=/dev/sdc1 \
  gate "analyze_require_report_dir \"$TMP/r2\" \"$INV\""; [[ $? -eq 0 ]] \
  && ok "report dir on a non-triaged disk accepted" || bad "safe report dir refused"

# --- 4. heuristic scans (fake filesystem trees) -----------------------------------
echo "== heuristic scans =="

build_tree() { # <dir> : infected-looking fake volume
    local t="$1"
    mkdir -p "$t/Windows/Temp" "$t/Windows/System32" \
             "$t/Users/alice/AppData/Local/Temp" \
             "$t/Users/alice/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
    dd if=/dev/zero of="$t/Windows/Temp/blob.bin" bs=1K count=300 status=none 2>/dev/null
    echo x > "$t/autorun.inf"
    echo x > "$t/Users/alice/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/pwn.lnk"
    touch -d '1 hour ago' "$t/Windows/System32/evil.dll"
    echo ok > "$t/Windows/System32/kernel32.dll"
}

INFECTED="$TMP/infected"; build_tree "$INFECTED"
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/Windows/System32"; echo ok > "$CLEAN/Windows/System32/kernel32.dll"
# the clean tree's system file must NOT look recently modified (test trees are
# created just now, so backdate it)
touch -d '30 days ago' "$CLEAN/Windows/System32/kernel32.dll"

export PHOENIX_ANALYZE_TEMP_MAX_KB=100
IND="$TMP/ind.json"
bash -c "source \"$LIB\"; analyze_scan_mount \"$INFECTED\" disk-2 \"$IND\"" >/dev/null
python3 - "$IND" <<'EOF' >/dev/null 2>&1 || exit 1
import json, sys
inds = json.load(open(sys.argv[1]))
codes = {i["code"] for i in inds}
for want in ("OVERSIZED_TEMP", "AUTORUN_ARTIFACT", "RECENT_SYSTEM_MODIFY"):
    assert want in codes, f"missing indicator {want}"
assert all(i["heuristic"] is True for i in inds), "every analyze finding must be heuristic"
assert all(i["title"].startswith("HEURISTIC:") for i in inds), "titles must be labeled HEURISTIC:"
sev = {i["code"]: i["severity"] for i in inds}
assert sev["AUTORUN_ARTIFACT"] == "suspicious"
assert sev["RECENT_SYSTEM_MODIFY"] == "suspicious"
assert sev["OVERSIZED_TEMP"] == "warn"
EOF
[[ $? -eq 0 ]] && ok "infected tree: temp/autorun/recent-file heuristics fire, all labeled" \
              || bad "heuristic scan of infected tree wrong"

IND2="$TMP/ind2.json"
bash -c "source \"$LIB\"; analyze_scan_mount \"$CLEAN\" disk-2 \"$IND2\"" >/dev/null
[[ "$(python3 -c 'import json; print(len(json.load(open("'"$IND2"'"))))')" == "0" ]] \
  && ok "clean tree: zero indicators" || bad "clean tree produced indicators"
unset PHOENIX_ANALYZE_TEMP_MAX_KB

# --- 5. report shape + verdict -----------------------------------------------------
echo "== report shape =="

# assemble a report from the fixtures
export PHOENIX_MOCK_PARTITIONS="$FIX/mock-partitions.txt"
PARTS_MAP="$TMP/pmap.json"; INDS_MAP="$TMP/imap.json"
bash -c "source \"$LIB\"
analyze_partition_inventory /dev/sda \"$TMP/p1.json\" >/dev/null
analyze_partition_inventory /dev/nvme0n1 \"$TMP/p2.json\" >/dev/null
python3 - '$TMP/p1.json' '$TMP/p2.json' '$PARTS_MAP' <<'EOF'
import json, sys
p1, p2 = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
json.dump({'1': p2, '2': p1}, open(sys.argv[3], 'w'))
EOF
analyze_scan_mount \"$INFECTED\" disk-2 \"$TMP/i1.json\" >/dev/null
python3 - '$TMP/i1.json' '$INDS_MAP' <<'EOF'
import json, sys
json.dump({'2': json.load(open(sys.argv[1]))}, open(sys.argv[2], 'w'))
EOF" >/dev/null
unset PHOENIX_MOCK_PARTITIONS

REP="$TMP/triage-report.json"
bash -c "source \"$LIB\"; analyze_write_report \"$TMP\" \"$INV\" \"$PARTS_MAP\" \"$INDS_MAP\"" >/dev/null
# (report path is deterministic: analyze_write_report writes triage-report.json
# into the state dir passed as its first argument)
python3 - "$TMP/triage-report.json" <<'EOF' >/dev/null 2>&1 || exit 1
import json, sys
r = json.load(open(sys.argv[1]))
assert r["schema"] == "phoenix-triage-report/1", "schema"
assert r["readonly"] is True, "readonly flag"
assert len(r["disks"]) == 3, "3 disks"
d2 = [d for d in r["disks"] if d["id"] == 2][0]
assert len(d2["partitions"]) == 3, "disk 2 has 3 partitions"
codes = {i["code"] for i in r["indicators"]}
assert "UNKNOWN_PARTITION" in codes, "structural unknown-partition indicator"
unk = [i for i in r["indicators"] if i["code"] == "UNKNOWN_PARTITION"][0]
assert unk["heuristic"] is False, "UNKNOWN_PARTITION is structural, not heuristic"
assert unk["disk_id"] == 2
assert r["verdict"] == "triage-complete-suspicious", f"verdict with suspicious findings: {r['verdict']}"
EOF
[[ $? -eq 0 ]] && ok "report shape: schema, readonly, partitions, structural indicator, suspicious verdict" \
              || bad "report shape wrong"

# clean indicators -> triage-complete
bash -c "source \"$LIB\"
python3 - '$PARTS_MAP' <<'EOF'
import json, sys
json.dump({'1': [], '2': []}, open('/tmp/x-empty-inds.json', 'w'))
EOF
analyze_write_report \"$TMP\" \"$INV\" \"$PARTS_MAP\" /tmp/x-empty-inds.json" >/dev/null
[[ "$(python3 -c 'import json; print(json.load(open("'"$TMP/triage-report.json"'"))["verdict"])')" == "triage-complete" ]] \
  && ok "no findings -> verdict triage-complete" || bad "clean verdict wrong"

# --- 6. ro-mount helper --------------------------------------------------------------
echo "== ro-mount helper =="

gate "analyze_ro_mount /dev/sda1 ntfs \"$TMP/m\" \"rw\""; [[ $? -ne 0 ]] \
  && ok "analyze_ro_mount refuses rw options" || bad "analyze_ro_mount ACCEPTED rw"

gate "analyze_ro_mount /dev/sda1 ntfs \"$TMP/m\" \"ro,errors=remount-ro\""; [[ $? -ne 0 ]] \
  && ok "analyze_ro_mount refuses options containing rw as substring" || bad "rw-substring ACCEPTED"

# --- 7. end-to-end flow (mocked) -------------------------------------------------------
echo "== end-to-end flow =="

SCANROOT="$TMP/scanroot"; mkdir -p "$SCANROOT/sda2/Windows/Temp"
dd if=/dev/zero of="$SCANROOT/sda2/Windows/Temp/blob" bs=1K count=200 status=none 2>/dev/null
echo x > "$SCANROOT/sda2/autorun.inf"
STATE="$TMP/state"
PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="sdb1" \
PHOENIX_MOCK_PARTITIONS="$FIX/mock-partitions.txt" PHOENIX_MOCK_SCAN_ROOT="$SCANROOT" \
PHOENIX_MOCK_REPORT_DEVICE=/dev/sdc1 PHOENIX_ANALYZE_TEMP_MAX_KB=100 \
  bash "$FLOW" --save-state "$STATE" >/dev/null 2>&1
[[ $? -eq 0 && -f "$STATE/triage-report.json" ]] \
  && ok "flow runs fully mocked and writes triage-report.json" || bad "mocked flow failed"

bash "$FLOW" >/dev/null 2>&1; [[ $? -ne 0 ]] \
  && ok "flow without --save-state refuses to run" || bad "flow ran without --save-state"

echo "----------------------------------------"
echo "RESULT: $pass PASS / $fail FAIL"
[[ "$fail" -eq 0 ]]
