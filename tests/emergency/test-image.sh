#!/usr/bin/env bash
#===============================================================================
# test-image.sh -- smoke/regression suite for scripts/emergency/image_disk.sh
#
# Images small file-backed "disks" (no root needed, no real hardware touched),
# exercises the safety interlocks, and verifies the SHA-256 manifest contract
# is interchangeable with scripts/checksum/check.sh + compare.sh.
#
# No network, no installs. Run from the repo root:
#   ./tests/emergency/test-image.sh
#===============================================================================
set -u
SCRIPT="scripts/emergency/image_disk.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
no()   { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$(dirname "$0")/../.." || exit 1

# --- fixture: an 8 MiB file-backed "disk" --------------------------------------
dd if=/dev/urandom of="$TMP/disk-a.img" bs=1M count=8 status=none

echo "== test-image.sh =="

# 1. happy path: image + manifest written, exit 0 ------------------------------
export PHOENIX_FIXTURE_CONFIRM="disk-a.img FILE-BACKED-DISK"
if "$SCRIPT" --src "$TMP/disk-a.img" --dest-dir "$TMP/out" --label snap1 --verify >/dev/null 2>&1; then
    ok "happy path exit 0"
else
    no "happy path exit 0 (got $?)"
fi
unset PHOENIX_FIXTURE_CONFIRM

# 2. image content matches source (dd conv=sync pads the short final block to
#    bs, so compare only the source's own byte count) ---------------------------
SRC_BYTES="$(stat -c%s "$TMP/disk-a.img")"
if cmp -s -n "$SRC_BYTES" "$TMP/disk-a.img" "$TMP/out/snap1.img"; then
    ok "image content matches source (first $SRC_BYTES bytes)"
else
    no "image content matches source (first $SRC_BYTES bytes)"
fi

# 3. manifest hash matches independent sha256sum --------------------------------
MAN_HASH="$(awk -F, 'NR==2 {gsub(/"/,""); print $2}' "$TMP/out/snap1.manifest.csv")"
REAL_HASH="$(sha256sum "$TMP/out/snap1.img" | awk '{print $1}')"
if [[ "$MAN_HASH" == "$REAL_HASH" && -n "$MAN_HASH" ]]; then
    ok "manifest hash matches independent sha256sum"
else
    no "manifest hash matches independent sha256sum (manifest=$MAN_HASH real=$REAL_HASH)"
fi

# 4. manifest contract: check.sh + compare.sh verify it -------------------------
./scripts/checksum/check.sh "$TMP/out/snap1.img" --out "$TMP/check-out.csv" >/dev/null 2>&1
CHECK_HASH="$(awk -F, 'NR==2 {gsub(/"/,""); gsub(/\r/,""); print $2}' "$TMP/check-out.csv")"
if [[ "$CHECK_HASH" == "$REAL_HASH" ]]; then
    ok "check.sh produces identical hash (contract parity)"
else
    no "check.sh produces identical hash (contract parity)"
fi
if ./scripts/checksum/compare.sh "$TMP/out/snap1.manifest.csv" >/dev/null 2>&1; then
    ok "compare.sh verifies the imager's manifest"
else
    no "compare.sh verifies the imager's manifest"
fi

# 5. manifest CSV header is exactly Path,Hash -----------------------------------
if head -1 "$TMP/out/snap1.manifest.csv" | grep -qx "Path,Hash"; then
    ok "manifest header is Path,Hash"
else
    no "manifest header is Path,Hash"
fi

# 6. --dry-run writes nothing ----------------------------------------------------
export PHOENIX_FIXTURE_CONFIRM="disk-a.img FILE-BACKED-DISK"
if "$SCRIPT" --src "$TMP/disk-a.img" --dest-dir "$TMP/dry" --label snap2 --dry-run >/dev/null 2>&1 \
   && [[ ! -e "$TMP/dry/snap2.img" ]]; then
    ok "--dry-run writes nothing"
else
    no "--dry-run writes nothing"
fi
unset PHOENIX_FIXTURE_CONFIRM

# 7. wrong confirmation -> exit 3 -----------------------------------------------
export PHOENIX_FIXTURE_CONFIRM="WRONG STRING"
"$SCRIPT" --src "$TMP/disk-a.img" --dest-dir "$TMP/out7" --label snap7 >/dev/null 2>&1
if [[ $? -eq 3 ]]; then ok "wrong confirmation -> exit 3"; else no "wrong confirmation -> exit 3 (got $?)"; fi
unset PHOENIX_FIXTURE_CONFIRM

# 8. missing source -> exit 2 -----------------------------------------------------
export PHOENIX_FIXTURE_CONFIRM="nope FILE-BACKED-DISK"
"$SCRIPT" --src "$TMP/does-not-exist.img" --dest-dir "$TMP/out8" --label snap8 >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "missing source -> exit 2"; else no "missing source -> exit 2 (got $?)"; fi
unset PHOENIX_FIXTURE_CONFIRM

# 9. existing destination -> exit 4 (no overwrite) --------------------------------
export PHOENIX_FIXTURE_CONFIRM="disk-a.img FILE-BACKED-DISK"
"$SCRIPT" --src "$TMP/disk-a.img" --dest-dir "$TMP/out" --label snap1 >/dev/null 2>&1
if [[ $? -eq 4 ]]; then ok "existing destination -> exit 4"; else no "existing destination -> exit 4 (got $?)"; fi
unset PHOENIX_FIXTURE_CONFIRM

# 10. missing --label -> exit 2 ----------------------------------------------------
export PHOENIX_FIXTURE_CONFIRM="disk-a.img FILE-BACKED-DISK"
"$SCRIPT" --src "$TMP/disk-a.img" --dest-dir "$TMP/out10" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "missing --label -> exit 2"; else no "missing --label -> exit 2 (got $?)"; fi
unset PHOENIX_FIXTURE_CONFIRM

echo ""
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ))
