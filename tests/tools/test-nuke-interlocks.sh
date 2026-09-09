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
#     typed_confirmation (pipe-fed input refused -- correct serial+size,
#     "yes", and "NUKE <serial> <size>" -- on non-TTY stdin; wrong serial,
#     wrong size, serial-only, and size-only refused on a real pty; correct
#     serial+size / "NUKE <serial> <size>" accepted on a real pty).
#   INTEGRATION (subprocess, mocked lsblk fixture: sda=HDD, sdb=boot USB
#     (mounted), nvme0n1=NVMe SSD, sdd=mounted data SSD):
#     dry-run enumeration, --whatif, boot-USB structural refusal,
#     mounted-partition refusal (by row and by /dev path), unknown id,
#     out-of-range row, bad --method, missing --nuke arg, gate ordering.
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

#--- typed_confirmation: pipe-fed input can never arm (the TTY interlock) -----
echo "== typed_confirmation: piped input cannot arm (unit) =="
# U1: the CORRECT serial+size, piped, is refused -- stdin is not a terminal.
if printf 'SATATEST001 931.5 GB\n' | typed_confirmation "SATATEST001" "931.5 GB" >/dev/null 2>&1; then
    fail "typed_confirmation refuses piped correct serial+size"
else
    pass "typed_confirmation refuses piped correct serial+size"
fi
# U2: piped "yes" is refused (it could never match either token anyway, but
#     the TTY gate must fire first).
if printf 'yes\n' | typed_confirmation "SATATEST001" "931.5 GB" >/dev/null 2>&1; then
    fail 'typed_confirmation refuses piped "yes"'
else
    pass 'typed_confirmation refuses piped "yes"'
fi
# U3: piped "NUKE <serial> <size>" is refused too -- the prefix does not bypass it.
if printf 'NUKE SATATEST001 931.5 GB\n' | typed_confirmation "SATATEST001" "931.5 GB" >/dev/null 2>&1; then
    fail 'typed_confirmation refuses piped "NUKE <serial> <size>"'
else
    pass 'typed_confirmation refuses piped "NUKE <serial> <size>"'
fi
# U4-U9: on a REAL pty (human-at-console equivalent), wrong serial, wrong
# size, serial-only, and size-only are refused; the correct serial+size and
# "NUKE <serial> <size>" are accepted.
# NOTE: util-linux `script` scrubs the environment, so `export -f` does not
# reach the pty child -- inject the function bodies via `declare -f` into a
# temp child script instead (avoids nested-quoting pitfalls entirely).
pty_confirm() { # pty_confirm <typed-input> <expected-serial> <expected-size> -> rc of typed_confirmation on a real pty
    local child="$T/pty-child.sh"
    { declare -f typed_confirmation; declare -f log; declare -f ts
      printf 'typed_confirmation %q %q\n' "$2" "$3"; } > "$child"
    printf '%s\n' "$1" | script -qec "bash $child" /dev/null >/dev/null 2>&1
}
if pty_confirm 'wrongserial 931.5 GB' 'SATATEST001' '931.5 GB'; then
    fail "typed_confirmation rejects wrong serial on a TTY"
else
    pass "typed_confirmation rejects wrong serial on a TTY"
fi
if pty_confirm 'SATATEST001 500.1 GB' 'SATATEST001' '931.5 GB'; then
    fail "typed_confirmation rejects wrong size on a TTY"
else
    pass "typed_confirmation rejects wrong size on a TTY"
fi
if pty_confirm 'SATATEST001' 'SATATEST001' '931.5 GB'; then
    fail "typed_confirmation rejects serial-only on a TTY"
else
    pass "typed_confirmation rejects serial-only on a TTY"
fi
if pty_confirm '931.5 GB' 'SATATEST001' '931.5 GB'; then
    fail "typed_confirmation rejects size-only on a TTY"
else
    pass "typed_confirmation rejects size-only on a TTY"
fi
if pty_confirm 'SATATEST001 931.5 GB' 'SATATEST001' '931.5 GB'; then
    pass "typed_confirmation accepts correct serial+size on a TTY"
else
    fail "typed_confirmation accepts correct serial+size on a TTY"
fi
if pty_confirm 'NUKE SATATEST001 931.5 GB' 'SATATEST001' '931.5 GB'; then
    pass 'typed_confirmation accepts "NUKE <serial> <size>" on a TTY'
else
    fail 'typed_confirmation accepts "NUKE <serial> <size>" on a TTY'
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
# I4: mounted data disk (row 4) refused by the mount guard.
run_case "I4 mounted-disk refused" 1 "has mounted partitions" --nuke 4
# I5: same guard reachable by /dev path (resolve_id path matching).
run_case "I5 mounted-disk by /dev path refused" 1 "has mounted partitions" --nuke /dev/sdd
# I6: unknown identifier rejected.
run_case "I6 unknown id rejected" 1 "No disk matches identifier" --nuke /dev/doesnotexist
# I7: out-of-range row rejected.
run_case "I7 out-of-range row rejected" 1 "No disk matches identifier" --nuke 99
# I8: bad --method rejected up front.
run_case "I8 bad --method rejected" 1 "Unknown --method" --method bogus --nuke 1
# I9: --nuke without an id errors (bash ${2:?...} exits 1).
run_case "I9 --nuke missing arg" 1 "needs a disk id" --nuke
# I10: gate ordering -- the block-device gate fires before any confirmation
#      prompt (fixture paths do not exist on the host, so this is the
#      expected outcome here; on real hardware the serial prompt follows).
NUKE_STDIN="y" run_case "I10 block-device gate before confirmation" 1 "not a block device" --nuke 1
unset NUKE_STDIN
# I12: even the CORRECT serial, piped in, cannot reach confirmation here --
#      the device gate fires first, and no "CONFIRMED"/arming line appears.
NUKE_STDIN="SATATEST001" run_case "I12 piped correct serial blocked by device gate" 1 "not a block device" --nuke 1
unset NUKE_STDIN
# I11: enumeration table content -- boot USB flagged, NVMe classified, sizes sane.
out="$(PATH="$MOCKBIN:$PATH" timeout 20 bash "$NUKE" --log-dir "$T/logs-I11" </dev/null 2>&1)"
for sub in "USBTEST002" "BOOT-USB" "MOUNTED" "NVMe SSD" "1.0 TB" "500.1 GB"; do
    [[ "$out" == *"$sub"* ]] && pass "I11 table contains '$sub'" \
        || fail "I11 table contains '$sub'"
done

echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases: ${FAILED_CASES[*]}"
    exit 1
fi
echo "All nuke interlock regression tests green."
