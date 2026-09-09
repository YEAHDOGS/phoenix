#!/usr/bin/env bash
#===============================================================================
# test-phoenix-nuke-guard.sh -- regression harness for the Phoenix NUKE arming
# guard: tools/phoenix-nuke-guard.sh (interactive front gate for the boot
# menu's NUKE path).
#
# Tests the arming contract WITHOUT any destructive primitive -- the guard
# script contains no destructive code at all, which the suite asserts. All
# runs are against mocked `lsblk` and fixture /proc files:
#   - fixture disks: sda=spare SATA HDD (ARMABLE), sdb=boot USB hosting
#     / and /boot (BOOT -- refused), nvme0n1=spare NVMe SSD (ARMABLE),
#     sdd=mounted data SSD at /mnt/data (MOUNTED -- refused), sde=spare USB
#     stick NOT mounted (ARMABLE).
#   - hostile firmware strings (MOCK_EVIL=1) must parse as data; the marker
#     file must never be created.
#   - pty runs use `script -qec` with a child wrapper that re-exports the
#     fixture env (script scrubs the environment).
#
# Coverage:
#   UNIT (functions sourced from the real script, trailing `main "$@"`
#   stripped): parse_lsblk_pairs (benign, -P unescaping, hostile $() and
#   quote-breakout payloads never execute), resolve_exact_dev (exact /dev
#   path only; prefixes, row numbers, serials, wildcards, whitespace
#   refused), detect_boot_disks (cmdline root= + / and /boot mounts; mounted
#   data disk is NOT a boot disk), typed_confirm (exact case-sensitive
#   match; piped stdin refused), human_size sanity.
#   INTEGRATION (subprocess, mocked lsblk + fixture /proc): dry-run default
#   and --whatif enumerate only (exit 0, no ARMED); --nuke with piped stdin
#   refused; on a real pty: exact /dev path + exact "NUKE <dev>" phrase arms
#   (ARMED target=...), partial paths/row numbers/serials/wildcards refused
#   (exit 1), wrong-case/extra-space/wrong-device phrases abort (exit 2),
#   boot disk refused, mounted disk refused, --override-boot-protection arms
#   with WARNING logged, --exec hands the validated path to the nuke tool,
#   audit log records CONFIRMED/REFUSED/ABORTED, --help, unknown flag.
#   STATIC: no destructive primitive (dd/mkfs/wipefs/shred/blkdiscard) and
#   no credential literals in the new script or tests.
#
# Deliberately NOT covered (VM-only, see docs/NUKE-TEST-PLAN.md): real block
# devices, real /proc.
#
# Usage: bash tests/tools/test-phoenix-nuke-guard.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$REPO/tools/phoenix-nuke-guard.sh"
T="$(mktemp -d /tmp/phoenix-nuke-guard-test.XXXXXX)"
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN"
export EVIL_MARKER="$T/EVIL_WAS_EXECUTED"
FIXT_MOUNTS="$T/proc-mounts"
FIXT_CMDLINE="$T/proc-cmdline"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- fixture /proc files --------------------------------------------------------
cat > "$FIXT_CMDLINE" <<'EOF'
BOOT_IMAGE=/vmlinuz root=/dev/sdb1 ro quiet
EOF
# /dev/sdb1 hosts / , /dev/sdb2 hosts /boot, /dev/sdd1 hosts /mnt/data
cat > "$FIXT_MOUNTS" <<'EOF'
/dev/sdb1 / ext4 rw,relatime 0 0
/dev/sdb2 /boot ext4 rw,relatime 0 0
/dev/sdd1 /mnt/data ext4 rw,relatime 0 0
EOF

#--- mock lsblk ----------------------------------------------------------------
cat > "$MOCKBIN/lsblk" <<'MOCK'
#!/usr/bin/env bash
args="$*"
last="${@: -1}"
evil="${MOCK_EVIL:-0}"
case "$args" in
  *"-ndo PKNAME"*)
    case "$last" in
      /dev/sdb1|/dev/sdb2) echo sdb ;; /dev/sdd1) echo sdd ;; *) echo "" ;;
    esac ;;
  *"-nr -o MOUNTPOINTS"*)
    case "$last" in
      /dev/sdb) echo "/media/phoenix-boot" ;; /dev/sdd) echo "/mnt/data" ;;
    esac ;;
  *"-P -b -d"*)
    if [[ "$evil" == "1" ]]; then
      # Hostile firmware, escaped the way real `lsblk -P` emits it. Must be
      # DATA: the row still enumerates, nothing executes.
      echo "NAME=\"sda\" MODEL=\"Evil\\\"; touch \\\"$EVIL_MARKER\\\"; echo \\\"X\\\"\" SERIAL=\"EVILTEST001\" SIZE=\"1000204886016\" TRAN=\"sata\" RM=\"0\" ROTA=\"1\" TYPE=\"disk\""
    else
      echo 'NAME="sda" MODEL="Spare SATA HDD" SERIAL="SATATEST001" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
    fi
    echo 'NAME="sdb" MODEL="Phoenix Boot USB" SERIAL="USBTEST002" SIZE="32000000000" TRAN="usb" RM="1" ROTA="1" TYPE="disk"'
    echo 'NAME="nvme0n1" MODEL="Spare NVMe SSD" SERIAL="NVMETEST003" SIZE="500107862016" TRAN="nvme" RM="0" ROTA="0" TYPE="disk"'
    echo 'NAME="sdd" MODEL="Mounted Data SSD" SERIAL="SDDTEST004" SIZE="250059350016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"'
    echo 'NAME="sde" MODEL="Spare USB Stick" SERIAL="USBTEST005" SIZE="16000000000" TRAN="usb" RM="1" ROTA="0" TYPE="disk"' ;;
  *) echo "mock-lsblk: unhandled args: $args" >&2; exit 99 ;;
esac
MOCK
chmod +x "$MOCKBIN/lsblk"

export PATH="$MOCKBIN:$PATH"
export PHOENIX_GUARD_PROC_MOUNTS="$FIXT_MOUNTS"
export PHOENIX_GUARD_PROC_CMDLINE="$FIXT_CMDLINE"

#--- preflight ------------------------------------------------------------------
echo "== preflight =="
[[ -f "$SH" ]] || { echo "FATAL: $SH not found"; exit 1; }
bash -n "$SH" && pass "bash -n syntax check (phoenix-nuke-guard.sh)" \
    || fail "bash -n syntax check (phoenix-nuke-guard.sh)"
for primitive in '\bdd\b' '\bmkfs\b' '\bwipefs\b' '\bshred\b' '\bblkdiscard\b' 'diskpart' 'Secure Erase'; do
    if grep -qE "$primitive" "$SH"; then
        fail "static: no destructive primitive ($primitive)"
    else
        pass "static: no destructive primitive ($primitive)"
    fi
done
if grep -qiE 'password|token|secret|api[_-]?key|bearer' "$SH"; then
    fail "static: secrets hygiene (no credential literals)"
else
    pass "static: secrets hygiene (no credential literals)"
fi

#--- source the real script's functions (strip the trailing `main "$@"`) --------
SRC_STRIPPED="$T/phoenix-nuke-guard-src.sh"
grep -v '^main \"\$@\"$' "$SH" > "$SRC_STRIPPED"
# shellcheck disable=SC1090
source "$SRC_STRIPPED"

echo "== unit: parse_lsblk_pairs =="
parse_lsblk_pairs 'NAME="sda" MODEL="Spare SATA HDD" SERIAL="SATATEST001" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
[[ "${LP[NAME]:-}" == "sda" && "${LP[MODEL]:-}" == "Spare SATA HDD" && "${LP[TYPE]:-}" == "disk" ]] \
    && pass "parse_lsblk_pairs benign line" \
    || fail "parse_lsblk_pairs benign line" "LP=${!LP[@]}"
parse_lsblk_pairs 'NAME="sda" MODEL="Evil\"; $(touch X); echo \"Y\"" SERIAL="E1" SIZE="1" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
[[ "${LP[MODEL]:-}" == 'Evil"; $(touch X); echo "Y"' ]] \
    && pass "hostile \$() payload parsed as data" \
    || fail "hostile \$() payload parsed as data" "got: ${LP[MODEL]:-}"
[[ -e "$EVIL_MARKER" ]] && fail "hostile payload never executed" || pass "hostile payload never executed"
parse_lsblk_pairs 'NAME="sda" MODEL="A\"B\\C" SERIAL="E2" SIZE="2" TRAN="sata" RM="0" ROTA="1" TYPE="disk"'
[[ "${LP[MODEL]:-}" == 'A"B\C' ]] \
    && pass "util-linux -P unescaping (\\\\ and \\\")" \
    || fail "util-linux -P unescaping" "got: ${LP[MODEL]:-}"

echo "== unit: human_size =="
[[ "$(human_size 1000204886016)" == "1 TB" ]] && pass "human_size(1TB)" || fail "human_size(1TB)"
[[ "$(human_size 16000000000)" == "16 GB" ]] && pass "human_size(16GB)" || fail "human_size(16GB)"

echo "== unit: enumerate + resolve_exact_dev =="
enumerate_disks
[[ "$D_COUNT" -eq 5 ]] && pass "enumerate_disks finds 5 disks" || fail "enumerate_disks finds 5 disks" "got $D_COUNT"
[[ "${D_DEV[0]}" == "/dev/sda" && "${D_DEV[2]}" == "/dev/nvme0n1" ]] \
    && pass "enumerate_disks order/paths" || fail "enumerate_disks order/paths" "${D_DEV[*]}"
[[ " ${D_FLAGS[1]} " == *" BOOT "* ]] && pass "sdb flagged BOOT" || fail "sdb flagged BOOT" "${D_FLAGS[1]}"
[[ " ${D_FLAGS[3]} " == *" MOUNTED "* && " ${D_FLAGS[3]} " != *" BOOT "* ]] \
    && pass "sdd flagged MOUNTED (not BOOT)" || fail "sdd flagged MOUNTED (not BOOT)" "${D_FLAGS[3]}"
[[ " ${D_FLAGS[0]} " == "  " ]] && pass "sda unflagged" || fail "sda unflagged" "${D_FLAGS[0]}"

r() { local idx; if idx="$(resolve_exact_dev "$1")"; then echo "OK:$idx"; else echo "REFUSE"; fi; }
[[ "$(r /dev/sda)" == "OK:0" ]] && pass "resolve exact /dev/sda" || fail "resolve exact /dev/sda"
[[ "$(r /dev/nvme0n1)" == "OK:2" ]] && pass "resolve exact /dev/nvme0n1" || fail "resolve exact /dev/nvme0n1"
[[ "$(r /dev/sd)" == "REFUSE" ]] && pass "refuse prefix /dev/sd" || fail "refuse prefix /dev/sd"
[[ "$(r 0)" == "REFUSE" ]] && pass "refuse row number 0" || fail "refuse row number 0"
[[ "$(r SATATEST001)" == "REFUSE" ]] && pass "refuse serial" || fail "refuse serial"
[[ "$(r '/dev/sda ')" == "REFUSE" ]] && pass "refuse trailing space" || fail "refuse trailing space"
[[ "$(r '/dev/*')" == "REFUSE" ]] && pass "refuse glob /dev/*" || fail "refuse glob /dev/*"
[[ "$(r '/dev/sd?')" == "REFUSE" ]] && pass "refuse glob /dev/sd?" || fail "refuse glob /dev/sd?"
[[ "$(r '')" == "REFUSE" ]] && pass "refuse empty input" || fail "refuse empty input"
[[ "$(r /dev/sda1)" == "REFUSE" ]] && pass "refuse non-disk /dev/sda1" || fail "refuse non-disk /dev/sda1"

echo "== unit: detect_boot_disks =="
blist="$(detect_boot_disks)"
grep -qxF "/dev/sdb" <<<"$blist" && pass "boot list contains /dev/sdb" || fail "boot list contains /dev/sdb" "$blist"
grep -qxF "/dev/sdd" <<<"$blist" && fail "boot list excludes mounted-data /dev/sdd" || pass "boot list excludes mounted-data /dev/sdd"
grep -qxF "/dev/sda" <<<"$blist" && fail "boot list excludes /dev/sda" || pass "boot list excludes /dev/sda"

echo "== unit: typed_confirm (piped stdin refused) =="
printf 'NUKE /dev/sda\n' | typed_confirm "P:" "NUKE /dev/sda" \
    && fail "typed_confirm refuses piped stdin" || pass "typed_confirm refuses piped stdin"

#--- pty helper: script(1) scrubs the environment, so the child wrapper --------
# re-exports the fixture env (mock lsblk PATH + fixture /proc paths) and
# execs the real guard script.
pty_run_capture() { # pty_run_capture <stdin lines> -- <logdir> [flags...]
    local -a lines=()
    while [[ "$1" != "--" ]]; do lines+=("$1"); shift; done
    shift
    local logdir="$1"; shift
    local child="$T/pty-cap-$RANDOM.sh" cap="$T/cap-$RANDOM.log"
    { printf '#!/usr/bin/env bash\n'
      printf 'export PATH=%q\n' "$MOCKBIN:$PATH"
      printf 'export PHOENIX_GUARD_PROC_MOUNTS=%q\n' "$FIXT_MOUNTS"
      printf 'export PHOENIX_GUARD_PROC_CMDLINE=%q\n' "$FIXT_CMDLINE"
      printf 'exec bash %q --log-dir %q "$@"\n' "$SH" "$logdir"
    } > "$child"
    chmod +x "$child"
    local rc=0
    printf '%s\n' "${lines[@]}" | script -qec "bash $child $*" /dev/null >"$cap" 2>&1 || rc=$?
    printf '%s|%s' "$rc" "$cap"
}
out="$(bash "$SH" --log-dir "$T/logs0")"; rc=$?
[[ $rc -eq 0 ]] && pass "dry-run default exit 0" || fail "dry-run default exit 0" "rc=$rc"
grep -q "Spare SATA HDD" <<<"$out" && pass "dry-run prints disk table" || fail "dry-run prints disk table"
grep -q "ARMED" <<<"$out" && fail "dry-run never arms" || pass "dry-run never arms"
out="$(bash "$SH" --whatif --log-dir "$T/logs0b")"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q "ARMED" <<<"$out" && pass "--whatif enumerate-only" \
    || fail "--whatif enumerate-only"
bash "$SH" --help >/dev/null 2>&1 && pass "--help exit 0" || fail "--help exit 0"
bash "$SH" --bogus >/dev/null 2>&1 && fail "unknown flag refused" || pass "unknown flag refused"

echo "== integration: --nuke piped stdin refused =="
rc=0
printf '/dev/sda\nNUKE /dev/sda\n' | bash "$SH" --nuke --log-dir "$T/logs1" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] && pass "--nuke piped stdin refused (exit 1)" || fail "--nuke piped stdin refused" "rc=$rc"

echo "== integration: --nuke on real pty =="

cap="$(pty_run_capture "/dev/sda" "NUKE /dev/sda" -- "$T/logs3" --nuke)"
rc="${cap%%|*}"; capfile="${cap#*|}"
[[ "$rc" -eq 0 ]] && grep -q "ARMED target=/dev/sda" "$capfile" \
    && pass "pty: ARMED target=/dev/sda printed" \
    || fail "pty: ARMED target=/dev/sda printed" "rc=$rc"
grep -q "mode=CONFIRMED target=/dev/sda" "$T/logs3/nuke-guard.log" \
    && pass "audit: CONFIRMED recorded" || fail "audit: CONFIRMED recorded"

cap="$(pty_run_capture "/dev/sd" -- "$T/logs4" --nuke)"
[[ "${cap%%|*}" -eq 1 ]] && ! grep -q "ARMED" "${cap#*|}" \
    && pass "pty: partial path /dev/sd refused (exit 1)" \
    || fail "pty: partial path /dev/sd refused"
cap="$(pty_run_capture "0" -- "$T/logs5" --nuke)"
[[ "${cap%%|*}" -eq 1 ]] && pass "pty: row number refused" || fail "pty: row number refused"
cap="$(pty_run_capture "/dev/sd?" -- "$T/logs6" --nuke)"
[[ "${cap%%|*}" -eq 1 ]] && pass "pty: wildcard refused" || fail "pty: wildcard refused"

echo "== integration: confirmation phrase must be exact =="
for bad in "nuke /dev/sda" "NUKE /dev/sda " " NUKE /dev/sda" "NUKE  /dev/sda" "NUKE /dev/sdb" "Y"; do
    cap="$(pty_run_capture "/dev/sda" "$bad" -- "$T/logs7-$RANDOM" --nuke)"
    if [[ "${cap%%|*}" -eq 2 ]]; then pass "pty: phrase '$bad' aborts (exit 2)"; \
    else fail "pty: phrase '$bad' aborts (exit 2)" "rc=${cap%%|*}"; fi
done
grep -q "mode=ABORTED" "$T"/logs7-*/nuke-guard.log \
    && pass "audit: ABORTED recorded" || fail "audit: ABORTED recorded"

echo "== integration: boot/mounted disks refused =="
cap="$(pty_run_capture "/dev/sdb" "NUKE /dev/sdb" -- "$T/logs8" --nuke)"
[[ "${cap%%|*}" -eq 1 ]] && grep -q "mode=REFUSED" "$T/logs8/nuke-guard.log" \
    && pass "pty: boot disk /dev/sdb refused (exit 1, audited)" \
    || fail "pty: boot disk /dev/sdb refused" "rc=${cap%%|*}"
cap="$(pty_run_capture "/dev/sdd" "NUKE /dev/sdd" -- "$T/logs9" --nuke)"
[[ "${cap%%|*}" -eq 1 ]] && pass "pty: mounted disk /dev/sdd refused" \
    || fail "pty: mounted disk /dev/sdd refused" "rc=${cap%%|*}"

echo "== integration: --override-boot-protection still requires typing =="
cap="$(pty_run_capture "/dev/sdb" "NUKE /dev/sdb" -- "$T/logs10" --nuke --override-boot-protection)"
[[ "${cap%%|*}" -eq 0 ]] && grep -q "ARMED target=/dev/sdb" "${cap#*|}" \
    && grep -q "WARNING" "$T/logs10/nuke-guard.log" \
    && pass "override arms with WARNING logged" \
    || fail "override arms with WARNING logged" "rc=${cap%%|*}"

echo "== integration: --exec hands off the validated path =="
FAKE_ARGS="$T/fake-nuke-args.txt"
cat > "$T/fake-nuke.sh" <<MOCK
#!/usr/bin/env bash
echo "FAKE-NUKE GOT: \$*" >> "$FAKE_ARGS"
MOCK
chmod +x "$T/fake-nuke.sh"
cap="$(pty_run_capture "/dev/sda" "NUKE /dev/sda" -- "$T/logs11" --nuke --exec "$T/fake-nuke.sh" "--nuke")"
[[ "${cap%%|*}" -eq 0 ]] && grep -qx "FAKE-NUKE GOT: --nuke /dev/sda" "$FAKE_ARGS" \
    && pass "--exec receives validated /dev/sda" \
    || fail "--exec receives validated /dev/sda" "rc=${cap%%|*}"

echo "== integration: evil fixture e2e =="
out="$(MOCK_EVIL=1 bash "$SH" --log-dir "$T/logs12")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'Evil' <<<"$out" && ! grep -q "ARMED" <<<"$out" \
    && pass "evil firmware displays as data, dry-run safe" \
    || fail "evil firmware displays as data, dry-run safe"
[[ -e "$EVIL_MARKER" ]] && fail "evil e2e: nothing executed" || pass "evil e2e: nothing executed"

echo
echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED CASES:"; printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1
fi
[[ -e "$EVIL_MARKER" ]] && { echo "FATAL: hostile payload executed"; exit 1; }
echo "All Phoenix NUKE guard regression tests green."
