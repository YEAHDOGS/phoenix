#!/usr/bin/env bash
#===============================================================================
# test-phoenix-backup.sh -- regression suite for tools/phoenix-backup.sh
# (+ structural parity checks for the WinPE twin tools/New-PhoenixBackup.ps1)
#
# Uses small regular files as fake "disks" (--allow-file) -- no block devices,
# no root, nothing leaves /tmp. Exit 0 = all green.
#
# Usage: bash tests/tools/test-phoenix-backup.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/phoenix-backup.sh"
TWIN="$REPO/tools/New-PhoenixBackup.ps1"
PROOF="$REPO/tools/New-ImageProof.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-backup-test.XXXXXX)"
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

manifest_val() { grep -E "^$2=" "$1" | cut -d= -f2-; }

# --- fixture: 3.5 MiB fake disk ---------------------------------------------------
DISK="$TMP/disk.img"
head -c 3670016 /dev/urandom > "$DISK"
DISK_SHA="$(sha512sum "$DISK" | cut -d' ' -f1)"
SERIAL="TESTSERIAL001"

B() { "$TOOL" --source "$DISK" --source-serial "$SERIAL" --allow-file \
        --chunk-mib 1 --compressor none --operator tester "$@"; }

# T1: full run succeeds, chunks + manifest + proof land ---------------------------
OUT1="$TMP/img1"
run "full backup exits 0" 0 -- B --out "$OUT1" --proof-out "$TMP/proofs1"
[[ -f "$OUT1/backup.manifest" ]] && pass "manifest written" || fail "manifest written"
[[ "$(manifest_val "$OUT1/backup.manifest" format)" == "phoenix-backup/1" ]] \
    && pass "manifest format tag" || fail "manifest format tag"
[[ "$(manifest_val "$OUT1/backup.manifest" stream_sha512)" == "$DISK_SHA" ]] \
    && pass "stream SHA-512 matches source disk" || fail "stream SHA-512 matches source disk"
[[ "$(manifest_val "$OUT1/backup.manifest" verify)" == "PASS" ]] \
    && pass "manifest verify=PASS" || fail "manifest verify=PASS"
[[ "$(manifest_val "$OUT1/backup.manifest" chunk_count)" == "4" ]] \
    && pass "3.5MiB / 1MiB chunks = 4" || fail "chunk count"
ls "$OUT1"/chunk-*.img.raw >/dev/null 2>&1 && pass "4 chunk files exist" || fail "chunk files exist"
P1=( "$TMP"/proofs1/*.proof )
[[ -f "${P1[0]}" ]] && pass "nuke-gate proof minted" || fail "nuke-gate proof minted"
grep -q "^verified=YES$" "${P1[0]}" && pass "proof verified=YES" || fail "proof verified=YES"
grep -q "^source_serial=$SERIAL$" "${P1[0]}" && pass "proof binds source serial" || fail "proof serial binding"
[[ "$(manifest_val "$OUT1/backup.manifest" chunks_concat_sha256)" == "$(grep -E '^sha256=' "${P1[0]}" | cut -d= -f2)" ]] \
    && pass "proof sha256 == manifest chunks_concat_sha256" || fail "proof/manifest hash agreement"

# T2: idempotent re-run (all chunks already verified) -----------------------------
run "re-run with complete image exits 0" 0 -- B --out "$OUT1" --proof-out "$TMP/proofs1b"
[[ "$(manifest_val "$OUT1/backup.manifest" stream_sha512)" == "$DISK_SHA" ]] \
    && pass "re-run stream hash stable" || fail "re-run stream hash stable"

# T3: resume -- delete one chunk, re-run restores it -------------------------------
rm -f "$OUT1"/chunk-00002.img.raw
run "resume after chunk loss exits 0" 0 -- B --out "$OUT1" --proof-out "$TMP/proofs1c"
[[ -f "$OUT1/chunk-00002.img.raw" ]] \
    && pass "missing chunk re-imaged on resume" || fail "resume re-images chunk"
[[ "$(manifest_val "$OUT1/backup.manifest" stream_sha512)" == "$DISK_SHA" ]] \
    && pass "post-resume stream hash still matches disk" || fail "post-resume hash"

# T4: tamper -- corrupt a chunk file; resume must detect the hash mismatch,
# re-image that chunk from source, and only then verify+mint (fail-open would
# be: trust the corrupt chunk). A separate case below covers hard failure.
OUT4="$TMP/img4"
B --out "$OUT4" --proof-out "$TMP/proofs4" >/dev/null 2>&1
printf 'X' | dd of="$OUT4/chunk-00001.img.raw" bs=1 seek=100 conv=notrunc status=none 2>/dev/null
run "corrupted chunk detected and re-imaged" 0 -- B --out "$OUT4" --proof-out "$TMP/proofs4b"
[[ "$(manifest_val "$OUT4/backup.manifest" stream_sha512)" == "$DISK_SHA" ]] \
    && pass "post-heal stream hash still matches disk" || fail "post-heal stream hash"
[[ -n "$(ls "$TMP"/proofs4b/*.proof 2>/dev/null)" ]] \
    && pass "proof minted only after heal+verify" || fail "proof after heal"

# T4b: hard failure -- proof writer broken: run must FAIL CLOSED (exit 2),
# manifest may exist but no proof may be minted
OUT4B="$TMP/img4b"
run "broken proof writer fails closed" 2 -- B --out "$OUT4B" \
    --proof-out "$TMP/proofs4c" --proof-writer /bin/false
[[ -z "$(ls "$TMP"/proofs4c/*.proof 2>/dev/null)" ]] \
    && pass "no proof minted when minting fails" || fail "no proof on mint failure"

# T5: validation gates --------------------------------------------------------------
run "missing source fails" 1 -- B --source "$TMP/nope.img" --out "$TMP/o5"
run "missing serial fails" 1 -- "$TOOL" --source "$DISK" --allow-file --out "$TMP/o6"
run "bad serial chars fail" 1 -- "$TOOL" --source "$DISK" --source-serial 'a/b' --allow-file --out "$TMP/o7"
run "bad compressor fails" 1 -- B --compressor lz4 --out "$TMP/o8"
run "block-device gate without --allow-file fails" 1 -- \
    "$TOOL" --source "$DISK" --source-serial "$SERIAL" --out "$TMP/o9"
run "wrong serial vs state fails" 1 -- \
    "$TOOL" --source "$DISK" --source-serial OTHERSERIAL --allow-file --out "$OUT1"
run "--help exits 0" 0 -- "$TOOL" --help

# T6: gzip path (compressor actually engaged) ---------------------------------------
OUT6="$TMP/img6"
run "gzip backup exits 0" 0 -- B --out "$OUT6" --proof-out "$TMP/proofs6" --compressor gzip
[[ "$(manifest_val "$OUT6/backup.manifest" compressor)" == "gzip" ]] \
    && pass "manifest records gzip" || fail "manifest records gzip"
[[ "$(manifest_val "$OUT6/backup.manifest" stream_sha512)" == "$DISK_SHA" ]] \
    && pass "gzip round-trip stream hash matches disk" || fail "gzip round-trip"

# T7: structural parity with the WinPE twin (no pwsh on this box -- grep contract) --
[[ -f "$TWIN" ]] && pass "WinPE twin exists" || fail "WinPE twin exists"
for key in 'format=phoenix-backup/1' 'stream_sha512' 'source_serial' 'image_name' \
           'phoenix-image-proof/1' 'verified=YES' 'chunks_concat_sha256'; do
    grep -q "$key" "$TWIN" && pass "twin carries '$key'" || fail "twin carries '$key'"
done
for flag in '\-Source\b' '\-SourceSerial\b' '\-Out\b' '\-Operator\b'; do
    grep -q -- "$flag" "$TWIN" && pass "twin exposes '$flag'" || fail "twin exposes '$flag'"
done

# T8: secrets hygiene -- no credentials baked into tool/test ------------------------
if grep -rEi '(password|passwd|secret|api[_-]?key|bearer)[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']+["'"'"']' \
        "$TOOL" "$TWIN" "$0" | grep -vi 'no password\|passwords:' >/dev/null; then
    fail "secrets hygiene" "credential-looking assignment found"
else
    pass "secrets hygiene (no credential literals)"
fi

echo "PASS: $PASS  FAIL: $FAIL"
(( FAIL == 0 ))
