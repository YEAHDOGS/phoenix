#!/usr/bin/env bash
#===============================================================================
# test-image-proof-twin.sh -- regression suite for tools/New-ImageProof.sh
# (+ structural parity checks for the WinPE twin tools/New-ImageProof.ps1)
#
# The image-proof manifest is the artifact the nuke image-proof gate consumes
# (runbook invariant 1: verified image or no wipe). A drift in keys, order,
# or filename between the twins silently breaks the Linux-side gate, so this
# suite pins the .sh behavior functionally AND the .sh<->.ps1 contract.
# (No pwsh on this box -- the .ps1 half is a static contract check, same as
# test-phoenix-backup.sh does for its twin.)
#
# Nothing destructive, nothing leaves /tmp. Exit 0 = all green.
#
# Usage: bash tests/tools/test-image-proof-twin.sh
#===============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/tools/New-ImageProof.sh"
TWIN="$REPO/tools/New-ImageProof.ps1"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

TMP="$(mktemp -d /tmp/phx-proof-test.XXXXXX)"
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

# --- fixture: fake image dir (2 files) -----------------------------------------
IMG="$TMP/laptop-fulldisk-2026-09-09"
mkdir -p "$IMG"
head -c 1048576 /dev/urandom > "$IMG/part1.img"
head -c 524288  /dev/urandom > "$IMG/part2.img"
SHA="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
SERIAL="TESTSERIAL002"

P() { "$TOOL" --image-name laptop-fulldisk-2026-09-09 --image-path "$IMG" \
        --source-serial "$SERIAL" --sha256 "$SHA" --out "$TMP" "$@"; }

# --- T1: verified run: exact key order, verified=YES ---------------------------
run "verified proof exits 0" 0 -- P --verified --verified-by tester
F=( "$TMP"/image-proof-"$SERIAL"-*.proof )
[[ -f "${F[0]}" ]] && pass "proof file lands" || fail "proof file lands"
[[ "${F[0]}" =~ image-proof-${SERIAL}-[0-9]{8}T[0-9]{6}Z\.proof$ ]] \
    && pass "filename pattern matches .sh convention" \
    || fail "filename pattern" "${F[0]}"
# size normalization: the sed block above rewrites the real du size to the
# DSIZE placeholder, so EXPECT keeps the placeholder too (no DUSIZE needed)
EXPECT=$'# phoenix image-proof manifest -- written by New-ImageProof.sh\n# keep on the Phoenix USB; pass to Invoke-Nuke.sh --image-proof\nformat=phoenix-image-proof/1\nimage_name=laptop-fulldisk-2026-09-09\nimage_path=IMG\nsource_serial=TESTSERIAL002\nsource_dev=\nimage_size_bytes=DSIZE\nsha256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\ncreated_utc=TS\nverified=YES\nverified_by=tester'
{
    sed -e "s|^image_path=.*|image_path=IMG|" -e "s|^created_utc=.*|created_utc=TS|" \
        -e "s|^image_size_bytes=.*|image_size_bytes=DSIZE|" "${F[0]}"
} > "$TMP/normalized"
printf '%s\n' "$EXPECT" > "$TMP/expected"
if diff -q "$TMP/expected" "$TMP/normalized" >/dev/null; then
    pass "proof content byte-exact (keys, order, values)"
else
    fail "proof content byte-exact" "$(diff "$TMP/expected" "$TMP/normalized" | head -6 | tr '\n' ';')"
fi

# --- T2: unverified run: written but gate-rejectable ----------------------------
# NOTE: proof filenames carry a 1-second timestamp; two runs in the same second
# collide on the filename, so only assert on the newest file's content.
run "unverified proof exits 0" 0 -- P --verified-by tester
NEWEST="$(ls -t "$TMP"/image-proof-"$SERIAL"-*.proof | head -1)"
[[ -f "$NEWEST" ]] && pass "proof file present" || fail "proof file present"
grep -q '^verified=NO$' "$NEWEST" && pass "unverified run records verified=NO" \
    || fail "unverified run records verified=NO"
OUT2="$(P 2>&1)"; echo "$OUT2" | grep -q 'verified=NO -- the nuke image-proof gate will REJECT' \
    && pass "unverified run warns on stdout" || fail "unverified warning"

# --- T3: fail-closed validation -------------------------------------------------
run "missing --image-name fails"   1 -- "$TOOL" --image-path "$IMG" --source-serial "$SERIAL" --sha256 "$SHA" --out "$TMP"
run "missing --image-path fails"   1 -- "$TOOL" --image-name x --source-serial "$SERIAL" --sha256 "$SHA" --out "$TMP"
run "missing --source-serial fails" 1 -- "$TOOL" --image-name x --image-path "$IMG" --sha256 "$SHA" --out "$TMP"
run "missing --sha256 fails"       1 -- "$TOOL" --image-name x --image-path "$IMG" --source-serial "$SERIAL" --out "$TMP"
run "short sha256 fails"           1 -- "$TOOL" --image-name x --image-path "$IMG" --source-serial "$SERIAL" --sha256 deadbeef --out "$TMP"
run "non-hex sha256 fails"         1 -- "$TOOL" --image-name x --image-path "$IMG" --source-serial "$SERIAL" --sha256 "$(printf 'zz%.0s' {1..32})" --out "$TMP"
run "missing image path fails"     1 -- "$TOOL" --image-name x --image-path "$TMP/nope" --source-serial "$SERIAL" --sha256 "$SHA" --out "$TMP"
run "bad --out dir fails"          1 -- "$TOOL" --image-name x --image-path "$IMG" --source-serial "$SERIAL" --sha256 "$SHA" --out "$TMP/nope"
run "unknown flag fails"           1 -- "$TOOL" --bogus

# --- T4: single-file image + explicit size override ----------------------------
ONE="$TMP/single.img"; head -c 65536 /dev/urandom > "$ONE"
run "single-file image exits 0" 0 -- "$TOOL" --image-name single --image-path "$ONE" \
    --source-serial FILE001 --sha256 "$SHA" --verified --out "$TMP" >/dev/null
S1=( "$TMP"/image-proof-FILE001-*.proof )
grep -q '^image_size_bytes=65536$' "${S1[0]}" && pass "file size read from file" \
    || fail "file size" "$(grep '^image_size_bytes' "${S1[0]}")"
run "size override exits 0" 0 -- "$TOOL" --image-name ovr --image-path "$ONE" \
    --source-serial OVR001 --sha256 "$SHA" --image-size-bytes 12345 --verified --out "$TMP" >/dev/null
S2=( "$TMP"/image-proof-OVR001-*.proof )
grep -q '^image_size_bytes=12345$' "${S2[0]}" && pass "explicit size override wins" \
    || fail "size override"

# --- T5: twin structural parity (static -- no pwsh on this box) ----------------
[[ -f "$TWIN" ]] && pass "WinPE twin exists" || fail "WinPE twin exists"
for key in format image_name image_path source_serial source_dev \
           image_size_bytes sha256 created_utc verified_by; do
    grep -qE "^[[:space:]\"']*$key=" "$TWIN" && pass "twin writes '$key='" || fail "twin writes '$key='"
done
# 'verified' is dynamic in both twins ($verifiedLine in .ps1, branch in .sh) --
# pin the emitted spellings instead of a literal line
grep -q "'verified=YES'" "$TWIN" && grep -q "'verified=NO'" "$TWIN" \
    && pass "twin writes 'verified=' (YES/NO spellings)" || fail "twin verified spellings"
for flag in '\$ImageName\b' '\$ImagePath\b' '\$SourceSerial\b' '\$SourceDev\b' \
            '\$Sha256\b' '\$ImageSizeBytes\b' '\$VerifiedBy\b' '\$OutDir\b' '\$Verified\b'; do
    grep -q -- "$flag" "$TWIN" && pass "twin exposes '$flag'" || fail "twin exposes '$flag'"
done
# key ORDER must be identical across twins (the nuke gate is positional-tolerant,
# but humans diff these files -- order drift is how bugs hide)
sh_order="$(grep -oE '^[[:space:]]*echo "(format|image_name|image_path|source_serial|source_dev|image_size_bytes|sha256|created_utc)=' "$TOOL" | grep -oE '(format|image_name|image_path|source_serial|source_dev|image_size_bytes|sha256|created_utc)')"
ps_order="$(grep -oE "^[[:space:]]*[\"']?(format|image_name|image_path|source_serial|source_dev|image_size_bytes|sha256|created_utc)=" "$TWIN" | grep -oE '(format|image_name|image_path|source_serial|source_dev|image_size_bytes|sha256|created_utc)')"
[[ "$sh_order" == "$ps_order" ]] && pass "twin key order identical" \
    || fail "twin key order" "$(echo "$sh_order" | tr '\n' ',') vs $(echo "$ps_order" | tr '\n' ',')"
grep -q "written by New-ImageProof.ps1" "$TWIN" \
    && pass "twin self-identifies in header" || fail "twin header"
grep -q 'image-proof-.*\.proof' "$TWIN" \
    && pass "twin uses same filename pattern" || fail "twin filename pattern"
grep -q "yyyyMMddTHHmmssZ" "$TWIN" \
    && pass "twin uses UTC filename timestamp" || fail "twin timestamp format"
grep -q 'exit 1' "$TWIN" && pass "twin fails closed (exit 1)" || fail "twin exit 1"
grep -q -- '-LiteralPath' "$TWIN" \
    && pass "twin uses -LiteralPath (no wildcard injection)" || fail "twin -LiteralPath"

# --- T6: credential-literal hygiene ---------------------------------------------
# flags keyword = 'value' assignments only (a looser grep self-matches on the
# test's own label text; an assignment is the actual leak shape)
if grep -rEi '(password|passwd|secret|api[_-]?key|bearer)[[:space:]]*=[[:space:]]*["'"'"'"][^"'"'"'"]+["'"'"'"]' \
        "$TOOL" "$TWIN" "$0" | grep -vi 'no password\|passwords:' >/dev/null; then
    fail "no credential literals" "$(grep -rEi "(password|passwd|secret|api[_-]?key|bearer)[[:space:]]*=" "$TOOL" "$TWIN" | head -2)"
else
    pass "no credential literals"
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
exit $(( FAIL > 0 ))
