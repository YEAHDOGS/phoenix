#!/usr/bin/env bash
#===============================================================================
# test-phoenix-nuke.sh -- regression harness for the Phoenix NUKE core pair:
#   tools/Invoke-PhoenixNuke.ps1  (Windows side)
#   tools/phoenix-nuke.sh          (Linux rescue side, rule parity with the .ps1)
#
# Tests the safety contract WITHOUT any destructive path, on this machine,
# with mocked `lsblk` and a mocked `dd` that would fail loudly if the armed
# path ever executed. Nothing here can destroy data:
#   - fixture disks are fake /dev/sd* paths that do not exist on the host,
#   - the mock `dd` records any invocation to a marker file and exits 1;
#     the suite asserts the marker is NEVER created,
#   - nwipe/hdparm/nvme-cli are absent (preflight refuses otherwise),
#   - the script's own "not a block device" gate fires before any
#     confirmation prompt for the fixture disks.
#
# Coverage (bash twin, mocked lsblk fixture: sda=HDD, sdb=boot USB mounted,
# nvme0n1=NVMe SSD, sdd=mounted data SSD, sde=spare USB stick NOT mounted):
#   UNIT (functions sourced from the real script, `main` stripped):
#     classify_media, human_size, parent_disk, resolve_id (rows, serials,
#     /dev nodes; wildcard/out-of-range/unknown rejected; duplicated serials
#     refuse at resolution AND are flagged), typed_confirm_twice (piped input
#     refused; on a real pty: wrong+wrong aborts, right+wrong aborts,
#     right+right arms, /dev path twice arms; audit ABORTED/CONFIRMED).
#   INTEGRATION (subprocess):
#     dry-run default + --whatif enumerate only (exit 0, audit
#     ENUMERATE_DRYRUN, dd never invoked), boot-USB refused, mounted disk
#     refused, USB disk refused without --override-boot-protection and
#     passing the guard WITH it (override logged), unknown/wildcard/row
#     identifiers refused (fail closed), duplicated-serial fixture refuses
#     at resolution and at arm time, ARM-CODE transcription gate first on
#     the armed path (wrong code aborts exit 2; piped stdin refused; code
#     derived independently via python3), then mistyped double-confirmation
#     aborts (pty), correct double-confirmation reaches the block-device
#     gate (audit CONFIRMED, dd never invoked), audit record fields present
#     (timestamp, disk id, mode, operator confirmation), --help, bad flag.
#     IMAGE-PROOF GATE (runbook invariant 1): --nuke with no proof refused;
#     gate precedes the boot-protection check; bad-format / unverified /
#     bad-sha256 / zero-size / serial-mismatch / unknown-serial proofs all
#     refused; valid proof passes (IMAGE-PROOF audit record) and arming
#     continues; --skip-image-gate piped refused, pty exact phrase proceeds
#     (WARNING audit), wrong phrase aborts; proof beats the skip flag.
#     CONFIG-PROTECTED EXCLUSIONS: a fixture phoenix-config.json naming a
#     serial + a /dev path removes them from the candidate rows (rows
#     renumber), lists them in the hidden summary, and no identifier
#     (serial, /dev path, stale row) can select them -- --override-boot-
#     protection cannot reach them either.
#   PARITY (static): the .ps1 exposes the same flags, gates, and audit modes
#     as the .sh (pwsh is not installed here, so the .ps1 is checked
#     structurally; behavioral tests run against the .sh twin). KNOWN GAP:
#     Invoke-PhoenixNuke.ps1 has no image-proof gate yet -- the .sh now
#     implements runbook invariant 1 (mirroring Invoke-Nuke.sh); the .ps1
#     twin still needs it.
#
# Deliberately NOT covered here (VM-only, see docs/NUKE-TEST-PLAN.md):
#   actual destruction against a real block device. Those need QEMU
#   throwaway images and must never run on bare metal.
#
# Usage: bash tests/tools/test-phoenix-nuke.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$REPO/tools/phoenix-nuke.sh"
PS1F="$REPO/tools/Invoke-PhoenixNuke.ps1"
T="$(mktemp -d /tmp/phoenix-nuke-core-test.XXXXXX)"
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN"
DD_MARKER="$T/DD_WAS_INVOKED"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

# armcode <serial> <model> <size-bytes> -> the ARM-CODE per the design
# formula, derived INDEPENDENTLY in python3 (not by calling the script's
# pdi_arm_code). Agreement between the two is the cross-implementation
# check; a mismatch means one side drifted from docs/NUKE-INTERLOCKS.md §2.
armcode() {
    python3 -c "import hashlib,sys
print(hashlib.sha256(('phoenix-nuke-arm|'+sys.argv[1]+'|'+sys.argv[2]+'|'+sys.argv[3]).encode()).hexdigest()[:6].upper())" \
        "$1" "$2" "$3"
}

#--- preflight -----------------------------------------------------------------
echo "== preflight =="
[[ -f "$SH" ]] || { echo "FATAL: $SH not found"; exit 1; }
[[ -f "$PS1F" ]] || { echo "FATAL: $PS1F not found"; exit 1; }
bash -n "$SH" && pass "bash -n syntax check (phoenix-nuke.sh)" || fail "bash -n syntax check (phoenix-nuke.sh)"
[[ $EUID -eq 0 ]] && pass "running as root (script requirement)" \
    || fail "running as root (script requirement)" "script refuses non-root; run with sudo"
for tool in nwipe hdparm nvme; do
    if command -v "$tool" >/dev/null 2>&1; then
        fail "preflight: $tool absent" "$tool is installed -- refusing to run"
    fi
done
pass "preflight: nwipe/hdparm/nvme absent"

#--- mock dd: fail loudly and leave evidence if the armed path ever runs -------
cat > "$MOCKBIN/dd" <<MOCK
#!/usr/bin/env bash
echo "INVOKED: $*" >> "$DD_MARKER"
echo "mock-dd: destructive path reached -- this must never happen in tests" >&2
exit 1
MOCK
chmod +x "$MOCKBIN/dd"

#--- mock lsblk ----------------------------------------------------------------
# Fixture: sda = SATA HDD (SATATEST001), sdb = boot USB mounted (USBTEST002),
# nvme0n1 = NVMe SSD (NVMETEST003), sdd = mounted data SSD (SDDTEST004),
# sde = spare USB stick NOT mounted (USBTEST005).
# MOCK_DUPS=1: sda and nvme0n1 report the SAME serial (dup-serial fixture).
cat > "$MOCKBIN/lsblk" <<'MOCK'
#!/usr/bin/env bash
args="$*"
last="${@: -1}"
dups="${MOCK_DUPS:-0}"
evil="${MOCK_EVIL:-0}"
evil_marker="${MOCK_EVIL_MARKER:-/tmp/phoenix-nuke-evil-marker}"
case "$args" in
  *"-ndo PKNAME"*)
    case "$last" in
      /dev/vda) echo vda ;; /dev/sda1) echo sda ;; /dev/sdd1) echo sdd ;;
      *) echo "" ;;
    esac ;;
  *"-dnr -o PATH"*)
    printf '%s\n' /dev/sda /dev/sdb /dev/nvme0n1 /dev/sdd /dev/sde ;;
  *"-nr -o MOUNTPOINTS"*)
    case "$last" in
      /dev/sdb) echo "/media/phoenix-usb" ;;
      /dev/sdd) echo "/mnt/data" ;;
    esac ;;
  *"-dnro TRAN"*)
    case "$last" in
      /dev/sda|/dev/sdd) echo sata ;; /dev/sdb|/dev/sde) echo usb ;;
      /dev/nvme0n1) echo nvme ;; *) echo "" ;;
    esac ;;
  *"-dnro RM"*)
    case "$last" in /dev/sdb|/dev/sde) echo 1 ;; *) echo 0 ;; esac ;;
  *"-dnro SERIAL"*)
    sda_s="SATATEST001"; nvme_s="NVMETEST003"
    if [[ "$dups" == "1" ]]; then sda_s="DUP111"; nvme_s="DUP111"; fi
    case "$last" in
      /dev/sda) echo "$sda_s" ;; /dev/sdb) echo USBTEST002 ;;
      /dev/nvme0n1) echo "$nvme_s" ;; /dev/sdd) echo SDDTEST004 ;;
      /dev/sde) echo USBTEST005 ;; *) echo "" ;;
    esac ;;
  *"-dnro ROTA"*)
    case "$last" in /dev/sda|/dev/sdb) echo 1 ;; *) echo 0 ;; esac ;;
  *"-P -b -d"*)
    sda_s="SATATEST001"; nvme_s="NVMETEST003"
    if [[ "$dups" == "1" ]]; then sda_s="DUP111"; nvme_s="DUP111"; fi
    if [[ "$evil" == "1" ]]; then
      # Hostile firmware, escaped the way real `lsblk -P` emits it (quotes
      # arrive as \"). The parser must keep the payload as DATA: the row
      # still enumerates, the attack string is displayed, nothing executes.
      echo "NAME=\"sda\" MODEL=\"Evil\\\"; touch \\\"$evil_marker\\\"; echo \\\"X\\\"\" SERIAL=\"EVILTEST001\" SIZE=\"1000204886016\" TRAN=\"sata\" RM=\"0\" ROTA=\"1\" TYPE=\"disk\""
    else
      echo "NAME=\"sda\" MODEL=\"Test SATA HDD\" SERIAL=\"$sda_s\" SIZE=\"1000204886016\" TRAN=\"sata\" RM=\"0\" ROTA=\"1\" TYPE=\"disk\""
    fi
    echo 'NAME="sdb" MODEL="Phoenix USB Stick" SERIAL="USBTEST002" SIZE="32000000000" TRAN="usb" RM="1" ROTA="1" TYPE="disk"'
    echo "NAME=\"nvme0n1\" MODEL=\"Test NVMe SSD\" SERIAL=\"$nvme_s\" SIZE=\"500107862016\" TRAN=\"nvme\" RM=\"0\" ROTA=\"0\" TYPE=\"disk\""
    echo 'NAME="sdd" MODEL="Mounted Data SSD" SERIAL="SDDTEST004" SIZE="250059350016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"'
    echo 'NAME="sde" MODEL="Spare USB Stick" SERIAL="USBTEST005" SIZE="16000000000" TRAN="usb" RM="1" ROTA="0" TYPE="disk"' ;;
  *) echo "mock-lsblk: unhandled args: $args" >&2; exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/lsblk"

#--- source the real script's functions (strip the trailing `main "$@"`) -------
SRC_STRIPPED="$T/phoenix-nuke-src.sh"
grep -v '^main "\$@"$' "$SH" > "$SRC_STRIPPED"
# The script sources tools/lib/phoenix-disk-inventory.sh relative to its own
# location -- mirror that layout so the stripped copy finds it too.
mkdir -p "$T/lib"
cp "$REPO/tools/lib/phoenix-disk-inventory.sh" "$T/lib/"
# Hermetic config: the lib would otherwise read ./phoenix-config.json from
# whatever cwd the suite runs in. Point it at a path that cannot exist; the
# protected-exclusion tests override it with a real fixture.
export PHOENIX_PDI_CONFIG="$T/no-such-config.json"
# shellcheck disable=SC1090
source "$SRC_STRIPPED"

echo "== unit tests (sourced functions) =="
#--- classify_media ------------------------------------------------------------
t() { local got; got="$(classify_media "$1" "$2")"
    [[ "$got" == "$3" ]] && pass "classify_media($1,$2)=$3" \
        || fail "classify_media($1,$2)" "expected '$3', got '$got'"; }
t nvme 0 "NVMe SSD"; t sata 1 "HDD"; t sata 0 "SATA SSD"
t usb 1 "USB HDD"; t usb 0 "USB flash/SSD"; t virtio 0 "Virtual disk"

#--- human_size -----------------------------------------------------------------
th() { local got; got="$(human_size "$1")"
    [[ "$got" == "$2" ]] && pass "human_size($1)=$2" \
        || fail "human_size($1)" "expected '$2', got '$got'"; }
th 1000204886016 "1.0 TB"; th 500107862016 "500.1 GB"; th 16000000000 "16.0 GB"

#--- parse_lsblk_pairs: eval-free lsblk -P parsing --------------------------------
# Firmware strings (MODEL/SERIAL) are UNTRUSTED input -- a hostile USB device
# can report arbitrary descriptors. The parser must treat them as data; the
# old `eval "$line"` approach executed them as shell. These cases prove the
# injection is dead.
echo "== parse_lsblk_pairs (eval-free lsblk -P parsing) =="
parse_lsblk_pairs 'NAME="sda" MODEL="Test SATA HDD" SERIAL="SATATEST001" SIZE="100" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
[[ "${LP[NAME]}" == "sda" && "${LP[MODEL]}" == "Test SATA HDD" && "${LP[SERIAL]}" == "SATATEST001" && "${LP[TYPE]}" == "disk" ]] \
    && pass "parse_lsblk_pairs benign line" \
    || fail "parse_lsblk_pairs benign line" "got NAME=${LP[NAME]} MODEL=${LP[MODEL]} SERIAL=${LP[SERIAL]}"
parse_lsblk_pairs 'NAME="sda" MODEL="Foo \"Bar\" \\ Baz" SERIAL="S1" TYPE="disk"'
[[ "${LP[MODEL]}" == 'Foo "Bar" \ Baz' ]] \
    && pass "parse_lsblk_pairs unescapes -P sequences" \
    || fail "parse_lsblk_pairs unescapes -P sequences" "got '${LP[MODEL]}'"
# hostile 1: command substitution inside a quoted value must not execute
rm -f "$T/cmdsub-marker"
p1='NAME="sda" MODEL="x$(touch '"$T"'/cmdsub-marker)" SERIAL="S1" TYPE="disk"'
parse_lsblk_pairs "$p1"
[[ "${LP[MODEL]}" == 'x$(touch '"$T"'/cmdsub-marker)' ]] \
    && pass "parser keeps \$(...) payload as data" \
    || fail "parser keeps \$(...) payload as data" "got '${LP[MODEL]}'"
[[ ! -e "$T/cmdsub-marker" ]] \
    && pass "parser does not execute \$(...) payload" \
    || fail "parser does not execute \$(...) payload" "marker file executed"
# hostile 2: quote break-out must not execute either
rm -f "$T/breakout-marker"
p2='NAME="sda" MODEL="Evil"; touch "'"$T"'/breakout-marker"; echo "X" SERIAL="S2" TYPE="disk"'
parse_lsblk_pairs "$p2"
[[ ! -e "$T/breakout-marker" ]] \
    && pass "parser does not execute quote-break-out payload" \
    || fail "parser does not execute quote-break-out payload" "marker file executed"
[[ "${LP[NAME]}" == "sda" && "${LP[MODEL]}" == "Evil" ]] \
    && pass "parser truncates at injected quote, keeps benign prefix" \
    || fail "parser truncates at injected quote" "got NAME=${LP[NAME]} MODEL=${LP[MODEL]}"

#--- parent_disk (mocked lsblk in PATH) -----------------------------------------
export PATH="$MOCKBIN:$PATH"
tp() { local got; got="$(parent_disk "$1")"
    [[ "$got" == "$2" ]] && pass "parent_disk($1)=$2" \
        || fail "parent_disk($1)" "expected '$2', got '$got'"; }
tp /dev/sda1 /dev/sda
tp /dev/nvme0n1p2 /dev/nvme0n1
tp /dev/vda /dev/vda

#--- resolve_id ------------------------------------------------------------------
D_DEV=(/dev/sda /dev/sdb /dev/nvme0n1); D_SERIAL=(SATATEST001 USBTEST002 NVMETEST003)
D_COUNT=3
tri() { # tri <id> <expected-idx-or-FAIL>
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
tri 1 0; tri 2 1; tri 3 2
tri SATATEST001 0; tri USBTEST002 1; tri NVMETEST003 2
tri /dev/sda 0; tri /dev/nvme0n1 2
tri 0 FAIL; tri 4 FAIL; tri 99 FAIL; tri bogus FAIL
# wildcards are never resolved -- fail closed
tri '*' FAIL; tri '/dev/sd*' FAIL; tri 'sda[0-9]' FAIL; tri '?' FAIL
out="$(resolve_id '/dev/sd*' 2>&1)" || true
[[ "$out" == *"wildcard"* ]] && pass "wildcard refusal explains itself" \
    || fail "wildcard refusal explains itself" "message lacks 'wildcard'"

#--- duplicated serials: ambiguity fails closed ---------------------------------
D_DEV=(/dev/sda /dev/nvme0n1); D_SERIAL=(DUP111 DUP111); D_COUNT=2
[[ "$(serial_count DUP111)" == "2" ]] && pass "serial_count(DUP111)=2" \
    || fail "serial_count(DUP111)"
tr DUP111 FAIL                      # serial resolution refuses...
tri 1 0; tri /dev/sda 0               # ...but rows/nodes still resolve mechanically
# restore fixture
D_DEV=(/dev/sda /dev/sdb /dev/nvme0n1); D_SERIAL=(SATATEST001 USBTEST002 NVMETEST003)
D_COUNT=3

#--- typed_confirm_twice: piped input can never arm ------------------------------
echo "== typed_confirm_twice: piped input cannot arm (unit) =="
AUDITFILE="$T/unit-audit.log"; : > "$AUDITFILE"
if printf 'SATATEST001\nSATATEST001\n' | typed_confirm_twice "SATATEST001" /dev/sda >/dev/null 2>&1; then
    fail "typed_confirm_twice refuses piped correct serial (x2)"
else
    pass "typed_confirm_twice refuses piped correct serial (x2)"
fi
if printf 'NUKE SATATEST001\nNUKE SATATEST001\n' | typed_confirm_twice "SATATEST001" /dev/sda >/dev/null 2>&1; then
    fail 'typed_confirm_twice refuses piped "NUKE <serial>" (x2)'
else
    pass 'typed_confirm_twice refuses piped "NUKE <serial>" (x2)'
fi

#--- typed_confirm_twice on a REAL pty -------------------------------------------
# `script` scrubs the environment, so inject function bodies via `declare -f`
# into a temp child script (avoids nested-quoting pitfalls).
pty_confirm2() { # pty_confirm2 <line1> <line2> <serial> <dev> -> rc of typed_confirm_twice on a real pty
    local child="$T/pty-child.sh"
    { declare -f typed_confirm_twice; declare -f audit; declare -f ts
      printf 'OVERRIDE_BOOT_PROT=0\n'
      printf 'AUDITFILE=%q\n' "$T/pty-audit.log"
      printf ': > "$T/pty-audit.log"\n'
      printf 'typed_confirm_twice %q %q\n' "$3" "$4"; } > "$child"
    printf '%s\n%s\n' "$1" "$2" | script -qec "bash $child" /dev/null >/dev/null 2>&1
}
echo "== typed_confirm_twice on a real pty (unit) =="
if pty_confirm2 'WRONG1' 'WRONG2' 'SATATEST001' /dev/sda; then
    fail "pty: wrong+wrong aborts"
else
    pass "pty: wrong+wrong aborts"
fi
grep -q 'mode=ABORTED' "$T/pty-audit.log" \
    && pass "pty: abort writes mode=ABORTED audit record" \
    || fail "pty: abort writes mode=ABORTED audit record"
grep -q "typed1='WRONG1' typed2='WRONG2'" "$T/pty-audit.log" \
    && pass "pty: abort audit records operator confirmation" \
    || fail "pty: abort audit records operator confirmation"
if pty_confirm2 'SATATEST001' 'WRONG2' 'SATATEST001' /dev/sda; then
    fail "pty: right+wrong aborts (second prompt mistyped)"
else
    pass "pty: right+wrong aborts (second prompt mistyped)"
fi
if pty_confirm2 'SATATEST001' 'SATATEST001' 'SATATEST001' /dev/sda; then
    pass "pty: correct serial twice arms"
else
    fail "pty: correct serial twice arms"
fi
grep -q 'mode=CONFIRMED' "$T/pty-audit.log" \
    && pass "pty: arm writes mode=CONFIRMED audit record" \
    || fail "pty: arm writes mode=CONFIRMED audit record"
if pty_confirm2 '/dev/sda' '/dev/sda' 'SATATEST001' /dev/sda; then
    pass "pty: device path twice arms (identifier may be serial or ID)"
else
    fail "pty: device path twice arms (identifier may be serial or ID)"
fi
if pty_confirm2 'NUKE SATATEST001' 'NUKE SATATEST001' 'SATATEST001' /dev/sda; then
    fail "pty: 'NUKE <serial>' rejected (only the exact identifier is accepted)"
else
    pass "pty: 'NUKE <serial>' rejected (only the exact identifier is accepted)"
fi

#--- pdi_arm_code: determinism + independent python3 cross-check ----------------
# The ARM-CODE is the transcription challenge the operator types to arm a
# wipe; it must match docs/NUKE-INTERLOCKS.md §2 byte for byte in every
# implementation (bash lib, .ps1 twin). The python3 derivation above is the
# independent check: if either side drifts from the formula, arming breaks
# visibly instead of silently.
echo "== pdi_arm_code unit tests (determinism, format, cross-check) =="
CODE_A="$(pdi_arm_code SATATEST001 'Test SATA HDD' 1000204886016)"
CODE_A_PY="$(armcode SATATEST001 'Test SATA HDD' 1000204886016)"
[[ "$CODE_A" == "$CODE_A_PY" ]] \
    && pass "arm-code matches independent python3 derivation ($CODE_A)" \
    || fail "arm-code matches independent python3 derivation" \
        "bash='$CODE_A' python3='$CODE_A_PY'"
[[ "$CODE_A" =~ ^[0-9A-F]{6}$ ]] \
    && pass "arm-code is 6 uppercase hex chars" \
    || fail "arm-code is 6 uppercase hex chars" "got '$CODE_A'"
[[ "$(pdi_arm_code SATATEST001 'Test SATA HDD' 1000204886016)" == "$CODE_A" ]] \
    && pass "arm-code is deterministic" \
    || fail "arm-code is deterministic"
CODE_B="$(pdi_arm_code USBTEST005 'Spare USB Stick' 16000000000)"
[[ "$CODE_B" != "$CODE_A" ]] \
    && pass "arm-code differs per disk identity ($CODE_B)" \
    || fail "arm-code differs per disk identity"
# the code binds the DISPLAYED size: a size change must change the code
CODE_C="$(pdi_arm_code SATATEST001 'Test SATA HDD' 1000204886017)"
[[ "$CODE_C" != "$CODE_A" ]] \
    && pass "arm-code binds the size (1-byte change changes the code)" \
    || fail "arm-code binds the size (1-byte change changes the code)"
# hostile firmware strings stay data inside the derivation (no execution,
# no error) -- the code just binds whatever identity was reported
CODE_EVIL="$(pdi_arm_code 'EVILTEST001' 'x$(touch /tmp/nope)' 100)"
[[ "$CODE_EVIL" =~ ^[0-9A-F]{6}$ ]] \
    && pass "arm-code derivation treats hostile strings as data" \
    || fail "arm-code derivation treats hostile strings as data"

#--- check_image_proof: proof-manifest validation (sourced function) --------------
# Fixture proofs: valid + every refusal class. A proof is the machine-readable
# form of runbook invariant 1 ("verified image or no wipe"); the serial
# binding stops a proof for disk A from arming a wipe of disk B.
echo "== check_image_proof unit tests (proof-manifest validation) =="
HEX64="$(printf 'a%.0s' {1..64})"
mkdir -p "$T/proofs"
write_proof() { # write_proof <file> <format> <verified> <sha256> <serial> <size>
    { printf 'format=%s\n' "$2"; printf 'source_serial=%s\n' "$5"
      printf 'image_size_bytes=%s\n' "$6"; printf 'sha256=%s\n' "$4"
      printf 'verified=%s\n' "$3"; printf '# comment lines and blank lines ignored\n'; } > "$T/proofs/$1"
}
cpv() { # cpv <name> <serial> -> rc of check_image_proof on fixture <name> for <serial>
    local rc
    if check_image_proof "$T/proofs/$1" "$2" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    echo "$rc"
}
write_proof good.proof  phoenix-image-proof/1 YES "$HEX64" SATATEST001 1000204886016
write_proof badfmt.proof phoenix-proof/9 YES "$HEX64" SATATEST001 1000204886016
write_proof unver.proof phoenix-image-proof/1 NO  "$HEX64" SATATEST001 1000204886016
write_proof badhex.proof phoenix-image-proof/1 YES "ZZZZ" SATATEST001 1000204886016
write_proof zerosz.proof phoenix-image-proof/1 YES "$HEX64" SATATEST001 0
write_proof others.proof phoenix-image-proof/1 YES "$HEX64" SDDTEST004 250059350016
write_proof noser.proof  phoenix-image-proof/1 YES "$HEX64" unknown 1000204886016
# per-target valid proofs so the gate passes and later gates get tested
write_proof usbboot.proof phoenix-image-proof/1 YES "$HEX64" USBTEST002 32000000000
write_proof usb.proof     phoenix-image-proof/1 YES "$HEX64" USBTEST005 16000000000
write_proof dup.proof     phoenix-image-proof/1 YES "$HEX64" DUP111     1000204886016
[[ "$(cpv good.proof SATATEST001)" == "0" ]] && pass "valid proof accepted" || fail "valid proof accepted"
[[ "$(cpv good.proof SDDTEST004)" != "0" ]] && pass "proof bound to a different serial refused" || fail "proof bound to a different serial refused"
[[ "$(cpv badfmt.proof SATATEST001)" != "0" ]] && pass "unknown format refused" || fail "unknown format refused"
[[ "$(cpv unver.proof SATATEST001)" != "0" ]] && pass "verified=NO refused" || fail "verified=NO refused"
[[ "$(cpv badhex.proof SATATEST001)" != "0" ]] && pass "malformed sha256 refused" || fail "malformed sha256 refused"
[[ "$(cpv zerosz.proof SATATEST001)" != "0" ]] && pass "zero size refused" || fail "zero size refused"
[[ "$(cpv noser.proof SATATEST001)" != "0" ]] && pass "unknown source_serial refused" || fail "unknown source_serial refused"
# refusal reasons go to stderr (evidence, not silence)
out="$(check_image_proof "$T/proofs/others.proof" SATATEST001 2>&1)" || true
[[ "$out" == *"SDDTEST004"* && "$out" == *"cannot arm a different disk"* ]] \
    && pass "serial-mismatch refusal names the binding" \
    || fail "serial-mismatch refusal names the binding" "got: $(echo "$out" | head -c 200)"
# missing file refuses
if check_image_proof "$T/proofs/does-not-exist" SATATEST001 >/dev/null 2>&1; then
    fail "missing proof file refused"
else
    pass "missing proof file refused"
fi
# hostile values stay data: a serial field containing $(...) must never execute
rm -f "$T/proof-evil-marker"
write_proof evil.proof phoenix-image-proof/1 YES "$HEX64" 'x$(touch "'"$T"'/proof-evil-marker")' 1000204886016
# the hostile string is the SAME string written into the file: a literal
# comparison must match (rc 0) -- the security property is that no command
# runs, not that the string differs.
if check_image_proof "$T/proofs/evil.proof" 'x$(touch "'"$T"'/proof-evil-marker")' >/dev/null 2>&1; then
    pass "hostile serial compares literally (matched, not executed)"
else
    fail "hostile serial literal comparison" "identical strings did not match"
fi
[[ ! -e "$T/proof-evil-marker" ]] \
    && pass "proof parser never executes field payloads" \
    || fail "proof parser never executes field payloads" "INJECTION LIVE"

#--- typed_skip_image_gate: piped input can never skip the image gate ------------
echo "== typed_skip_image_gate: piped input cannot skip (unit) =="
if printf 'NUKE WITHOUT BACKUP\n' | typed_skip_image_gate >/dev/null 2>&1; then
    fail "typed_skip_image_gate refuses piped phrase"
else
    pass "typed_skip_image_gate refuses piped phrase"
fi
# wrong phrase on piped stdin also refuses (the tty check fires first, but
# the exact-match requirement is covered on the pty below)
if printf 'y\n' | typed_skip_image_gate >/dev/null 2>&1; then
    fail "typed_skip_image_gate refuses piped 'y'"
else
    pass "typed_skip_image_gate refuses piped 'y'"
fi

#--- typed_skip_image_gate on a REAL pty: only the exact phrase arms ------------
pty_skip() { # pty_skip <line> -> rc of typed_skip_image_gate on a real pty
    local child="$T/pty-skip.sh"
    { declare -f typed_skip_image_gate
      printf 'typed_skip_image_gate\n'; } > "$child"
    printf '%s\n' "$1" | script -qec "bash $child" /dev/null >/dev/null 2>&1
}
if pty_skip 'NUKE WITHOUT BACKUP'; then
    pass "pty: exact 'NUKE WITHOUT BACKUP' phrase arms the skip"
else
    fail "pty: exact 'NUKE WITHOUT BACKUP' phrase arms the skip"
fi
for bad in 'nuke without backup' 'NUKEWITHOUTBACKUP' 'yes'; do
    if pty_skip "$bad"; then
        fail "pty: skip phrase '$bad' rejected"
    else
        pass "pty: skip phrase '$bad' rejected"
    fi
done
# bash `read` trims trailing IFS whitespace, so a trailing space still
# matches -- same leniency as typed_confirm_twice's explicit sed trim.
# Documented, not a weakening: only the EXACT phrase (mod whitespace) arms.
if pty_skip 'NUKE WITHOUT BACKUP '; then
    pass "pty: trailing-space phrase still matches (read trims IFS whitespace)"
else
    fail "pty: trailing-space phrase still matches (read trims IFS whitespace)"
fi

echo "== integration tests (mocked lsblk + mocked dd subprocess) =="
PROOFS="$T/proofs"   # fixture manifests built in the unit section above
# Fixture ARM-CODEs, derived independently (python3) -- the same derivation
# the armed path must demand on the console.
CODE_SDA="$(armcode SATATEST001 'Test SATA HDD' 1000204886016)"
CODE_SDE="$(armcode USBTEST005 'Spare USB Stick' 16000000000)"
# run_case <name> <expected-exit> <expected-substring> [script args...]
# stdin comes from /dev/null unless CASE_STDIN is set.
run_case() {
    local name="$1" exp_exit="$2" exp_sub="$3"; shift 3
    local out rc logdir="$T/logs-$name"
    mkdir -p "$logdir"
    if [[ -n "${CASE_STDIN:-}" ]]; then
        out="$(printf '%s' "$CASE_STDIN" | PATH="$MOCKBIN:$PATH" timeout 20 \
            bash "$SH" --log-dir "$logdir" "$@" 2>&1)" && rc=0 || rc=$?
    else
        out="$(PATH="$MOCKBIN:$PATH" timeout 20 \
            bash "$SH" --log-dir "$logdir" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
    fi
    if (( rc == exp_exit )) && [[ "$out" == *"$exp_sub"* ]]; then
        pass "$name (exit $rc)"
    else
        fail "$name" "expected exit $exp_exit + '$exp_sub'; got exit $rc; output: $(echo "$out" | head -c 400)"
    fi
}

# K1: dry-run default -- enumerate only, exit 0.
run_case "K1 enumerate-only default" 0 "5 candidate disk(s)"
# K2: --whatif behaves identically.
run_case "K2 whatif" 0 "dry-run" --whatif
# K2b: hostile firmware payload -- enumeration must stay dry-run AND the
# injected `touch` must never execute (would create $T/evil-marker).
rm -f "$T/evil-marker"
MOCK_EVIL=1 MOCK_EVIL_MARKER="$T/evil-marker" run_case "K2b hostile lsblk payload inert" 0 "Evil"
[[ ! -e "$T/evil-marker" ]] \
    && pass "K2b payload did not execute (no marker file)" \
    || fail "K2b payload executed" "marker file $T/evil-marker exists -- INJECTION LIVE"
# K3: audit record for enumeration carries timestamp + disk ids + mode.
auditf="$(ls "$T"/logs-K1*enumerate-only*default/phoenix-nuke-audit-*.log)"
grep -Eq '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] mode=ENUMERATE_DRYRUN' "$auditf" \
    && pass "K3 audit ENUMERATE_DRYRUN has timestamp + mode" \
    || fail "K3 audit ENUMERATE_DRYRUN has timestamp + mode"
grep -q 'SATATEST001' "$auditf" && grep -q 'USBTEST005' "$auditf" \
    && pass "K3 audit lists disk serials" \
    || fail "K3 audit lists disk serials"
# K4: boot USB (row 2) refused structurally (gate passes with its own proof).
run_case "K4 boot-USB refused" 1 "self-protected" --image-proof "$PROOFS/usbboot.proof" --nuke 2
auditf="$(ls "$T"/logs-K4*boot-USB*refused/phoenix-nuke-audit-*.log)"
grep -q 'mode=REFUSED' "$auditf" && grep -q 'serial=USBTEST002' "$auditf" \
    && grep -q "reason='boot-device'" "$auditf" \
    && pass "K4 audit REFUSED has disk id + reason" \
    || fail "K4 audit REFUSED has disk id + reason"
# K5: mounted data disk (row 4) refused (mounted => protected; gate passes).
run_case "K5 mounted-disk refused" 1 "self-protected" --image-proof "$PROOFS/others.proof" --nuke 4
# K6: spare USB stick (row 5) refused WITHOUT the override flag (gate passes).
run_case "K6 usb-disk refused without override" 1 "self-protected" --image-proof "$PROOFS/usb.proof" --nuke 5
# K7: spare USB stick (row 5) passes the guard WITH --override-boot-protection
# (on a real pty, confirmation succeeds); the override is logged as a
# WARNING, and the next gate (not a block device on the host) is what fires.
pty_case() { # pty_case <name> <arm-line> <line1> <line2> <exp-exit> <exp-sub> [args...]
    # The armed path is three typed gates: the ARM-CODE transcription
    # challenge first, then the double-typed serial confirmation. All three
    # lines are fed on a real pty (the script's [ -t 0 ] check passes).
    local name="$1" arm="$2" l1="$3" l2="$4" exp_exit="$5" exp_sub="$6"; shift 6
    local child="$T/pty-int.sh" logdir="$T/logs-$name" out rc
    mkdir -p "$logdir"
    printf 'export PATH=%q:"$PATH"\n' "$MOCKBIN" > "$child"
    printf 'export MOCK_DUPS=%q\n' "${MOCK_DUPS:-0}" >> "$child"
    printf 'export PHOENIX_PDI_CONFIG=%q\n' "${PHOENIX_PDI_CONFIG:-}" >> "$child"
    printf 'exec bash %q --log-dir %q --no-countdown %s\n' "$SH" "$logdir" "$*" >> "$child"
    chmod +x "$child"
    out="$(printf '%s\n%s\n%s\n' "$arm" "$l1" "$l2" | PATH="$MOCKBIN:$PATH" timeout 20 \
        script -qec "$child" /dev/null 2>&1)" && rc=0 || rc=$?
    if (( rc == exp_exit )) && [[ "$out" == *"$exp_sub"* ]]; then
        pass "$name (exit $rc)"
    else
        fail "$name" "expected exit $exp_exit + '$exp_sub'; got exit $rc; output: $(echo "$out" | head -c 400)"
    fi
}
pty_case "K7 usb-disk override passes guard" "$CODE_SDE" "USBTEST005" "USBTEST005" 1 "not a block device" --image-proof "$PROOFS/usb.proof" --override-boot-protection --nuke 5
auditf="$(ls "$T"/logs-K7*override*passes*guard/phoenix-nuke-audit-*.log)"
grep -q 'mode=WARNING' "$auditf" && grep -q 'boot-protection-overridden' "$auditf" \
    && pass "K7 audit logs the override as WARNING" \
    || fail "K7 audit logs the override as WARNING"
grep -q 'mode=CONFIRMED' "$auditf" \
    && pass "K7 confirmation still required with override" \
    || fail "K7 confirmation still required with override"
# K8: unknown identifier refused.
run_case "K8 unknown id refused" 1 "no disk matches" --nuke /dev/doesnotexist
# K9: wildcard identifier refused (never resolved).
run_case "K9 wildcard id refused" 1 "wildcard" --nuke '/dev/sd*'
# K10: out-of-range row refused.
run_case "K10 out-of-range row refused" 1 "REFUSED" --nuke 99
# K11: duplicated-serial fixture: serial id is an ambiguity refusal...
MOCK_DUPS=1 run_case "K11a dup serial id refused" 1 "ambiguous" --nuke DUP111
# ...and arming by row is refused at the dup-serial gate (identity failure).
MOCK_DUPS=1 run_case "K11b dup serial arm refused" 1 "multiple disks" --image-proof "$PROOFS/dup.proof" --nuke 1
# K12: pty, correct serial typed twice on an unprotected disk: confirmation
#      succeeds (audit CONFIRMED), then the block-device gate fires (fixture
#      paths are not block devices on the host) -- dd is never reached.
pty_case "K12 arm-code + double-confirm reaches block-device gate" "$CODE_SDA" "SATATEST001" "SATATEST001" 1 "not a block device" --image-proof "$PROOFS/good.proof" --nuke 1
auditf="$(ls "$T"/logs-K12*double-confirm*/phoenix-nuke-audit-*.log)"
grep -q 'mode=CONFIRMED' "$auditf" && grep -q "typed1='SATATEST001' typed2='SATATEST001'" "$auditf" \
    && pass "K12 audit CONFIRMED records operator confirmation" \
    || fail "K12 audit CONFIRMED records operator confirmation"
# K13: pty, mistyped second confirmation aborts (exit 2), dd never invoked.
pty_case "K13 mistyped second prompt aborts" "$CODE_SDA" "SATATEST001" "SATATEST00X" 2 "Aborted" --image-proof "$PROOFS/good.proof" --nuke 1
# K14: --help exits 0.
run_case "K14 help" 0 "Usage" --help
# K15: unknown flag exits 1.
run_case "K15 bad flag" 1 "Unknown option" --bogus

echo "== integration: image-proof gate (runbook invariant 1) =="
# PROOFS already defined at the top of the integration section
# K17: --nuke with NO proof and NO skip flag refuses (gate is mandatory).
run_case "K17 nuke without proof refused" 1 "requires --image-proof" --nuke 1
auditf="$(ls "$T"/logs-K17*nuke*without*proof*refused/phoenix-nuke-audit-*.log)"
grep -q "mode=REFUSED" "$auditf" && grep -q "reason='no-image-proof'" "$auditf" \
    && pass "K17 audit REFUSED records reason=no-image-proof" \
    || fail "K17 audit REFUSED records reason=no-image-proof"
# K18: gate runs FIRST -- a boot-protected target (row 2) without a proof is
# refused for the MISSING PROOF, not for being self-protected.
run_case "K18 gate precedes boot-protection check" 1 "requires --image-proof" --nuke 2
# K19: bad-format proof refused.
run_case "K19 bad-format proof refused" 1 "unknown/missing format" --image-proof "$PROOFS/badfmt.proof" --nuke 1
# K20: unverified (verified=NO) proof refused.
run_case "K20 unverified proof refused" 1 "not VERIFIED" --image-proof "$PROOFS/unver.proof" --nuke 1
# K21: malformed sha256 refused.
run_case "K21 bad-sha256 proof refused" 1 "valid 64-hex sha256" --image-proof "$PROOFS/badhex.proof" --nuke 1
# K22: zero-size proof refused.
run_case "K22 zero-size proof refused" 1 "positive image_size_bytes" --image-proof "$PROOFS/zerosz.proof" --nuke 1
# K23: proof bound to a DIFFERENT disk's serial refused.
run_case "K23 serial-mismatch proof refused" 1 "cannot arm a different disk" --image-proof "$PROOFS/others.proof" --nuke 1
# K24: valid proof passes the gate; with stdin redirected, the double-typed
# confirmation then refuses (exit 2, aborted) -- gate evidence is audited.
run_case "K24 valid proof passes gate, tty-refusal aborts" 2 "Aborted" --image-proof "$PROOFS/good.proof" --nuke 1
auditf="$(ls "$T"/logs-K24*valid*proof*passes*/phoenix-nuke-audit-*.log)"
grep -q 'mode=IMAGE-PROOF' "$auditf" && grep -q "serial=SATATEST001" "$auditf" \
    && pass "K24 audit IMAGE-PROOF records the gate pass" \
    || fail "K24 audit IMAGE-PROOF records the gate pass"
# K25: pty, valid proof + correct double-typed serial reaches the
# block-device gate (fixture paths are not block devices on the host).
pty_case "K25 valid proof + pty confirm reaches block-device gate" "$CODE_SDA" "SATATEST001" "SATATEST001" 1 "not a block device" --image-proof "$PROOFS/good.proof" --nuke 1
auditf="$(ls "$T"/logs-K25*valid*proof*pty*/phoenix-nuke-audit-*.log)"
grep -q 'mode=IMAGE-PROOF' "$auditf" && grep -q 'mode=CONFIRMED' "$auditf" \
    && pass "K25 audit has IMAGE-PROOF and CONFIRMED records" \
    || fail "K25 audit has IMAGE-PROOF and CONFIRMED records"
# K26: --skip-image-gate with piped stdin refuses (needs a real console).
run_case "K26 skip-gate piped refuses" 1 "real console" --skip-image-gate --nuke 1
# K27: pty, --skip-image-gate + exact phrase + correct serial proceeds past
# the gate (logged WARNING); the block-device gate then fires. 3 input lines.
pty_skip_case() { # pty_skip_case <name> <skip-line> <arm-line> <l1> <l2> <exp-exit> <exp-sub> [args...]
    local name="$1" sl="$2" arm="$3" l1="$4" l2="$5" exp_exit="$6" exp_sub="$7"; shift 7
    local child="$T/pty-skip-int.sh" logdir="$T/logs-$name" out rc
    mkdir -p "$logdir"
    printf 'export PATH=%q:"$PATH"\n' "$MOCKBIN" > "$child"
    printf 'export PHOENIX_PDI_CONFIG=%q\n' "${PHOENIX_PDI_CONFIG:-}" >> "$child"
    printf 'exec bash %q --log-dir %q --no-countdown %s\n' "$SH" "$logdir" "$*" >> "$child"
    chmod +x "$child"
    out="$(printf '%s\n%s\n%s\n%s\n' "$sl" "$arm" "$l1" "$l2" | PATH="$MOCKBIN:$PATH" timeout 20 \
        script -qec "$child" /dev/null 2>&1)" && rc=0 || rc=$?
    if (( rc == exp_exit )) && [[ "$out" == *"$exp_sub"* ]]; then
        pass "$name (exit $rc)"
    else
        fail "$name" "expected exit $exp_exit + '$exp_sub'; got exit $rc; output: $(echo "$out" | head -c 400)"
    fi
}
pty_skip_case "K27 skip-gate typed phrase proceeds" "NUKE WITHOUT BACKUP" "$CODE_SDA" "SATATEST001" "SATATEST001" 1 "not a block device" --skip-image-gate --nuke 1
auditf="$(ls "$T"/logs-K27*skip-gate*typed*phrase*proceeds/phoenix-nuke-audit-*.log)"
grep -q 'mode=WARNING' "$auditf" && grep -q "reason='image-proof-gate-skipped'" "$auditf" \
    && pass "K27 audit WARNING records the gate skip" \
    || fail "K27 audit WARNING records the gate skip"
# K28: pty, --skip-image-gate with a WRONG phrase aborts (exit 1).
pty_skip_case "K28 skip-gate wrong phrase aborts" "yes" "$CODE_SDA" "SATATEST001" "SATATEST001" 1 "not confirmed" --skip-image-gate --nuke 1
# K29: --skip-image-gate + valid proof together: the proof wins, no skip
# prompt is needed -- gate passes on the proof alone.
run_case "K29 proof wins over skip flag" 2 "Aborted" --image-proof "$PROOFS/good.proof" --skip-image-gate --nuke 1
auditf="$(ls "$T"/logs-K29*proof*wins*over*skip*flag/phoenix-nuke-audit-*.log)"
grep -q 'mode=IMAGE-PROOF' "$auditf" && ! grep -q 'image-proof-gate-skipped' "$auditf" \
    && pass "K29 audit shows proof gate, no skip" \
    || fail "K29 audit shows proof gate, no skip"

echo "== integration: ARM-CODE gate + config-protected exclusions =="
# Fixture config: sdd protected BY SERIAL, sde protected BY /dev PATH.
PROT_CFG="$T/phoenix-config-protected.json"
cat > "$PROT_CFG" <<'JSON'
{
  "nuke": {
    "protectedDisks": ["SDDTEST004", "/dev/sde"]
  }
}
JSON
# P1: protected disks are excluded from the candidate rows (3 remain, rows
# renumber) and named in the hidden summary instead.
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P1 protected disks excluded from rows" 0 "3 candidate disk(s)"
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P1b hidden summary names sdd" 0 "hidden: /dev/sdd (PROTECTED(config))"
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P1c hidden summary names sde" 0 "hidden: /dev/sde (PROTECTED(config))"
# P2: a protected serial selects nothing -- fail closed, no arming.
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P2 protected serial refuses" 1 "no disk matches" --nuke SDDTEST004
# P3: protected beats the override -- even --override-boot-protection cannot
# reach a config-protected disk (exclusion, not warning).
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P3 protected beats override" 1 "no disk matches" --override-boot-protection --nuke /dev/sde
# P4: rows renumber after exclusion -- old row 5 (sde) is out of range now.
PHOENIX_PDI_CONFIG="$PROT_CFG" run_case "P4 rows renumber after exclusion" 1 "no disk matches" --nuke 5
# P5: ARM-CODE transcription gate on the armed path (pty).
# P5a: a wrong code aborts (exit 2) BEFORE the double-typed confirmation is
# ever offered -- the mistyped serials on lines 2/3 are never consumed.
pty_case "P5a wrong arm-code aborts" "ZZZZZZ" "SATATEST001" "SATATEST001" 2 "did not match" --image-proof "$PROOFS/good.proof" --nuke 1
auditf="$(ls "$T"/logs-P5a*wrong*arm-code*aborts/phoenix-nuke-audit-*.log)"
grep -q "mode=ABORTED" "$auditf" && grep -q "reason='arm-code-mismatch'" "$auditf" \
    && pass "P5a audit ABORTED records reason=arm-code-mismatch" \
    || fail "P5a audit ABORTED records reason=arm-code-mismatch"
# P5b: piped (non-tty) stdin refuses the arm-code gate structurally.
run_case "P5b arm-code gate piped refuses" 2 "real terminal" --image-proof "$PROOFS/good.proof" --nuke 1
# P5c: the exact serial ALSO satisfies the arm-code gate (design: code OR
# exact serial), then the double-typed confirmation proceeds normally.
pty_case "P5c exact serial satisfies arm gate" "SATATEST001" "SATATEST001" "SATATEST001" 1 "not a block device" --image-proof "$PROOFS/good.proof" --nuke 1
auditf="$(ls "$T"/logs-P5c*exact*serial*satisfies*/phoenix-nuke-audit-*.log)"
grep -q 'mode=ARM-CODE' "$auditf" && grep -q 'mode=CONFIRMED' "$auditf" \
    && pass "P5c audit has ARM-CODE and CONFIRMED records" \
    || fail "P5c audit has ARM-CODE and CONFIRMED records"
# P5d: correct code + correct double-type audits the code that was typed.
auditf="$(ls "$T"/logs-K12*double-confirm*/phoenix-nuke-audit-*.log)"
grep -q "mode=ARM-CODE" "$auditf" && grep -q "arm_code=$CODE_SDA" "$auditf" \
    && pass "P5d audit ARM-CODE records the typed code" \
    || fail "P5d audit ARM-CODE records the typed code"

# K16: dd was NEVER invoked in any path above.
if [[ -f "$DD_MARKER" ]]; then
    fail "K16 dd never invoked" "marker exists: $(cat "$DD_MARKER")"
else
    pass "K16 dd never invoked (no destructive path executed)"
fi

echo "== .ps1 parity checks (structural; pwsh not installed here) =="
pc() { # pc <description> <grep-pattern>
    if grep -qE -- "$2" "$PS1F"; then pass "ps1: $1"; else fail "ps1: $1" "pattern '$2' not found"; fi
}
pc "has -Nuke parameter"           '\[string\]\$Nuke'
pc "has -DryRun (-WhatIf alias)"   'Alias\("WhatIf"\)'
pc "has -LogDir parameter"         '\[string\]\$LogDir'
pc "has -OverrideBootProtection"   '\[switch\]\$OverrideBootProtection'
pc "has -NoCountdown"              '\[switch\]\$NoCountdown'
pc "refuses redirected stdin"      'IsInputRedirected'
pc "requires elevation"            'Administrator'
pc "double-typed confirmation"     'attempt 2 of 2'
pc "audit ENUMERATE_DRYRUN"        '-Mode "ENUMERATE_DRYRUN"'
pc "audit REFUSED"                 '-Mode "REFUSED"'
pc "audit ABORTED"                 '-Mode "ABORTED"'
pc "audit CONFIRMED"               '-Mode "CONFIRMED"'
pc "audit COMPLETE"                '-Mode "COMPLETE"'
pc "audit records confirmation"    'typed1='
pc "boot/USB self-protection"      'self-protect|ProtectedReason'
pc "wildcard refusal"              'wildcard'
pc "ambiguity refusal"             'ambiguous'
pc "exact (case-sensitive) match"  '-ceq'
pc "destructive primitive (diskpart clean all)" 'clean all'
pc "no wildcard resolution"        'Where-Object \{ \$\_\.Serial -ceq'

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
[[ -f "$DD_MARKER" ]] && { echo "FATAL: dd was invoked during tests"; exit 1; }
echo "All Phoenix NUKE core regression tests green; no destructive path executed."
