#!/usr/bin/env bash
#===============================================================================
# test-nuke-interlocks.sh -- regression harness for tools/Invoke-Nuke.sh
#
# Tests the NUKE safety interlocks WITHOUT any destructive path, on this
# machine, with a mocked `lsblk`. Nothing here can destroy data:
#   - no real block devices are ever named as targets (fixture uses fake
#     /dev/sd* paths that do not exist on the host),
#   - nwipe/hdparm/nvme-cli are absent, and the harness REFUSES to run if any
#     of them is present (so the armed path can never execute),
#   - the container has no block devices at all, so the script's own
#     "not a block device" gate fires before any confirmation prompt.
#
# Coverage:
#   UNIT (functions sourced from the real script, `main` stripped):
#     classify_media, method_for (+ --method overrides), nist_level_for,
#     human_size, parent_disk (lsblk hit + sed fallback), resolve_id,
#     typed_confirmation (pipe-fed input refused -- serial, "yes", and
#     "NUKE <serial>" -- on non-TTY stdin; wrong serial refused and correct
#     serial / "NUKE <serial>" accepted on a real pty).
#     check_image_proof (fixtures written by the REAL tools/New-ImageProof.sh:
#     valid proof passes; missing file, verified=NO, tampered sha256, zero
#     size, unknown format, and serial-mismatch proofs are all refused).
#   INTEGRATION (subprocess, mocked lsblk fixture: sda=HDD, sdb=boot USB
#     (mounted), nvme0n1=NVMe SSD, sdd=mounted data SSD):
#     dry-run enumeration, --whatif, boot-USB structural refusal,
#     mounted-partition refusal (by row and by /dev path), unknown id,
#     out-of-range row, bad --method, missing --nuke arg, gate ordering,
#     nuke-without-proof refused, missing/wrong-serial proof refused,
#     valid proof passes the image gate (next gate fires), piped
#     --skip-image-gate refused.
#   STICK POLICY (--config, phoenix-config.json; SAFETY interlock 12):
#   UNIT (sourced functions): load_usb_config (valid config loads policy,
#     serial normalization, invalid/missing config refused), normalize_serial,
#     check_usb_config_policy (nuke-disabled stick refuses, allowlist miss
#     refuses, allowlist hit passes, skip-gate compiled out refuses
#     --skip-image-gate, skip-gate enabled passes the policy check).
#   INTEGRATION (subprocess, mocked lsblk): nuke-disabled config refuses,
#     allowlist miss refuses, allowlist hit reaches the block-device gate,
#     --skip-image-gate refused when compiled out, piped skip still refused
#     on a real-console check when the hatch is enabled, invalid config
#     refused, missing config refused.
#
# Deliberately NOT covered here (VM-only, see docs/NUKE-TEST-PLAN.md T5-T8):
#   typed-confirmation accept/abort against a real block device, and any
#   destructive method execution. Those need QEMU throwaway images and must
#   never run on bare metal. (The pipe/pty confirmation matrix IS covered
#   in the unit section above; it just cannot prove the device-exists path.)
#
# Usage: bash tests/tools/test-nuke-interlocks.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NUKE="$REPO/tools/Invoke-Nuke.sh"
T="$(mktemp -d /tmp/phoenix-nuke-test.XXXXXX)"
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- preflight -----------------------------------------------------------------
echo "== preflight =="
[[ -f "$NUKE" ]] || { echo "FATAL: $NUKE not found"; exit 1; }
bash -n "$NUKE" && pass "bash -n syntax check" || fail "bash -n syntax check"
[[ $EUID -eq 0 ]] && pass "running as root (script requirement)" \
    || fail "running as root (script requirement)" "script refuses non-root; run with sudo"
for tool in nwipe hdparm nvme; do
    if command -v "$tool" >/dev/null 2>&1; then
        fail "preflight: $tool absent" "$tool is installed -- armed paths could execute; refusing to run"
    fi
done
pass "preflight: nwipe/hdparm/nvme absent (armed paths cannot execute)"

#--- mock lsblk ----------------------------------------------------------------
cat > "$MOCKBIN/lsblk" <<'MOCK'
#!/usr/bin/env bash
# Fixture: sda = SATA HDD, sdb = boot USB (mounted), nvme0n1 = NVMe SSD,
#          sdd = mounted data SSD. /dev/vda is the (real) container root disk.
args="$*"
last="${@: -1}"
case "$args" in
  *"-ndo PKNAME"*)
    case "$last" in
      /dev/vda) echo vda ;; /dev/sda1) echo sda ;; /dev/sdd1) echo sdd ;;
      *) echo "" ;;  # e.g. /dev/nvme0n1p2 -> empty, exercises the sed fallback
    esac ;;
  *"-dnr -o PATH"*)
    printf '%s\n' /dev/sda /dev/sdb /dev/nvme0n1 /dev/sdd ;;
  *"-nr -o MOUNTPOINTS"*)
    case "$last" in
      /dev/sdb) echo "/media/phoenix-usb" ;;
      /dev/sdd) echo "/mnt/data" ;;
    esac ;;
  *"-dnro TRAN"*)
    case "$last" in
      /dev/sda) echo sata ;; /dev/sdb) echo usb ;; /dev/nvme0n1) echo nvme ;;
      /dev/sdd) echo sata ;; /dev/vda) echo virtio ;; *) echo "" ;;
    esac ;;
  *"-dnro RM"*)
    if [[ "$last" == /dev/sdb ]]; then echo 1; else echo 0; fi ;;
  *"-dnro SERIAL"*)
    case "$last" in
      /dev/sda) echo SATATEST001 ;; /dev/sdb) echo USBTEST002 ;;
      /dev/nvme0n1) echo NVMETEST003 ;; /dev/sdd) echo SDDTEST004 ;;
      /dev/vda) echo VDA000 ;; *) echo "" ;;
    esac ;;
  *"-dnro ROTA"*)
    case "$last" in /dev/sda|/dev/sdb) echo 1 ;; *) echo 0 ;; esac ;;
  *"-P -b -d"*)
    # NOTE: no PATH= column -- the real script deliberately does not request
    # it (eval would turn PATH=/dev/... into a shell assignment and clobber
    # the real PATH). The script rebuilds the node from NAME.
    echo 'NAME="sda" MODEL="Test SATA HDD" SERIAL="SATATEST001" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
    echo 'NAME="sdb" MODEL="Phoenix USB Stick" SERIAL="USBTEST002" SIZE="32000000000" TRAN="usb" RM="1" ROTA="1" TYPE="disk"'
    echo 'NAME="nvme0n1" MODEL="Test NVMe SSD" SERIAL="NVMETEST003" SIZE="500107862016" TRAN="nvme" RM="0" ROTA="0" TYPE="disk"'
    echo 'NAME="sdd" MODEL="Mounted Data SSD" SERIAL="SDDTEST004" SIZE="250059350016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"' ;;
  *) echo "mock-lsblk: unhandled args: $args" >&2; exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/lsblk"

#--- source the real script's functions (strip the trailing `main "$@"`) -------
SRC_STRIPPED="$T/invoke-nuke-src.sh"
grep -v '^main "\$@"$' "$NUKE" > "$SRC_STRIPPED"
# The stripped copy lives in $T, so the script's own tools-dir detection
# would point at $T -- aim it at the real tools/ for the config-reader tests.
export PHOENIX_TOOLS_DIR="$REPO/tools"
# shellcheck disable=SC1090
source "$SRC_STRIPPED"

echo "== unit tests (sourced functions) =="
#--- classify_media ------------------------------------------------------------
t() { # t <tran> <rota> <expected>
    local got; got="$(classify_media "$1" "$2")"
    [[ "$got" == "$3" ]] && pass "classify_media($1,$2)=$3" \
        || fail "classify_media($1,$2)" "expected '$3', got '$got'"
}
t nvme 0 "NVMe SSD"; t sata 1 "HDD"; t sata 0 "SATA SSD"
t usb 1 "USB HDD"; t usb 0 "USB flash/SSD"; t virtio 0 "Virtual disk"

#--- method_for (auto + overrides) ---------------------------------------------
METHOD_OVERRIDE="auto"
tm() { # tm <media> <expected>
    local got; got="$(method_for "$1")"
    [[ "$got" == "$2" ]] && pass "method_for($1)=$2" \
        || fail "method_for($1)" "expected '$2', got '$got'"
}
tm "NVMe SSD" "nvme-format-ses1"; tm "SATA SSD" "ata-secure-erase"
tm "HDD" "nwipe:dod522022m"; tm "USB HDD" "nwipe:dod522022m"
tm "USB flash/SSD" "nwipe:dodshort"; tm "Virtual disk" "nwipe:dodshort"
tm "Unknown (foo)" "nwipe:dodshort"
for ov in dod522022m gutmann dodshort zero; do
    METHOD_OVERRIDE="$ov"
    tm "NVMe SSD" "nwipe:$ov"
done
METHOD_OVERRIDE="auto"

#--- nist_level_for -------------------------------------------------------------
tn() { # tn <method> <expected>
    local got; got="$(nist_level_for "$1")"
    [[ "$got" == "$2" ]] && pass "nist_level_for($1)=$2" \
        || fail "nist_level_for($1)" "expected '$2', got '$got'"
}
tn "nvme-format-ses1" "Purge"; tn "ata-secure-erase" "Purge"
tn "nwipe:dod522022m" "Clear"; tn "nwipe:zero" "Clear"

#--- human_size -----------------------------------------------------------------
th() { # th <bytes> <expected>
    local got; got="$(human_size "$1")"
    [[ "$got" == "$2" ]] && pass "human_size($1)=$2" \
        || fail "human_size($1)" "expected '$2', got '$got'"
}
th 1000204886016 "1.0 TB"; th 500107862016 "500.1 GB"; th 32000000000 "32.0 GB"

#--- parent_disk (mocked lsblk in PATH) -----------------------------------------
export PATH="$MOCKBIN:$PATH"
tp() { # tp <node> <expected>
    local got; got="$(parent_disk "$1")"
    [[ "$got" == "$2" ]] && pass "parent_disk($1)=$2" \
        || fail "parent_disk($1)" "expected '$2', got '$got'"
}
tp /dev/sda1 /dev/sda            # lsblk PKNAME hit
tp /dev/sdd1 /dev/sdd            # lsblk PKNAME hit
tp /dev/nvme0n1p2 /dev/nvme0n1   # PKNAME empty -> sed fallback
tp /dev/vda /dev/vda             # bare disk, no partition digits

#--- resolve_id ------------------------------------------------------------------
D_DEV=(/dev/sda /dev/sdb); D_MODEL=(A B); D_SERIAL=(SATATEST001 USBTEST002)
D_SIZE=(1 2); D_TRAN=(sata usb); D_MEDIA=(HDD "USB HDD"); D_FLAGS=("" "BOOT-USB")
D_COUNT=2
tr() { # tr <id> <expected-idx-or-FAIL>
    local got rc
    if got="$(resolve_id "$1" 2>/dev/null)"; then rc=0; else rc=1; fi
    if [[ "$2" == "FAIL" ]]; then
        (( rc != 0 )) && pass "resolve_id($1) rejected" \
            || fail "resolve_id($1)" "expected rejection, got idx $got"
    else
        (( rc == 0 )) && [[ "$got" == "$2" ]] && pass "resolve_id($1)=$2" \
            || fail "resolve_id($1)" "expected idx $2, got '$got' rc=$rc"
    fi
}
tr 1 0; tr 2 1; tr SATATEST001 0; tr USBTEST002 1
tr /dev/sda 0; tr /dev/sdb 1; tr 0 FAIL; tr 3 FAIL; tr 99 FAIL; tr bogus FAIL

#--- serial ambiguity: duplicated serials refuse, never first-match-wins --------
# A1: fixture with two disks reporting the SAME serial (VM clone / dup firmware).
D_DEV=(/dev/sda /dev/sdb); D_MODEL=(A B); D_SERIAL=(DUP111 DUP111)
D_SIZE=(100 100); D_TRAN=(sata sata); D_MEDIA=(HDD HDD); D_FLAGS=("" "")
D_COUNT=2
[[ "$(serial_count DUP111)" == "2" ]] && pass "serial_count(DUP111)=2" \
    || fail "serial_count(DUP111)" "expected 2, got '$(serial_count DUP111)'"
[[ "$(serial_count NOSUCH)" == "0" ]] && pass "serial_count(NOSUCH)=0" \
    || fail "serial_count(NOSUCH)" "expected 0"
# A2: serial-based selection of a duplicated serial is refused (not resolved
#     to the first disk).
tr DUP111 FAIL
# A3: refusal message names the ambiguity (stdout to stderr, mentions disks).
out="$(resolve_id "DUP111" 2>&1)" || true
if [[ "$out" == *"ambiguous"* ]]; then
    pass "resolve_id(DUP111) refusal explains ambiguity"
else
    fail "resolve_id(DUP111) refusal explains ambiguity" "message lacks 'ambiguous'"
fi
# A4: row number and /dev node still resolve mechanically...
tr 1 0; tr /dev/sda 0; tr /dev/sdb 1
# A5: ...but arming them is refused structurally: typed confirmation of a
#     duplicated serial cannot prove WHICH disk was meant.
if refuse_dup_serial "DUP111" /dev/sda >/dev/null 2>&1; then
    fail "refuse_dup_serial(DUP111) refuses"
else
    pass "refuse_dup_serial(DUP111) refuses"
fi
out="$(refuse_dup_serial "DUP111" /dev/sda 2>&1)" || true
if [[ "$out" == *"MULTIPLE disks"* ]]; then
    pass "refuse_dup_serial(DUP111) names candidate disks"
else
    fail "refuse_dup_serial(DUP111) names candidate disks"
fi
# A6: unique serials are NOT refused -- normal arming path unaffected.
D_DEV=(/dev/sda /dev/sdb); D_SERIAL=(SATATEST001 USBTEST002); D_COUNT=2
tr SATATEST001 0
refuse_dup_serial "SATATEST001" /dev/sda >/dev/null 2>&1 \
    && pass "refuse_dup_serial(unique) allows" \
    || fail "refuse_dup_serial(unique) allows" "unique serial was refused"
# A7: empty/unknown serials pass through to the (separate) no-serial refusal.
D_DEV=(/dev/sda /dev/sdb); D_SERIAL=(unknown unknown); D_COUNT=2
refuse_dup_serial "unknown" /dev/sda >/dev/null 2>&1 \
    && pass "refuse_dup_serial(unknown) defers to no-serial gate" \
    || fail "refuse_dup_serial(unknown) defers to no-serial gate"
# restore the unit-test fixture used by later sections
D_DEV=(/dev/sda /dev/sdb); D_MODEL=(A B); D_SERIAL=(SATATEST001 USBTEST002)
D_SIZE=(1 2); D_TRAN=(sata usb); D_MEDIA=(HDD "USB HDD"); D_FLAGS=("" "BOOT-USB")
D_COUNT=2

#--- typed_confirmation: pipe-fed input can never arm (the TTY interlock) -----
echo "== typed_confirmation: piped input cannot arm (unit) =="
# U1: the CORRECT serial, piped, is refused -- stdin is not a terminal.
if printf 'SATATEST001\n' | typed_confirmation "SATATEST001" >/dev/null 2>&1; then
    fail "typed_confirmation refuses piped correct serial"
else
    pass "typed_confirmation refuses piped correct serial"
fi
# U2: piped "yes" is refused (it could never match a serial anyway, but the
#     TTY gate must fire first).
if printf 'yes\n' | typed_confirmation "SATATEST001" >/dev/null 2>&1; then
    fail 'typed_confirmation refuses piped "yes"'
else
    pass 'typed_confirmation refuses piped "yes"'
fi
# U3: piped "NUKE <serial>" is refused too -- the prefix does not bypass it.
if printf 'NUKE SATATEST001\n' | typed_confirmation "SATATEST001" >/dev/null 2>&1; then
    fail 'typed_confirmation refuses piped "NUKE <serial>"'
else
    pass 'typed_confirmation refuses piped "NUKE <serial>"'
fi
# U4/U5/U6: on a REAL pty (human-at-console equivalent), the wrong serial is
# still refused and the correct serial / "NUKE <serial>" are accepted.
# NOTE: util-linux `script` scrubs the environment, so `export -f` does not
# reach the pty child -- inject the function bodies via `declare -f` into a
# temp child script instead (avoids nested-quoting pitfalls entirely).
pty_confirm() { # pty_confirm <typed-input> <expected-serial> -> rc of typed_confirmation on a real pty
    local child="$T/pty-child.sh"
    { declare -f typed_confirmation; declare -f log; declare -f ts
      printf 'typed_confirmation %q\n' "$2"; } > "$child"
    printf '%s\n' "$1" | script -qec "bash $child" /dev/null >/dev/null 2>&1
}
if pty_confirm 'wrongserial' 'SATATEST001'; then
    fail "typed_confirmation rejects wrong serial on a TTY"
else
    pass "typed_confirmation rejects wrong serial on a TTY"
fi
if pty_confirm 'SATATEST001' 'SATATEST001'; then
    pass "typed_confirmation accepts correct serial on a TTY"
else
    fail "typed_confirmation accepts correct serial on a TTY"
fi
if pty_confirm 'NUKE SATATEST001' 'SATATEST001'; then
    pass 'typed_confirmation accepts "NUKE <serial>" on a TTY'
else
    fail 'typed_confirmation accepts "NUKE <serial>" on a TTY'
fi

#--- image-proof gate: no verified image, no wipe (runbook invariant 1) -------
echo "== image-proof gate (unit) =="
# Fixtures are generated by the REAL tools/New-ImageProof.sh -- this also
# smoke-tests the writer end to end.
PROOFWRITER="$REPO/tools/New-ImageProof.sh"
mkdir -p "$T/fakeimg"
echo "fake-disk-image-bytes" > "$T/fakeimg/part.img"
GOODSHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
bash "$PROOFWRITER" --image-name laptop-fulldisk-test \
    --image-path "$T/fakeimg" --source-serial SATATEST001 \
    --source-dev /dev/sda --sha256 "$GOODSHA" \
    --verified --verified-by harness --out "$T" >/dev/null
GOODPROOF="$(ls "$T"/image-proof-SATATEST001-*.proof)"
[[ -f "$GOODPROOF" ]] && pass "New-ImageProof.sh writes a .proof file" \
    || fail "New-ImageProof.sh writes a .proof file"
# P2: writer refuses a malformed sha256.
if bash "$PROOFWRITER" --image-name x --image-path "$T/fakeimg" \
        --source-serial SATATEST001 --sha256 "nothex" --verified \
        --out "$T" >/dev/null 2>&1; then
    fail "New-ImageProof.sh rejects malformed sha256"
else
    pass "New-ImageProof.sh rejects malformed sha256"
fi
# P3: valid proof bound to the target serial passes the gate.
check_image_proof "$GOODPROOF" "SATATEST001" >/dev/null 2>&1 \
    && pass "check_image_proof(valid, matching serial)" \
    || fail "check_image_proof(valid, matching serial)" "valid proof was rejected"
# P4: missing proof file refused.
check_image_proof "$T/does-not-exist.proof" "SATATEST001" >/dev/null 2>&1 \
    && fail "check_image_proof refuses missing file" \
    || pass "check_image_proof refuses missing file"
# P5: verified=NO proof refused (writer run WITHOUT --verified).
# NOTE: uses a DIFFERENT source serial than the P1 proof -- the writer names
# files by serial+UTC-second, and two proofs for one serial in the same
# second would overwrite each other.
bash "$PROOFWRITER" --image-name unverified-test \
    --image-path "$T/fakeimg" --source-serial NOVERIFY002 \
    --sha256 "$GOODSHA" --out "$T" >/dev/null
NOPROOF="$(ls "$T"/image-proof-NOVERIFY002-*.proof)"
check_image_proof "$NOPROOF" "NOVERIFY002" >/dev/null 2>&1 \
    && fail "check_image_proof refuses verified=NO" \
    || pass "check_image_proof refuses verified=NO"
# P6: tampered sha256 refused.
sed 's/^sha256=.*/sha256=zzzz/' "$GOODPROOF" > "$T/tampered.proof"
check_image_proof "$T/tampered.proof" "SATATEST001" >/dev/null 2>&1 \
    && fail "check_image_proof refuses tampered sha256" \
    || pass "check_image_proof refuses tampered sha256"
# P7: zero-size image refused.
sed 's/^image_size_bytes=.*/image_size_bytes=0/' "$GOODPROOF" > "$T/zero.proof"
check_image_proof "$T/zero.proof" "SATATEST001" >/dev/null 2>&1 \
    && fail "check_image_proof refuses zero image_size_bytes" \
    || pass "check_image_proof refuses zero image_size_bytes"
# P8: wrong format refused.
printf 'format=something-else/9\nverified=YES\n' > "$T/badformat.proof"
check_image_proof "$T/badformat.proof" "SATATEST001" >/dev/null 2>&1 \
    && fail "check_image_proof refuses unknown format" \
    || pass "check_image_proof refuses unknown format"
# P9: proof bound to a DIFFERENT serial cannot arm this target.
check_image_proof "$GOODPROOF" "USBTEST002" >/dev/null 2>&1 \
    && fail "check_image_proof refuses serial mismatch" \
    || pass "check_image_proof refuses serial mismatch"
out="$(check_image_proof "$GOODPROOF" "USBTEST002" 2>&1)" || true
[[ "$out" == *"bound"* ]] && pass "serial-mismatch refusal explains binding" \
    || fail "serial-mismatch refusal explains binding" "message lacks 'bound'"
# Fixture proof for the mounted data disk (row 4 / SDDTEST004), so the
# integration cases below can get PAST the image gate and exercise the
# mount guard itself.
bash "$PROOFWRITER" --image-name data-disk-test \
    --image-path "$T/fakeimg" --source-serial SDDTEST004 \
    --sha256 "$GOODSHA" --verified --verified-by harness --out "$T" >/dev/null
SDDPROOF="$(ls "$T"/image-proof-SDDTEST004-*.proof)"

#--- stick policy: phoenix-config.json (unit) ---------------------------------
echo "== stick policy: phoenix-config.json (unit) =="
CFG_OK="$T/cfg-ok.json"
CFG_SKIP="$T/cfg-skip.json"
CFG_NONUKE="$T/cfg-nonuke.json"
CFG_MISS="$T/cfg-miss.json"
CFG_BAD="$T/cfg-bad.json"
write_cfg() { # write_cfg <path> <nuke> <allow_skip> <serials-json-array>
    cat > "$1" <<JSON
{
  "schema_version": 1,
  "boot_entries": {"analyze": true, "backup": true, "nuke": $2, "reinstall": true},
  "target_disks": $4,
  "backup_target": {"kind": "direct-usb"},
  "unattend": {"answer_file": "/autounattend.xml"},
  "safety": {"require_image_proof": true, "allow_skip_image_gate": $3, "abort_countdown_seconds": 5}
}
JSON
}
write_cfg "$CFG_OK" true false '[{"serial": "SATATEST001", "model": "Test SATA HDD"}, {"serial": "sddtest004", "model": "Mounted Data SSD", "note": "lowercase on purpose: the reader must normalize it"}]'
write_cfg "$CFG_SKIP" true true '[{"serial": "SATATEST001"}]'
write_cfg "$CFG_NONUKE" false false '[]'
write_cfg "$CFG_MISS" true false '[{"serial": "SOMETHINGELSE"}]'
write_cfg "$CFG_BAD" true false '[]'
# CFG_BAD is invalid on purpose: nuke=true with an empty target_disks
# violates docs/CONFIG-SCHEMA.md section 6 (structural rule 2).

# C1: valid config loads; policy values land in CFG_* globals.
CONFIG="$CFG_OK"
load_usb_config
[[ "${CFG_NUKE_ENABLED:-}" == "1" ]] && pass "C1 nuke enabled flag" \
    || fail "C1 nuke enabled flag" "got '${CFG_NUKE_ENABLED:-}'"
[[ "${CFG_ALLOW_SERIAL_COUNT:-}" == "2" ]] && pass "C1 allowlist count" \
    || fail "C1 allowlist count" "got '${CFG_ALLOW_SERIAL_COUNT:-}'"
[[ "${CFG_ALLOW_SERIAL_0:-}" == "SATATEST001" ]] && pass "C1 allowlisted serial 0" \
    || fail "C1 allowlisted serial 0" "got '${CFG_ALLOW_SERIAL_0:-}'"
[[ "${CFG_ALLOW_SERIAL_1:-}" == "SDDTEST004" ]] && pass "C1 lowercase serial normalized" \
    || fail "C1 lowercase serial normalized" "got '${CFG_ALLOW_SERIAL_1:-}'"
[[ "${CFG_ALLOW_SKIP_IMAGE_GATE:-}" == "0" ]] && pass "C1 skip-gate flag" \
    || fail "C1 skip-gate flag" "got '${CFG_ALLOW_SKIP_IMAGE_GATE:-}'"
[[ "${CFG_ABORT_COUNTDOWN:-}" == "5" ]] && pass "C1 countdown" \
    || fail "C1 countdown" "got '${CFG_ABORT_COUNTDOWN:-}'"
# C2: normalize_serial (whitespace trim + uppercase).
[[ "$(normalize_serial ' sataTest001 ')" == "SATATEST001" ]] \
    && pass "C2 normalize_serial trims + uppercases" \
    || fail "C2 normalize_serial trims + uppercases" "got '$(normalize_serial ' sataTest001 ')'"
# C3: allowlisted serial passes the policy check.
check_usb_config_policy "SATATEST001" >/dev/null 2>&1 \
    && pass "C3 policy allows allowlisted serial" \
    || fail "C3 policy allows allowlisted serial" "allowlisted serial was refused"
# C4: serial NOT on the allowlist is refused (subshell -- die() exits).
if (CONFIG="$CFG_OK"; load_usb_config >/dev/null 2>&1; check_usb_config_policy "NOSUCH999" >/dev/null 2>&1); then
    fail "C4 policy refuses non-allowlisted serial"
else
    pass "C4 policy refuses non-allowlisted serial"
fi
# C5: invalid config (nuke=true, empty target_disks) is refused by the loader.
if (CONFIG="$CFG_BAD"; load_usb_config >/dev/null 2>&1); then
    fail "C5 loader refuses invalid config"
else
    pass "C5 loader refuses invalid config"
fi
# C6: missing config file is refused by the loader.
if (CONFIG="$T/does-not-exist.json"; load_usb_config >/dev/null 2>&1); then
    fail "C6 loader refuses missing config file"
else
    pass "C6 loader refuses missing config file"
fi
# C7: nuke=false loads fine (flag 0), but the policy refuses any arming.
CONFIG="$CFG_NONUKE"
load_usb_config
[[ "${CFG_NUKE_ENABLED:-}" == "0" ]] && pass "C7 nuke-disabled flag" \
    || fail "C7 nuke-disabled flag" "got '${CFG_NUKE_ENABLED:-}'"
if (check_usb_config_policy "SATATEST001" >/dev/null 2>&1); then
    fail "C7 policy refuses arming on nuke-disabled stick"
else
    pass "C7 policy refuses arming on nuke-disabled stick"
fi
# C8: --skip-image-gate is refused when the stick compiled it out...
CONFIG="$CFG_OK"
load_usb_config
SKIP_IMAGE_GATE=1
if (check_usb_config_policy "SATATEST001" >/dev/null 2>&1); then
    fail "C8 skip-gate compiled out refuses --skip-image-gate"
else
    pass "C8 skip-gate compiled out refuses --skip-image-gate"
fi
# C9: ...but passes the policy check when the stick's hatch is enabled.
#     (The human TTY gate still stands -- see integration I22.)
CONFIG="$CFG_SKIP"
load_usb_config
check_usb_config_policy "SATATEST001" >/dev/null 2>&1 \
    && pass "C9 skip-gate enabled passes policy check" \
    || fail "C9 skip-gate enabled passes policy check" "policy refused with the hatch enabled"
SKIP_IMAGE_GATE=0
# C10: the reader's --json mode emits the same policy.
out="$(python3 "$REPO/tools/Read-UsbConfig.py" --json "$CFG_OK")"
if [[ "$out" == *'"nuke_enabled": true'* && "$out" == *'"SDDTEST004"'* ]]; then
    pass "C10 reader --json policy output"
else
    fail "C10 reader --json policy output" "unexpected output: $(echo "$out" | head -c 200)"
fi
# C11: the reader validates before printing -- the invalid fixture exits 2.
if python3 "$REPO/tools/Read-UsbConfig.py" --shell "$CFG_BAD" >/dev/null 2>&1; then
    fail "C11 reader exits 2 on invalid config"
else
    [[ $? == 2 ]] && pass "C11 reader exits 2 on invalid config" \
        || fail "C11 reader exits 2 on invalid config" "got exit $?"
fi

echo "== integration tests (mocked lsblk subprocess) =="
# run_case <name> <expected-exit> <expected-substring> [script args...]
# stdin comes from /dev/null unless NUKE_STDIN is set.
run_case() {
    local name="$1" exp_exit="$2" exp_sub="$3"; shift 3
    local out rc logdir="$T/logs-$name"
    mkdir -p "$logdir"
    if [[ -n "${NUKE_STDIN:-}" ]]; then
        out="$(printf '%s' "$NUKE_STDIN" | PATH="$MOCKBIN:$PATH" timeout 20 \
            bash "$NUKE" --log-dir "$logdir" "$@" 2>&1)" && rc=0 || rc=$?
    else
        out="$(PATH="$MOCKBIN:$PATH" timeout 20 \
            bash "$NUKE" --log-dir "$logdir" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
    fi
    if (( rc == exp_exit )) && [[ "$out" == *"$exp_sub"* ]]; then
        pass "$name (exit $rc)"
    else
        fail "$name" "expected exit $exp_exit + '$exp_sub'; got exit $rc; output: $(echo "$out" | head -c 400)"
    fi
}

# I1: dry-run enumeration (no flags) -- the default. Must exit 0, no arming.
run_case "I1 enumerate-only" 0 "4 disk(s) detected"
# I2: --whatif behaves identically.
run_case "I2 whatif" 0 "dry-run" --whatif
# I3: boot USB (row 2) is refused structurally, exit 1, no log written.
run_case "I3 boot-USB refused" 1 "REFUSED" --nuke 2
[[ -z "$(ls -A "$T/logs-I3 boot-USB refused" 2>/dev/null)" ]] \
    && pass "I3 no log file on refusal" \
    || fail "I3 no log file on refusal" "log dir not empty"
# I4: mounted data disk (row 4) refused by the mount guard (image gate
#      satisfied with a valid proof for its serial, so the mount guard fires).
run_case "I4 mounted-disk refused" 1 "has mounted partitions" --image-proof "$SDDPROOF" --nuke 4
# I5: same guard reachable by /dev path (resolve_id path matching).
run_case "I5 mounted-disk by /dev path refused" 1 "has mounted partitions" --image-proof "$SDDPROOF" --nuke /dev/sdd
# I6: unknown identifier rejected.
run_case "I6 unknown id rejected" 1 "No disk matches identifier" --nuke /dev/doesnotexist
# I7: out-of-range row rejected.
run_case "I7 out-of-range row rejected" 1 "No disk matches identifier" --nuke 99
# I8: bad --method rejected up front.
run_case "I8 bad --method rejected" 1 "Unknown --method" --method bogus --nuke 1
# I9: --nuke without an id errors (bash ${2:?...} exits 1).
run_case "I9 --nuke missing arg" 1 "needs a disk id" --nuke
# I10: gate ordering -- the image-proof gate fires before any confirmation
#      prompt (and before the block-device check): no verified image, no wipe.
NUKE_STDIN="y" run_case "I10 image-proof gate before confirmation" 1 "image-proof" --nuke 1
unset NUKE_STDIN
# I12: even the CORRECT serial, piped in, cannot reach confirmation -- the
#      image-proof gate refuses first, and no "CONFIRMED"/arming line appears.
NUKE_STDIN="SATATEST001" run_case "I12 piped correct serial blocked by image gate" 1 "image-proof" --nuke 1
unset NUKE_STDIN
# I11: enumeration table content -- boot USB flagged, NVMe classified, sizes sane.
out="$(PATH="$MOCKBIN:$PATH" timeout 20 bash "$NUKE" --log-dir "$T/logs-I11" </dev/null 2>&1)"
for sub in "USBTEST002" "BOOT-USB" "MOUNTED" "NVMe SSD" "1.0 TB" "500.1 GB"; do
    [[ "$out" == *"$sub"* ]] && pass "I11 table contains '$sub'" \
        || fail "I11 table contains '$sub'"
done
# I13: --nuke without --image-proof is refused (image-proof gate, invariant 1).
run_case "I13 nuke without image-proof refused" 1 "requires --image-proof" --nuke 1
# I14: --image-proof pointing at a missing file is refused.
run_case "I14 missing proof file refused" 1 "not a readable file" --image-proof "$T/nope.proof" --nuke 1
# I15: proof bound to the WRONG serial cannot arm this target.
run_case "I15 wrong-serial proof refused" 1 "bound" --image-proof "$GOODPROOF" --nuke 2
# I16: a VALID proof bound to the target passes the image gate -- the next
#      gate (fixture paths are not block devices on the host) is what fires.
run_case "I16 valid proof passes image gate" 1 "not a block device" --image-proof "$GOODPROOF" --nuke 1
# I17: --skip-image-gate with piped stdin is refused -- skipping the gate is
#      a human-at-the-console action only.
NUKE_STDIN="NUKE WITHOUT BACKUP" run_case "I17 piped image-gate skip refused" 1 "real console" --skip-image-gate --nuke 1
unset NUKE_STDIN
# --- stick policy: phoenix-config.json (SAFETY interlock 12) -----------------
# I18: --config with boot_entries.nuke=false refuses before any other gate.
run_case "I18 config nuke disabled refuses" 1 "boot_entries.nuke" --config "$CFG_NONUKE" --image-proof "$GOODPROOF" --nuke 1
# I19: --config whose allowlist does not contain the target serial refuses.
run_case "I19 config allowlist miss refuses" 1 "allowlist" --config "$CFG_MISS" --image-proof "$GOODPROOF" --nuke 1
# I20: --config with the target on the allowlist passes the policy gates;
#      the next gate (fixture paths are not block devices on the host) fires.
run_case "I20 config allowlist hit passes policy" 1 "not a block device" --config "$CFG_OK" --image-proof "$GOODPROOF" --nuke 1
# I21: --skip-image-gate is refused when the stick compiled it out.
run_case "I21 config skip-gate compiled out refuses" 1 "compiled out" --config "$CFG_OK" --skip-image-gate --nuke 1
# I22: --skip-image-gate with the stick's hatch ENABLED still requires a
#      human at a real console -- the config opens the hatch, it does not
#      bypass the console. Piped input is refused by the TTY gate.
NUKE_STDIN="NUKE WITHOUT BACKUP" run_case "I22 config skip-gate enabled still needs TTY" 1 "real console" --config "$CFG_SKIP" --skip-image-gate --nuke 1
unset NUKE_STDIN
# I23: an INVALID config (nuke=true, empty target_disks -- violates
#      docs/CONFIG-SCHEMA.md section 6) is refused by the loader.
run_case "I23 invalid config refused" 1 "INVALID" --config "$CFG_BAD" --nuke 1
# I24: a missing config file is refused.
run_case "I24 missing config refused" 1 "not a readable file" --config "$T/does-not-exist.json" --nuke 1

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "All nuke interlock regression tests green."
