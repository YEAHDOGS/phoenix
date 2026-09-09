#!/usr/bin/env bash
#===============================================================================
# test-phoenix-quarantine-copy.sh -- regression suite for
# tools/phoenix-quarantine-copy.sh (runbook Step 2.7)
#
# Builds a tiny REAL image with tools/phoenix-backup.sh (regular-file source
# via --allow-file) so the quarantine tool is tested against the genuine
# manifest/state contract. Everything lives in /tmp -- no block devices,
# no root, no network, nothing leaves /tmp. Exit 0 = all green.
#
# Usage: bash tests/tools/test-phoenix-quarantine-copy.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/phoenix-quarantine-copy.sh"
BACKUP="$REPO/tools/phoenix-backup.sh"
PROOF="$REPO/tools/New-ImageProof.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-quarantine-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
chmod +x "$TOOL" "$BACKUP" "$PROOF"

run() {  # run <name> <expected-exit> -- <cmd...>: records PASS/FAIL
    local name="$1" want="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == want )); then pass "$name (exit $rc)";
    else fail "$name" "want exit $want, got $rc :: $out"; fi
}

manifest_val() { grep -E "^$2=" "$1" | cut -d= -f2-; }

# --- fixture: a real verified image (3 MiB source, 1 MiB chunks, gzip) -----------
SRCFILE="$TMP/fake-disk.img"
head -c $((3*1024*1024)) /dev/urandom > "$SRCFILE"
IMG="$TMP/laptop-fulldisk-2026-09-09"
QDATE="2026-09-09"
run "fixture: phoenix-backup.sh images the fake disk" 0 -- \
    "$BACKUP" --source "$SRCFILE" --allow-file --source-serial QTEST001 \
    --out "$IMG" --chunk-mib 1 --compressor gzip --operator tester \
    --proof-out "$TMP/proofs"
Q() { "$TOOL" --source "$1" --target "$2" --date "$QDATE" --operator tester "${@:3}"; }

# --- T1: happy path ---------------------------------------------------------------
TGT1="$TMP/castle"
mkdir -p "$TGT1"
run "quarantine copy exits 0" 0 -- Q "$IMG" "$TGT1"
DEST1="$TGT1/QUARANTINE-INFECTED-$QDATE/laptop-fulldisk-2026-09-09"
[[ -d "$DEST1" ]] && pass "quarantine layout created" || fail "quarantine layout created"
M1="$DEST1/quarantine-copy.manifest"
[[ -f "$M1" ]] && pass "quarantine-copy.manifest written" || fail "quarantine-copy.manifest written"
[[ "$(manifest_val "$M1" format)" == "phoenix-quarantine-copy/1" ]] \
    && pass "manifest format tag" || fail "manifest format tag"
[[ "$(manifest_val "$M1" verify)" == "PASS" ]] \
    && pass "manifest verify=PASS" || fail "manifest verify=PASS"
[[ "$(manifest_val "$M1" evidence)" == "manifest" ]] \
    && pass "evidence=manifest" || fail "evidence=manifest"
[[ "$(manifest_val "$M1" chunk_count)" == "3" ]] \
    && pass "chunk_count=3" || fail "chunk count"
[[ "$(manifest_val "$M1" source_stream_sha512)" == "$(manifest_val "$IMG/backup.manifest" stream_sha512)" ]] \
    && pass "stream hash recorded from source manifest" || fail "stream hash recorded"
[[ -f "$DEST1/backup.manifest" && -f "$DEST1/.phoenix-backup.state" && -f "$DEST1/copy.log" ]] \
    && pass "sidecar files copied (manifest, state, log)" || fail "sidecar files copied"
for c in "$IMG"/chunk-*.img.gz; do
    bn="$(basename "$c")"
    [[ "$(sha512sum "$c" | cut -d' ' -f1)" == "$(sha512sum "$DEST1/$bn" | cut -d' ' -f1)" ]] \
        && pass "chunk byte-identical: $bn" || fail "chunk byte-identical: $bn"
done

# --- T2: idempotent re-run --------------------------------------------------------
run "re-run on complete copy exits 0" 0 -- Q "$IMG" "$TGT1"
[[ "$(manifest_val "$M1" verify)" == "PASS" ]] \
    && pass "manifest still PASS after re-run" || fail "manifest still PASS"

# --- T3: corrupted target chunk is detected and re-copied ------------------------
echo "CORRUPTION" >> "$DEST1/chunk-00000.img.gz"
run "re-run after corruption exits 0 (recovers)" 0 -- Q "$IMG" "$TGT1"
src_h="$(sha512sum "$IMG/chunk-00000.img.gz" | cut -d' ' -f1)"
dst_h="$(sha512sum "$DEST1/chunk-00000.img.gz" | cut -d' ' -f1)"
[[ "$src_h" == "$dst_h" ]] && pass "corrupted chunk re-copied byte-identical" \
    || fail "corrupted chunk re-copied"
[[ "$(manifest_val "$M1" verify)" == "PASS" ]] \
    && pass "manifest PASS after recovery" || fail "manifest PASS after recovery"

# --- T4: unverified image is refused ----------------------------------------------
IMG_BAD="$TMP/img-unverified"
cp -r "$IMG" "$IMG_BAD"
sed -i 's/^verify=PASS$/verify=FAIL/' "$IMG_BAD/backup.manifest"
TGT4="$TMP/castle4"; mkdir -p "$TGT4"
run "manifest verify=FAIL refused" 1 -- Q "$IMG_BAD" "$TGT4"
[[ ! -e "$TGT4/QUARANTINE-INFECTED-$QDATE" ]] \
    && pass "nothing written on refusal" || fail "nothing written on refusal"

# --- T5: no evidence at all is refused --------------------------------------------
IMG_NONE="$TMP/img-noevidence"
mkdir -p "$IMG_NONE"
echo "x" > "$IMG_NONE/chunk-00000.img.gz"
TGT5="$TMP/castle5"; mkdir -p "$TGT5"
run "no manifest and no --image-proof refused" 1 -- Q "$IMG_NONE" "$TGT5"

# --- T6: proof path with verified=NO is refused -----------------------------------
IMG_GUI="$TMP/img-gui"
mkdir -p "$IMG_GUI"
cp "$IMG"/chunk-*.img.gz "$IMG_GUI"/
"$PROOF" --image-name rescuezilla-img --image-path "$IMG_GUI" \
    --source-serial QTEST001 --sha256 "$(sha256sum "$SRCFILE" | cut -d' ' -f1)" \
    --verified-by tester --out "$TMP" >/dev/null
NOPROOF="$(ls "$TMP"/image-proof-QTEST001-*.proof | head -1)"
TGT6="$TMP/castle6"; mkdir -p "$TGT6"
run "proof with verified=NO refused" 1 -- Q "$IMG_GUI" "$TGT6" --image-proof "$NOPROOF"

# --- T7: proof path with verified=YES works ---------------------------------------
"$PROOF" --image-name rescuezilla-img --image-path "$IMG_GUI" \
    --source-serial QTEST001 --sha256 "$(sha256sum "$SRCFILE" | cut -d' ' -f1)" \
    --verified --verified-by tester --out "$TMP" >/dev/null
YESPROOF="$(ls -t "$TMP"/image-proof-QTEST001-*.proof | head -1)"
run "verified proof path exits 0" 0 -- Q "$IMG_GUI" "$TGT6" --image-proof "$YESPROOF"
DEST7="$TGT6/QUARANTINE-INFECTED-$QDATE/img-gui"
M7="$DEST7/quarantine-copy.manifest"
[[ "$(manifest_val "$M7" evidence)" == "proof" && "$(manifest_val "$M7" verify)" == "PASS" ]] \
    && pass "proof evidence recorded, verify=PASS" || fail "proof evidence recorded"
[[ -f "$DEST7/$(basename "$YESPROOF")" ]] \
    && pass "proof file copied alongside image" || fail "proof file copied"

# --- T8: path-safety refusals -----------------------------------------------------
run "target == source refused" 1 -- Q "$IMG" "$IMG"
run "target inside source refused" 1 -- Q "$IMG" "$IMG/nested"
mkdir -p "$TGT1/inner"
run "source inside target refused" 1 -- Q "$TGT1" "$TGT1/inner"

# --- T9: bad date refused ----------------------------------------------------------
run "bad --date refused" 1 -- Q "$IMG" "$TGT1" --date "yesterday"

# --- T10: missing args -------------------------------------------------------------
run "missing --target refused" 1 -- "$TOOL" --source "$IMG"
run "missing --source refused" 1 -- "$TOOL" --target "$TGT1"

# --- T11: empty source dir refused --------------------------------------------------
IMG_EMPTY="$TMP/img-empty"; mkdir -p "$IMG_EMPTY"
run "source with no chunks refused" 1 -- Q "$IMG_EMPTY" "$TGT1"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
