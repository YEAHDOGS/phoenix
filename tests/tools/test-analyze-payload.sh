#!/usr/bin/env bash
#===============================================================================
# test-analyze-payload.sh -- regression harness for tools/Invoke-Analyze.sh
# (+ static contract checks for tools/Invoke-Analyze.ps1)
#
# The Analyze module is READ-ONLY by construction, so the harness focuses on
# the identity contract it shares with Invoke-Nuke.sh / Invoke-Backup.sh:
#   - enumeration correctness on both paths (lsblk JSON + /sys fallback)
#   - empty-field fidelity: a disk with null model/serial must show '?' and
#     must NOT shift fields or trigger false DUP-SERIAL (regression: bash
#     IFS-whitespace collapsing used to eat empty fields)
#   - JSON boolean fidelity: lsblk rota=false must map to media SSD, not
#     "unknown" (regression: `or ""` dropped JSON false)
#   - boot-USB marking via row number, /dev node, or serial
#   - DUP-SERIAL flagging without refusal (analyze never destroys)
#   - config honesty: --config validates and requires boot_entries.analyze
#   - fail-closed: empty enumeration refuses, no partial report lands
#   - read-only guarantee: no destructive primitives in code (static)
#   - report atomicity: temp+rename, JSON-parseable or nothing lands
#   - .ps1 twin: no destructive cmdlets, report_version parity, param contract
#
# Nothing here can destroy data: all disks are fake /sys fixtures or mock
# lsblk JSON. The real host's disks are only ever READ via lsblk in one
# case-free... (no: the JSON mock fully replaces lsblk; the host is untouched).
#
# Usage: bash tests/tools/test-analyze-payload.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ANALYZE="$REPO/tools/Invoke-Analyze.sh"
ANALYZE_PS1="$REPO/tools/Invoke-Analyze.ps1"
FIX="$REPO/tests/config/fixtures"
T="$(mktemp -d /tmp/phoenix-analyze-test.XXXXXX)"
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN" "$T/sys/block" "$T/proc" "$T/dev" "$T/out"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- preflight -----------------------------------------------------------------
echo "== preflight =="
[[ -f "$ANALYZE" ]] || { echo "FATAL: $ANALYZE not found"; exit 1; }
[[ -f "$ANALYZE_PS1" ]] || { echo "FATAL: $ANALYZE_PS1 not found"; exit 1; }
bash -n "$ANALYZE" && pass "bash -n syntax check" || fail "bash -n syntax check"
for cmd in python3 mktemp; do
    command -v "$cmd" >/dev/null 2>&1 \
        && pass "preflight: $cmd present" \
        || fail "preflight: $cmd present" "$cmd is required"
done

#--- fixture: fake /sys + /proc + /dev ------------------------------------------
mkdisk() {  # mkdisk <name> <sectors> <model> <serial> <rotational> <removable>
    local n="$1"
    mkdir -p "$T/sys/block/$n/device" "$T/sys/block/$n/queue"
    echo "$2" > "$T/sys/block/$n/size"
    echo "$5" > "$T/sys/block/$n/queue/rotational"
    echo "$6" > "$T/sys/block/$n/removable"
    printf '%s' "$3" > "$T/sys/block/$n/device/model"
    printf '%s' "$4" > "$T/sys/block/$n/device/serial"
}
mkdisk nvme0n1 2000409264 "Samsung SSD 970 EVO Plus 1TB" "S6P7NX0T123456A" 0 0
mkdisk sda      121634816  "SanDisk Ultra Fit"             "4C530001230719115224" 0 1
printf 'processor\t: 0\nmodel name\t: Intel(R) Core(TM) i7-12700K\n' > "$T/proc/cpuinfo"
printf 'MemTotal:        32648752 kB\n' > "$T/proc/meminfo"
: > "$T/proc/mounts"
mkdir -p "$T/sys/class/dmi/id"
printf 'Dell Inc.' > "$T/sys/class/dmi/id/bios_vendor"
printf '2.4.0'     > "$T/sys/class/dmi/id/bios_version"
printf 'XPS 8950'  > "$T/sys/class/dmi/id/product_name"
mkdir -p "$T/sys/class/net/eth0" "$T/sys/class/net/lo"
echo down > "$T/sys/class/net/eth0/operstate"
echo unknown > "$T/sys/class/net/lo/operstate"
touch "$T/dev/tpm0"

export PHOENIX_SYSFS_ROOT="$T/sys" PHOENIX_PROC_ROOT="$T/proc" PHOENIX_DEV_ROOT="$T/dev"
export PHOENIX_TOOLS_DIR="$REPO/tools"

# lsblk that always fails -> forces the /sys fallback path
printf '#!/bin/bash\nexit 1\n' > "$MOCKBIN/lsblk"
chmod +x "$MOCKBIN/lsblk"
run_fb() { PATH="$MOCKBIN:/usr/bin:/bin" bash "$ANALYZE" "$@"; }

#--- A. sysfs fallback enumeration + report ------------------------------------
echo "== A: sysfs fallback =="
OUT="$(run_fb 2>&1)" && pass "A1 enumerate exit 0" || fail "A1 enumerate exit 0"
echo "$OUT" | grep -q "nvme0n1" && pass "A2 table lists nvme0n1" || fail "A2 table lists nvme0n1"
echo "$OUT" | grep -q "S6P7NX0T123456A" && pass "A2 table lists serial" || fail "A2 table lists serial"
OUT="$(run_fb --boot-device sda 2>&1)"
echo "$OUT" | grep -q "BOOT-USB" && pass "A3 --boot-device marks BOOT-USB" || fail "A3 --boot-device marks BOOT-USB"
OUT="$(run_fb --boot-device 4C530001230719115224 2>&1)"
echo "$OUT" | grep -q "BOOT-USB" && pass "A3b serial resolves to BOOT-USB" || fail "A3b serial resolves to BOOT-USB"

rm -f "$T/out"/*.json
run_fb --write --out "$T/out" --boot-device sda >/dev/null 2>&1 \
    && pass "A4 --write exit 0" || fail "A4 --write exit 0"
REPORT="$(ls "$T"/out/phoenix-analyze-report-*.json 2>/dev/null | head -1)"
[[ -n "$REPORT" ]] || fail "A4 report file landed" "no report"
python3 -m json.tool "$REPORT" >/dev/null 2>&1 \
    && pass "A4 report parses as JSON" || fail "A4 report parses as JSON"
python3 - "$REPORT" <<'EOF' || exit 1
import json,sys
r=json.load(open(sys.argv[1]))
assert r["report"]=="phoenix-analyze-report", "report tag"
assert r["report_version"]==1, "report_version"
assert r["tool"].startswith("Invoke-Analyze.sh "), "tool tag"
d=r["disks"]
assert len(d)==2, f"disk count {len(d)}"
assert d[0]["serial"]=="S6P7NX0T123456A", "nvme serial"
assert d[0]["media"]=="SSD", "nvme media"
assert d[1]["is_boot_usb"] is True, "sda is_boot_usb"
assert d[1]["model"]=="SanDisk Ultra Fit", "sda model"
assert d[0]["is_boot_usb"] is False, "nvme not boot usb"
assert r["machine"]["system_product"]=="XPS 8950", "dmi product"
assert r["machine"]["tpm"]=="present", "tpm"
assert any("lsblk unavailable" in n for n in r["notes"]), "fallback note"
EOF
[[ $? -eq 0 ]] && pass "A5 report content (serials/media/boot-usb/notes)" \
               || fail "A5 report content (serials/media/boot-usb/notes)"
ls "$T/out"/.analyze-report.* >/dev/null 2>&1 \
    && fail "A6 no temp files left behind" "temp file present" \
    || pass "A6 no temp files left behind"

#--- B. duplicate serials flag without refusal -----------------------------------
echo "== B: duplicate serials =="
mkdisk sdb 62533296 "Spare SSD" "S6P7NX0T123456A" 0 0
OUT="$(run_fb 2>&1)" && RC=0 || RC=$?
[[ $RC -eq 0 ]] && pass "B1 dup serials: still exit 0 (read-only)" || fail "B1 dup serials: exit $RC"
echo "$OUT" | grep -q "DUP-SERIAL" && pass "B2 table flags DUP-SERIAL" || fail "B2 table flags DUP-SERIAL"
echo "$OUT" | grep -q "identity ambiguous" && pass "B3 note explains ambiguity" || fail "B3 note explains ambiguity"
rm -rf "$T/sys/block/sdb"   # back to the 2-disk fixture

#--- C. lsblk JSON path: empty-field + boolean fidelity --------------------------
echo "== C: lsblk JSON path =="
cat > "$MOCKBIN/lsblk" <<'MOCK'
#!/bin/bash
cat <<'JSON'
{"blockdevices":[
 {"name":"nvme0n1","size":1024209543168,"model":"Samsung SSD 970 EVO Plus 1TB","serial":"S6P7NX0T123456A","tran":"nvme","rota":false,"rm":false},
 {"name":"sda","size":62277025792,"model":null,"serial":null,"tran":"usb","rota":false,"rm":true}
]}
JSON
MOCK
chmod +x "$MOCKBIN/lsblk"
OUT="$(run_fb 2>&1)" && RC=0 || RC=$?
[[ $RC -eq 0 ]] && pass "C1 lsblk path exit 0" || fail "C1 lsblk path exit $RC"
# The null model/serial disk must show '?' in the right columns, not shift fields:
echo "$OUT" | grep -E "^2 +/dev/sda +\? + +\? " >/dev/null \
    && pass "C2 empty serial/model show '?' without shifting" \
    || fail "C2 empty serial/model show '?' without shifting" "$OUT"
echo "$OUT" | grep -q "DUP-SERIAL" \
    && fail "C3 no false DUP-SERIAL on empty serials" "flagged" \
    || pass "C3 no false DUP-SERIAL on empty serials"
echo "$OUT" | grep -E "^1 +/dev/nvme0n1 +S6P7NX0T123456A" | grep -q "SSD" \
    && pass "C4 rota=false maps to SSD (boolean fidelity)" \
    || fail "C4 rota=false maps to SSD (boolean fidelity)"
rm -f "$T/out"/*.json
run_fb --write --out "$T/out" >/dev/null 2>&1
REPORT="$(ls "$T"/out/phoenix-analyze-report-*.json 2>/dev/null | head -1)"
python3 - "$REPORT" <<'EOF' || exit 1
import json,sys
r=json.load(open(sys.argv[1]))
d=r["disks"]
assert d[1]["serial"]=="", "empty serial stays empty in JSON"
assert d[1]["media"]=="SSD", "JSON false rota -> SSD"
assert d[1]["removable"] is True, "rm true -> removable"
assert d[0]["transport"]=="nvme", "transport preserved"
EOF
[[ $? -eq 0 ]] && pass "C5 JSON report: empty serial, SSD, removable" \
               || fail "C5 JSON report: empty serial, SSD, removable"

#--- D. config honesty ------------------------------------------------------------
echo "== D: config honesty =="
python3 - "$FIX/valid-full.json" "$T/analyze-disabled.json" <<'EOF'
import json,sys
cfg=json.load(open(sys.argv[1])); cfg["boot_entries"]["analyze"]=False
json.dump(cfg,open(sys.argv[2],"w"))
EOF
printf 'not json' > "$T/bad.json"
OUT="$(run_fb --config "$FIX/valid-full.json" 2>&1)" && RC=0 || RC=$?
[[ $RC -eq 0 ]] && pass "D1 analyze-enabled config accepted" || fail "D1 analyze-enabled config exit $RC"
OUT="$(run_fb --config "$T/analyze-disabled.json" 2>&1)" && RC=0 || RC=$?
[[ $RC -ne 0 ]] && pass "D2 analyze=false config refused" || fail "D2 analyze=false config refused"
echo "$OUT" | grep -qi "not enabled" && pass "D2b refusal names the policy" || fail "D2b refusal names the policy"
OUT="$(run_fb --config "$T/bad.json" 2>&1)" && RC=0 || RC=$?
[[ $RC -ne 0 ]] && pass "D3 malformed config refused" || fail "D3 malformed config refused"
OUT="$(run_fb --config "$T/nope.json" 2>&1)" && RC=0 || RC=$?
[[ $RC -ne 0 ]] && pass "D4 missing config refused" || fail "D4 missing config refused"

#--- E. empty enumeration fails closed ----------------------------------------------
echo "== E: fail closed =="
printf '#!/bin/bash\nexit 1\n' > "$MOCKBIN/lsblk"; chmod +x "$MOCKBIN/lsblk"
mkdir -p "$T/empty/block"
PHOENIX_SYSFS_ROOT="$T/empty" run_fb >/dev/null 2>&1 && RC=0 || RC=$?
[[ $RC -ne 0 ]] && pass "E1 no disks: exit non-zero" || fail "E1 no disks: exit $RC"
rm -f "$T/out"/*.json
PHOENIX_SYSFS_ROOT="$T/empty" run_fb --write --out "$T/out" >/dev/null 2>&1 && RC=0 || RC=$?
[[ $RC -ne 0 ]] && pass "E2 no disks --write: exit non-zero" || fail "E2 no disks --write: exit $RC"
ls "$T"/out/phoenix-analyze-report-*.json >/dev/null 2>&1 \
    && fail "E3 no partial report lands" "report exists" \
    || pass "E3 no partial report lands"

#--- F. read-only static guarantee ----------------------------------------------------
echo "== F: read-only static =="
# Strip comments; then no destructive primitive may appear as a command word.
# (Reading /proc/mounts and the variable named $mounts are the read-only
# mount-*detection*, not mounting -- the regex demands a word boundary so
# "mounts"/"mounted"/"Never mounts," in prose do not match.)
sed 's/#.*//' "$ANALYZE" > "$T/code.sh"
if grep -nE '(^|[^a-zA-Z0-9_])(mount|mkfs|wipefs|shred|hdparm)([^a-zA-Z0-9_]|$)|nvme[[:space:]]+(format|sanitize)([^a-zA-Z0-9_]|$)|(^|[^a-zA-Z0-9_])dd[[:space:]]' "$T/code.sh" | grep -qv 'PROCFS/mounts'; then
    fail "F1 no destructive primitives in code" "$(grep -nE '(^|[^a-zA-Z0-9_])(mount|mkfs|wipefs|shred|hdparm)([^a-zA-Z0-9_]|$)' "$T/code.sh" | head -3)"
else
    pass "F1 no destructive primitives in code"
fi
grep -q 'suspect OS never booted' "$ANALYZE" \
    && pass "F2 read-only contract stated" || fail "F2 read-only contract stated"

#--- G. .ps1 twin static contract -------------------------------------------------------
echo "== G: ps1 twin =="
python3 - "$ANALYZE_PS1" <<'EOF' || exit 1
import re,sys
src=open(sys.argv[1]).read()
# strip block comments <# ... #> and line comments
src=re.sub(r'<#.*?#>', '', src, flags=re.S)
src="\n".join(re.sub(r'#.*$', '', l) for l in src.splitlines())
bad=re.findall(r'(?i)\b(Format-Volume|Format-|Clear-Disk|Initialize-Disk|Remove-Partition|Set-Disk|New-Partition|Clear-Content)\b|diskpart', src)
assert not bad, f"destructive cmdlets present: {bad}"
assert 'report_version' in src and '= 1' in src, "report_version 1"
for p in ('Write','OutDir','BootDevice','Config','ImageProof'):
    assert re.search(r'\[' + 'string' + r'\]\$'+p + r'|\$'+p, src), f"param {p}"
assert src.count('{')==src.count('}'), "brace balance"
EOF
[[ $? -eq 0 ]] && pass "G1 ps1: no destructive cmdlets, version/parity/params" \
               || fail "G1 ps1: no destructive cmdlets, version/parity/params"

#--- H. image-proof hint ----------------------------------------------------------------
echo "== H: image-proof hint =="
OUT="$(run_fb --image-proof "$T/nope.proof" 2>&1)" && RC=0 || RC=$?
[[ $RC -eq 0 ]] && pass "H1 missing proof: exit 0 (hint only)" || fail "H1 missing proof exit $RC"
echo "$OUT" | grep -q "missing or invalid" && pass "H2 missing proof noted" || fail "H2 missing proof noted"
# Real proof via the real writer:
printf 'x%.0s' $(seq 1 64) > "$T/fake.img"
SHA="$(sha256sum "$T/fake.img" | cut -d' ' -f1)"
bash "$REPO/tools/New-ImageProof.sh" --image-name test --image-path "$T/fake.img" \
    --source-serial S6P7NX0T123456A --sha256 "$SHA" --verified --out "$T" >/dev/null 2>&1
PROOF="$(ls "$T"/*.proof 2>/dev/null | head -1)"
if [[ -n "$PROOF" ]]; then
    pass "H3 proof generated by New-ImageProof.sh"
    rm -f "$T/out"/*.json
    run_fb --write --out "$T/out" --image-proof "$PROOF" >/dev/null 2>&1
    REPORT="$(ls "$T"/out/phoenix-analyze-report-*.json 2>/dev/null | head -1)"
    python3 - "$REPORT" <<'EOF' || exit 1
import json,sys
r=json.load(open(sys.argv[1]))
ip=r["image_proof"]
assert ip["provided"] is True and ip["valid"] is True, f"proof valid {ip}"
assert ip["source_serial"]=="S6P7NX0T123456A", "serial recorded"
EOF
    [[ $? -eq 0 ]] && pass "H4 valid proof recorded in report" || fail "H4 valid proof recorded in report"
    printf 'format=phoenix-image-proof/1\nverified=NO\nsha256=%s\nsource_serial=S6P7NX0T123456A\nimage_size_bytes=64\n' "$SHA" > "$T/unverified.proof"
    rm -f "$T/out"/*.json
    run_fb --write --out "$T/out" --image-proof "$T/unverified.proof" >/dev/null 2>&1
    REPORT="$(ls "$T"/out/phoenix-analyze-report-*.json 2>/dev/null | head -1)"
    python3 - "$REPORT" <<'EOF' || exit 1
import json,sys
r=json.load(open(sys.argv[1]))
assert r["image_proof"]["valid"] is False, "unverified proof invalid"
assert any("missing or invalid" in n for n in r["notes"]), "noted"
EOF
    [[ $? -eq 0 ]] && pass "H5 unverified proof treated as absent" || fail "H5 unverified proof treated as absent"
else
    fail "H3 proof generated by New-ImageProof.sh" "no .proof file"
fi

#--- summary ----------------------------------------------------------------------
echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "FAILED: ${FAILED_CASES[*]}"
    exit 1
fi
echo "All analyze payload regression tests green."
