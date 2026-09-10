#!/usr/bin/env bash
#===============================================================================
# test-quarantine-copy-twin.sh -- regression suite for
# tools/phoenix-quarantine-copy.sh (+ static contract parity for the Windows
# twin tools/New-PhoenixQuarantineCopy.ps1). Runbook Step 2.7.
#
# Builds a REAL verified image fixture from scratch (3 x 1 MiB gzip chunks,
# genuine phoenix-backup/1 manifest + .phoenix-backup.state with real
# SHA-512s) -- no dependency on phoenix-backup.sh, everything in /tmp,
# no block devices, no root, no network. Exit 0 = all green.
#
# The quarantine-copy.manifest is a pinned contract: key order must match
# between the twins, and verify=PASS may appear ONLY after verification
# passes. No pwsh on this box -- the .ps1 half is a static contract check,
# same as test-file-inventory-twin.sh does for its twin.
#
# Usage: bash tests/tools/test-quarantine-copy-twin.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/phoenix-quarantine-copy.sh"
TWIN="$REPO/tools/New-PhoenixQuarantineCopy.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-qcopy-test.XXXXXX)"
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

mval() { grep -E "^$2=" "$1" | cut -d= -f2-; }

# --- fixture: genuine verified image (3 MiB raw, 3 x 1 MiB gzip chunks) --------
IMG="$TMP/laptop-fulldisk-2026-09-09"
mkdir -p "$IMG"
# deterministic pseudo-random bytes (reproducible fixture)
python3 - "$IMG" <<'PYEOF'
import gzip, hashlib, sys
img = sys.argv[1]
raw = bytearray()
x = 0x243F6A88
for _ in range(3 * 1024 * 1024):
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF
    raw.append(x >> 16 & 0xFF)
pieces = [bytes(raw[i:i + 1024 * 1024]) for i in range(0, len(raw), 1024 * 1024)]
stream = hashlib.sha512()
chunks_concat = hashlib.sha256()
state = []
for i, p in enumerate(pieces):
    comp = gzip.compress(p, compresslevel=6)   # fixed level -> stable bytes
    name = "chunk-%05d.img.gz" % i
    open(f"{img}/{name}", "wb").write(comp)
    stream.update(p)
    chunks_concat.update(comp)
    rsha = hashlib.sha512(p).hexdigest()
    csha = hashlib.sha512(comp).hexdigest()
    state.append(f"chunk\t{i}\t{name}\t{rsha}\t{csha}\t{len(p)}\t{len(comp)}")
open(f"{img}/.phoenix-backup.state", "w").write("\n".join(state) + "\n")
man = "\n".join([
    "format=phoenix-backup/1",
    "image_name=laptop-fulldisk-2026-09-09",
    "source_serial=QTEST001",
    f"stream_sha512={stream.hexdigest()}",
    f"chunks_concat_sha256={chunks_concat.hexdigest()}",
    "compressor=gzip",
    "verify=PASS",
]) + "\n"
open(f"{img}/backup.manifest", "w").write(man)
print("fixture ok")
PYEOF
[[ -f "$IMG/backup.manifest" && -f "$IMG/.phoenix-backup.state" ]] \
    && pass "fixture minted (3 chunks, real manifest+state)" \
    || { echo "fixture minting failed"; exit 1; }

QDATE="2026-09-09"
Q() { "$TOOL" --source "$1" --target "$2" --date "$QDATE" --operator tester "${@:3}"; }
TGT1="$TMP/castle"; mkdir -p "$TGT1"

# --- T1: happy path ---------------------------------------------------------------
run "quarantine copy exits 0" 0 -- Q "$IMG" "$TGT1"
DEST1="$TGT1/QUARANTINE-INFECTED-$QDATE/laptop-fulldisk-2026-09-09"
[[ -d "$DEST1" ]] && pass "quarantine layout created" || fail "quarantine layout created"
M1="$DEST1/quarantine-copy.manifest"
[[ -f "$M1" ]] && pass "quarantine-copy.manifest written" || fail "quarantine-copy.manifest written"
[[ "$(mval "$M1" format)" == "phoenix-quarantine-copy/1" ]] \
    && pass "manifest format tag" || fail "manifest format tag"
[[ "$(mval "$M1" verify)" == "PASS" ]] \
    && pass "manifest verify=PASS" || fail "manifest verify=PASS"
[[ "$(mval "$M1" evidence)" == "manifest" ]] \
    && pass "evidence=manifest" || fail "evidence=manifest"
[[ "$(mval "$M1" chunk_count)" == "3" ]] \
    && pass "chunk_count=3" || fail "chunk count"
[[ "$(mval "$M1" source_serial)" == "QTEST001" ]] \
    && pass "source_serial carried" || fail "source serial"
[[ "$(mval "$M1" source_stream_sha512)" == "$(mval "$IMG/backup.manifest" stream_sha512)" ]] \
    && pass "stream hash recorded from source manifest" || fail "stream hash recorded"
[[ "$(mval "$M1" source_chunks_concat_sha256)" == "$(mval "$IMG/backup.manifest" chunks_concat_sha256)" ]] \
    && pass "concat hash recorded from source manifest" || fail "concat hash recorded"
[[ "$(mval "$M1" tool)" == "phoenix-quarantine-copy.sh" ]] \
    && pass "tool tag records the .sh twin" || fail "tool tag"
[[ -f "$DEST1/backup.manifest" && -f "$DEST1/.phoenix-backup.state" && -f "$DEST1/copy.log" ]] \
    && pass "sidecar files copied (manifest, state, log)" || fail "sidecar files copied"
for c in "$IMG"/chunk-*.img.gz; do
    bn="$(basename "$c")"
    [[ "$(sha512sum "$c" | cut -d' ' -f1)" == "$(sha512sum "$DEST1/$bn" | cut -d' ' -f1)" ]] \
        && pass "chunk byte-identical: $bn" || fail "chunk byte-identical: $bn"
done
# pinned manifest key order (contract shared with the .ps1 twin)
python3 - "$M1" <<'PYEOF'
import sys
keys = [l.split('=')[0] for l in open(sys.argv[1]) if '=' in l and not l.startswith('#')]
want = ['format','image_name','source_dir','target_dir','quarantine_date','evidence',
        'source_serial','chunk_count','bytes_copied','source_stream_sha512',
        'source_chunks_concat_sha256','target_fs_type','tool','created_utc',
        'operator','verify']
assert keys == want, f"manifest key order drift: {keys}"
print("manifest key order pinned OK")
PYEOF
(( $? == 0 )) && pass "manifest key order pinned" || fail "manifest key order pinned"

# --- T2: idempotent re-run ----------------------------------------------------------
run "re-run on complete copy exits 0" 0 -- Q "$IMG" "$TGT1"
[[ "$(mval "$M1" verify)" == "PASS" ]] \
    && pass "manifest still PASS after re-run" || fail "manifest still PASS"

# --- T3: corrupted target chunk is detected and re-copied --------------------------
echo "CORRUPTION" >> "$DEST1/chunk-00000.img.gz"
run "re-run after corruption exits 0 (recovers)" 0 -- Q "$IMG" "$TGT1"
[[ "$(sha512sum "$IMG/chunk-00000.img.gz" | cut -d' ' -f1)" == "$(sha512sum "$DEST1/chunk-00000.img.gz" | cut -d' ' -f1)" ]] \
    && pass "corrupted chunk re-copied byte-identical" || fail "corrupted chunk re-copied"
[[ "$(mval "$M1" verify)" == "PASS" ]] \
    && pass "manifest PASS after recovery" || fail "manifest PASS after recovery"

# --- T4: unverified image is refused (exit 1) ---------------------------------------
IMG_BAD="$TMP/img-unverified"; cp -r "$IMG" "$IMG_BAD"
sed -i 's/^verify=PASS$/verify=FAIL/' "$IMG_BAD/backup.manifest"
TGT4="$TMP/castle4"; mkdir -p "$TGT4"
run "manifest verify=FAIL refused" 1 -- Q "$IMG_BAD" "$TGT4"
[[ ! -e "$TGT4/QUARANTINE-INFECTED-$QDATE" ]] \
    && pass "nothing written on refusal" || fail "nothing written on refusal"

# --- T5: no evidence at all is refused ----------------------------------------------
IMG_NONE="$TMP/img-noevidence"; mkdir -p "$IMG_NONE"
echo "x" > "$IMG_NONE/chunk-00000.img.gz"
TGT5="$TMP/castle5"; mkdir -p "$TGT5"
run "no manifest and no --image-proof refused" 1 -- Q "$IMG_NONE" "$TGT5"

# --- T6: proof path, verified=NO refused --------------------------------------------
IMG_GUI="$TMP/img-gui"; mkdir -p "$IMG_GUI"
cp "$IMG"/chunk-*.img.gz "$IMG_GUI"/
cat > "$TMP/proof-no.proof" <<'EOF'
format=phoenix-image-proof/1
image_name=rescuezilla-img
source_serial=QTEST001
verified=NO
EOF
TGT6="$TMP/castle6"; mkdir -p "$TGT6"
run "proof with verified=NO refused" 1 -- Q "$IMG_GUI" "$TGT6" --image-proof "$TMP/proof-no.proof"

# --- T7: proof path, verified=YES works ---------------------------------------------
cat > "$TMP/proof-yes.proof" <<'EOF'
format=phoenix-image-proof/1
image_name=rescuezilla-img
source_serial=QTEST001
verified=YES
EOF
run "verified proof path exits 0" 0 -- Q "$IMG_GUI" "$TGT6" --image-proof "$TMP/proof-yes.proof"
DEST7="$TGT6/QUARANTINE-INFECTED-$QDATE/img-gui"
M7="$DEST7/quarantine-copy.manifest"
[[ "$(mval "$M7" evidence)" == "proof" && "$(mval "$M7" verify)" == "PASS" ]] \
    && pass "proof evidence recorded, verify=PASS" || fail "proof evidence recorded"
[[ -f "$DEST7/proof-yes.proof" ]] \
    && pass "proof file copied alongside image" || fail "proof file copied"
[[ "$(mval "$M7" image_proof)" == "proof-yes.proof" ]] \
    && pass "image_proof basename in manifest" || fail "image_proof in manifest"

# --- T8: path-safety refusals (exit 1) -----------------------------------------------
run "target == source refused" 1 -- Q "$IMG" "$IMG"
run "target inside source refused" 1 -- Q "$IMG" "$IMG/nested"
mkdir -p "$TGT1/inner"
run "source inside target refused" 1 -- Q "$TGT1" "$TGT1/inner"

# --- T9: bad date / missing args / empty source (exit 1) ----------------------------
run "bad --date refused" 1 -- Q "$IMG" "$TGT1" --date "yesterday"
run "missing --target refused" 1 -- "$TOOL" --source "$IMG"
run "missing --source refused" 1 -- "$TOOL" --target "$TGT1"
IMG_EMPTY="$TMP/img-empty"; mkdir -p "$IMG_EMPTY"
run "source with no chunks refused" 1 -- Q "$IMG_EMPTY" "$TGT1"

# --- T10: tampered SOURCE chunk -> stream verify fails (exit 2) ----------------------
IMG_TAMP="$TMP/img-tampered"; cp -r "$IMG" "$IMG_TAMP"
head -c 100 "$IMG/chunk-00000.img.gz" > "$IMG_TAMP/chunk-00000.img.gz"
TGT10="$TMP/castle10"; mkdir -p "$TGT10"
run "tampered source chunk fails stream verify" 2 -- Q "$IMG_TAMP" "$TGT10"
[[ ! -f "$TGT10/QUARANTINE-INFECTED-$QDATE/laptop-fulldisk-2026-09-09/quarantine-copy.manifest" ]] \
    && pass "no PASS manifest on failed verification" || fail "no PASS manifest on failed verification"

# --- T11: state-file hash mismatch -> per-chunk verify fails (exit 2) ----------------
IMG_ST="$TMP/img-badstate"; cp -r "$IMG" "$IMG_ST"
sed -i "s/^\(chunk\t0\tchunk-00000.img.gz\t[0-9a-f]*\t\)[0-9a-f]*/\1deadbeef/" "$IMG_ST/.phoenix-backup.state"
TGT11="$TMP/castle11"; mkdir -p "$TGT11"
run "state hash mismatch refused" 2 -- Q "$IMG_ST" "$TGT11"

# --- T12: .ps1 twin static contract parity (no pwsh on this box) --------------------
# The manifest keys in the .ps1 $lines array must appear in the exact order
# the .sh emits them (tool value differs by twin, so compare keys only).
python3 - "$TOOL" "$TWIN" <<'PYEOF'
import re, sys
sh = open(sys.argv[1]).read()
ps = open(sys.argv[2]).read()
sh_keys = re.findall(r'^\s*(?:\[\[ [^\n]*\]\] && )?echo "([a-z_]+)=', sh, re.M)
# restrict to the manifest block (after the pinned-contract comment)
start = ps.index('quarantine-copy manifest (written ONLY after verification passes)')
block = ps[start:]
ps_keys = re.findall(r'''["']([a-z_]+)=[^"']*["']''', block)
errs = []
if 'format=phoenix-quarantine-copy/1' not in ps:
    errs.append("ps1 missing format tag")
if [k for k in ps_keys if k == 'format'] != ['format']:
    errs.append("ps1 format key placement drift")
sh_order = [k for k in sh_keys if k in
    ('format','image_name','source_dir','target_dir','quarantine_date','evidence',
     'source_serial','chunk_count','bytes_copied','source_stream_sha512',
     'source_chunks_concat_sha256','image_proof','target_fs_type','tool',
     'created_utc','operator','verify')]
ps_order = [k for k in ps_keys if k in
    ('format','image_name','source_dir','target_dir','quarantine_date','evidence',
     'source_serial','chunk_count','bytes_copied','source_stream_sha512',
     'source_chunks_concat_sha256','image_proof','target_fs_type','tool',
     'created_utc','operator','verify')]
# .sh emits evidence-dependent keys conditionally; check the union order of the
# always-emitted keys matches.
always = ('format','image_name','source_dir','target_dir','quarantine_date','evidence',
          'source_serial','chunk_count','bytes_copied','target_fs_type','tool',
          'created_utc','operator','verify')
if [k for k in sh_order if k in always] != [k for k in ps_order if k in always]:
    errs.append(f"manifest key order drift sh<->ps1: {sh_order} vs {ps_order}")
if errs:
    print("TWIN DRIFT: " + "; ".join(errs)); sys.exit(1)
print("twin manifest key-order parity OK")
PYEOF
(( $? == 0 )) && pass "ps1 manifest key-order parity" || fail "ps1 manifest key-order parity"

grep -q 'tool=New-PhoenixQuarantineCopy.ps1' "$TWIN" \
    && pass "ps1 tool tag names the ps1 twin" || fail "ps1 tool tag"
for k in source_stream_sha512 source_chunks_concat_sha256 image_proof; do
    grep -q "\"$k=" "$TWIN" \
        && pass "ps1 evidence-conditional key '$k'" || fail "ps1 evidence-conditional key '$k'"
done
grep -q "SHA512" "$TWIN" && grep -q "SHA256" "$TWIN" \
    && pass "ps1 hashes SHA-512/SHA-256" || fail "ps1 hash algorithms"
grep -q "GZipStream" "$TWIN" \
    && pass "ps1 gzip decompression path" || fail "ps1 gzip path"
grep -q "phoenix-image-proof/1" "$TWIN" && grep -q "phoenix-backup/1" "$TWIN" \
    && pass "ps1 evidence formats" || fail "ps1 evidence formats"
grep -q "verified" "$TWIN" && grep -q "verify=PASS" "$TWIN" \
    && pass "ps1 fail-closed verify checks" || fail "ps1 verify checks"
grep -q "DriveType\]::Network" "$TWIN" \
    && pass "ps1 refuses network drives" || fail "ps1 network-drive refusal"
grep -q '\\\\' "$TWIN" && grep -q "UNC" "$TWIN" \
    && pass "ps1 refuses UNC paths" || fail "ps1 UNC refusal"
grep -q "INSIDE" "$TWIN" \
    && pass "ps1 path-containment refusals" || fail "ps1 containment refusals"
grep -q "free" "$TWIN" -i && grep -q "AvailableFreeSpace" "$TWIN" \
    && pass "ps1 free-space preflight" || fail "ps1 preflight"
grep -q 'exit \$code' "$TWIN" && grep -Eq '\[int\]\$code = 1' "$TWIN" && grep -q '" 2' "$TWIN" \
    && pass "ps1 exit-code contract (default 1 validation, 2 copy/verify)" || fail "ps1 exit codes"
grep -q "QUARANTINE-INFECTED" "$TWIN" \
    && pass "ps1 quarantine label layout" || fail "ps1 quarantine layout"
grep -q "copy.log" "$TWIN" \
    && pass "ps1 run log (copy.log)" || fail "ps1 run log"
grep -q "Get-ChildItem" "$TWIN" && grep -q "chunk-\*.img.\*" "$TWIN" \
    && pass "ps1 chunk inventory glob" || fail "ps1 chunk glob"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
