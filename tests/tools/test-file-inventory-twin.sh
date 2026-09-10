#!/usr/bin/env bash
#===============================================================================
# test-file-inventory-twin.sh -- regression suite for tools/New-FileInventory.sh
# (+ structural parity checks for the Windows twin tools/New-FileInventory.ps1)
#
# The inventory JSON is a pinned contract: key order, ISO-8601 UTC stamps,
# path sorting, and the created_utc=null-on-Linux rule. A drift in any of
# these between the twins silently breaks cross-platform inventory diffing,
# so this suite pins the .sh behavior functionally AND the .sh<->.ps1
# contract statically. (No pwsh on this box -- the .ps1 half is a static
# contract check, same as test-image-proof-twin.sh does for its twin.)
#
# Nothing destructive, nothing leaves /tmp. Exit 0 = all green.
#
# Usage: bash tests/tools/test-file-inventory-twin.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/New-FileInventory.sh"
TWIN="$REPO/tools/New-FileInventory.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-inv-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
chmod +x "$TOOL"

run() {  # run <name> <expected-exit> -- <cmd...>: records PASS/FAIL
    local name="$1" want="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == want )); then pass "$name (exit $rc)";
    else fail "$name" "want exit $want, got $rc :: $out"; fi
}

# --- fixture: dir tree with edge-case names ------------------------------------
FIX="$TMP/tree"
mkdir -p "$FIX/sub/nested" "$FIX/emptydir"
printf 'hello' > "$FIX/a.txt"
printf 'world!' > "$FIX/sub/b.txt"
printf 'deep' > "$FIX/sub/nested/c.dat"
printf 'hidden' > "$FIX/.hidden"
printf 'sp ace' > "$FIX/with space.txt"
printf 'uni' > "$FIX/ünïcodé.txt"
ln -s a.txt "$FIX/link-to-a" 2>/dev/null || true
# fixed mtime so assertions are deterministic
touch -d '2026-09-09 20:30:00 UTC' "$FIX/a.txt"

EXPECTED_COUNT="$(find "$FIX" -mindepth 0 | wc -l)"

# --- T1: directory inventory ---------------------------------------------------
run "dir inventory exits 0" 0 -- "$TOOL" --path "$FIX" --out "$TMP/inv.json"
[[ -f "$TMP/inv.json" ]] && pass "inventory file lands" || fail "inventory file lands"

python3 - "$TMP/inv.json" "$EXPECTED_COUNT" <<'PYEOF'
import json, re, sys
inv = json.load(open(sys.argv[1]))
want = int(sys.argv[2])
keys = ['path', 'type', 'size_bytes', 'modified_utc', 'created_utc']
iso = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
errs = []
if len(inv) != want:
    errs.append(f"count: want {want}, got {len(inv)}")
paths = [e['path'] for e in inv]
if paths != sorted(paths):
    errs.append("paths not sorted")
if any(list(e.keys()) != keys for e in inv):
    errs.append("key order drift")
if any(not e['path'].startswith('/') for e in inv):
    errs.append("non-absolute path")
if any(e['type'] not in ('file', 'directory', 'symlink', 'other') for e in inv):
    errs.append("bad type value")
if any(e['type'] == 'file' and not isinstance(e['size_bytes'], int) for e in inv):
    errs.append("file without int size_bytes")
if any(e['type'] != 'file' and e['size_bytes'] is not None for e in inv):
    errs.append("non-file with non-null size_bytes")
if any(not iso.match(e['modified_utc']) for e in inv):
    errs.append("modified_utc not ISO-8601 UTC")
if any(e['created_utc'] is not None for e in inv):
    errs.append("created_utc should be null on Linux")
by = {e['path']: e for e in inv}
a = None
for p, e in by.items():
    if p.endswith('/a.txt'):
        a = e
if a is None:
    errs.append("a.txt entry missing")
else:
    if a['type'] != 'file' or a['size_bytes'] != 5:
        errs.append(f"a.txt wrong type/size: {a['type']}/{a['size_bytes']}")
    if a['modified_utc'] != '2026-09-09T20:30:00Z':
        errs.append(f"a.txt wrong mtime: {a['modified_utc']}")
if not any(p.endswith('/emptydir') and by[p]['type'] == 'directory' for p in by):
    errs.append("emptydir entry missing/wrong")
if not any('with space.txt' in p for p in by):
    errs.append("space filename missing")
if not any('ünïcodé.txt' in p for p in by):
    errs.append("unicode filename missing")
if not any(p.endswith('/.hidden') for p in by):
    errs.append("hidden file missing")
if errs:
    print("CONTRACT DRIFT: " + "; ".join(errs))
    sys.exit(1)
print(f"contract OK: {len(inv)} entries")
PYEOF
(( $? == 0 )) && pass "JSON contract pinned" || fail "JSON contract pinned"

# --- T2: single file input -> exactly one entry --------------------------------
run "single file exits 0" 0 -- "$TOOL" --path "$FIX/a.txt" --out "$TMP/one.json"
N="$(python3 -c "import json; print(len(json.load(open('$TMP/one.json'))))")"
[[ "$N" == "1" ]] && pass "single file yields 1 entry" || fail "single file yields 1 entry" "got $N"

# --- T3/T4: validation failures -------------------------------------------------
run "missing path exits 1" 1 -- "$TOOL" --path "$TMP/nope" --out "$TMP/x.json"
run "no --path exits 1" 1 -- "$TOOL" --out "$TMP/x.json"
run "unknown flag exits 1" 1 -- "$TOOL" --bogus

# --- T5: default --out naming ---------------------------------------------------
(cd "$TMP" && run "default out name exits 0" 0 -- "$TOOL" --path "$FIX")
ls "$TMP"/tree-inventory-[0-9]*T[0-9]*Z.json >/dev/null 2>&1 \
    && pass "default filename pattern" \
    || fail "default filename pattern" "$(ls "$TMP"/*.json 2>/dev/null | tr '\n' ' ')"

# --- T6: .ps1 static contract parity (no pwsh on this box) ----------------------
grep -q '\[ordered\]@{' "$TWIN" && pass "ps1 preserves key order" || fail "ps1 preserves key order"
for k in path type size_bytes modified_utc created_utc; do
    grep -Eq "^[[:space:]]*$k[[:space:]]*=" "$TWIN" \
        && pass "ps1 key '$k' present" || fail "ps1 key '$k' present"
done
grep -q 'yyyy-MM-ddTHH:mm:ssZ' "$TWIN" \
    && pass "ps1 ISO-8601 UTC format" || fail "ps1 ISO-8601 UTC format"
grep -q 'Sort-Object path' "$TWIN" \
    && pass "ps1 sorts by path" || fail "ps1 sorts by path"
grep -q 'ConvertTo-Json' "$TWIN" \
    && pass "ps1 emits JSON" || fail "ps1 emits JSON"
grep -q 'Mandatory = \$true' "$TWIN" && grep -q '\[string\]$OutFile' "$TWIN" \
    && pass "ps1 params -Path/-OutFile" || fail "ps1 params -Path/-OutFile"
grep -q 'CreationTimeUtc' "$TWIN" \
    && pass "ps1 uses real CreationTimeUtc" || fail "ps1 uses real CreationTimeUtc"

echo "--- $PASS passed, $FAIL failed ---"
(( FAIL == 0 ))
