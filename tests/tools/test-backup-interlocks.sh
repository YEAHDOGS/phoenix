#!/usr/bin/env bash
#===============================================================================
# test-backup-interlocks.sh -- regression harness for tools/Invoke-Backup.sh
#
# Tests the BACKUP safety interlocks. Backup is non-destructive (it only READS
# the source), but it is identity-critical: the Nuke phase's image-proof gate
# binds the proof to the source serial, so every identity gate is covered:
#   - --config required + stick policy (backup disabled / castle-smb refused /
#     unknown fields fail closed)
#   - serial resolution (wrong serial, row number, unknown id, dup serial)
#   - boot-USB structural refusal (as source and as target), mounted source
#   - air-gap gate (network up refuses; --allow-network needs a real TTY)
#   - --dry-run walks the flow and writes NOTHING
#   - armed run in PHOENIX_BACKUP_TEST=1 (file-backed fake source: zero
#     destructive potential) images, re-hashes, smoke-checks, and emits a
#     proof via the REAL tools/New-ImageProof.sh with verified=YES and the
#     source_serial bound -- the exact artifact Invoke-Nuke.sh --image-proof
#     demands
#
# Nothing here can destroy data: the armed path only ever reads a regular
# file and writes an image into a temp dir (test hook refuses in normal
# operation), and the mock-lsblk integration tests use fake /dev nodes that
# do not exist on the host.
#
# Coverage matrix mirrors tests/tools/test-nuke-interlocks.sh in style.
#
# Usage: bash tests/tools/test-backup-interlocks.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP="$REPO/tools/Invoke-Backup.sh"
FIX="$REPO/tests/config/fixtures"
T="$(mktemp -d /tmp/phoenix-backup-test.XXXXXX)"
MOCKBIN="$T/mockbin"
mkdir -p "$MOCKBIN"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

export PHOENIX_TOOLS_DIR="$REPO/tools"

#--- preflight -----------------------------------------------------------------
echo "== preflight =="
[[ -f "$BACKUP" ]] || { echo "FATAL: $BACKUP not found"; exit 1; }
bash -n "$BACKUP" && pass "bash -n syntax check" || fail "bash -n syntax check"
for cmd in lsblk dd sha256sum od findmnt df python3 gzip; do
    command -v "$cmd" >/dev/null 2>&1 \
        && pass "preflight: $cmd present" \
        || fail "preflight: $cmd present" "$cmd is required by the scripted path"
done

#--- fixtures ------------------------------------------------------------------
echo "== fixtures =="
# net dirs: $T/net-down (nothing up), $T/net-up (eth0 up)
mkdir -p "$T/net-down"/{lo,eth0,wlan0} "$T/net-up"/{lo,eth0,wlan0}
echo unknown > "$T/net-down/lo/operstate";  echo down > "$T/net-down/eth0/operstate"; echo down > "$T/net-down/wlan0/operstate"
echo unknown > "$T/net-up/lo/operstate";    echo up   > "$T/net-up/eth0/operstate";   echo down > "$T/net-up/wlan0/operstate"
# fake proc cmdline: we booted from /dev/sdb (the Phoenix USB)
printf 'BOOT_IMAGE=/dev/sdb1 root=/dev/sdb1 ro quiet\n' > "$T/cmdline"
# fake 8MB source disk with an MBR signature (file-backed, zero risk)
dd if=/dev/zero of="$T/fakedisk.img" bs=1M count=8 status=none
printf '\x55\xaa' | dd of="$T/fakedisk.img" bs=1 seek=510 conv=notrunc status=none
[[ -s "$T/fakedisk.img" ]] && pass "fake source disk created" || fail "fake source disk created"
mkdir -p "$T/mnt" "$T/logs" "$T/proofs"

#--- mock lsblk ----------------------------------------------------------------
# Fixture: sda = SATA HDD (serial WD-WMC4N0L12345), sdb = boot USB (mounted),
# sdd = mounted data SSD. MOCK_DUP=1 adds sde sharing sda's serial.
cat > "$MOCKBIN/lsblk" <<'MOCK'
#!/usr/bin/env bash
args="$*"
last="${@: -1}"
serial_of() {
    case "$1" in
        /dev/sda|/dev/sde) echo "WD-WMC4N0L12345" ;;
        /dev/sdb)          echo "PHOENIXSTICK9" ;;
        /dev/sdd)          echo "DATASSD0001" ;;
        *)                 echo "unknown" ;;
    esac
}
case "$args" in
  *"-ndo PKNAME"*)
    case "$last" in
      /dev/sdb1) echo sdb ;; /dev/sda1) echo sda ;;
      /dev/sdd1) echo sdd ;; /dev/sde1) echo sde ;;
      *) echo "" ;;
    esac ;;
  *"-dnr -o PATH"*)
    if [[ "${MOCK_DUP:-0}" == "1" ]]; then
        printf '%s\n' /dev/sda /dev/sdb /dev/sdd /dev/sde
    else
        printf '%s\n' /dev/sda /dev/sdb /dev/sdd
    fi ;;
  *"-nr -o MOUNTPOINTS"*)
    case "$last" in
      /dev/sdb) echo "/media/phoenix-usb" ;;
      /dev/sdd) echo "/mnt/data" ;;
    esac ;;
  *"-dnro TRAN"*)
    case "$last" in /dev/sdb) echo usb ;; *) echo sata ;; esac ;;
  *"-dnro RM"*)
    case "$last" in /dev/sdb) echo 1 ;; *) echo 0 ;; esac ;;
  *"-dnro SERIAL"*) serial_of "$last" ;;
  *"-P -b -d -o"*)
    printf 'NAME="sda" MODEL="WD Blue" SERIAL="WD-WMC4N0L12345" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"\n'
    printf 'NAME="sdb" MODEL="Phoenix USB" SERIAL="PHOENIXSTICK9" SIZE="64000000000" TRAN="usb" RM="1" ROTA="0" TYPE="disk"\n'
    printf 'NAME="sdd" MODEL="Data SSD" SERIAL="DATASSD0001" SIZE="500107862016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"\n'
    if [[ "${MOCK_DUP:-0}" == "1" ]]; then
        printf 'NAME="sde" MODEL="Clone Disk" SERIAL="WD-WMC4N0L12345" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"\n'
    fi ;;
esac
MOCK
chmod +x "$MOCKBIN/lsblk"
export PATH="$MOCKBIN:$PATH"

BASE_ENV="PHOENIX_PROC_CMDLINE=$T/cmdline PHOENIX_SYS_NET_DIR=$T/net-down"

#--- UNIT: sourced functions (main stripped) ------------------------------------
echo "== unit: sourced functions =="
export PHOENIX_SYS_NET_DIR="$T/net-down"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$BACKUP")

[[ "$(normalize_serial '  satatest001 ')" == "SATATEST001" ]] \
    && pass "normalize_serial uppercases+trims" \
    || fail "normalize_serial uppercases+trims"
[[ "$(sanitize_name 'QUARANTINE INFECTED/x')" == "QUARANTINE-INFECTED-x" ]] \
    && pass "sanitize_name strips unsafe chars" \
    || fail "sanitize_name strips unsafe chars"
comp_spec="$(pick_compressor)"
[[ "$comp_spec" == *"|"* && "$comp_spec" != "|"* || "$comp_spec" == "|raw" ]] \
    && pass "pick_compressor returns cmd|ext" \
    || fail "pick_compressor returns cmd|ext" "$comp_spec"

# network_up_list
export PHOENIX_SYS_NET_DIR="$T/net-down"; SYS_NET_DIR="$T/net-down"
[[ -z "$(network_up_list)" ]] && pass "network_up_list: all down -> empty" \
    || fail "network_up_list: all down -> empty"
SYS_NET_DIR="$T/net-up"
[[ "$(network_up_list)" == "eth0" ]] && pass "network_up_list: eth0 up detected, lo skipped" \
    || fail "network_up_list: eth0 up detected, lo skipped" "$(network_up_list)"

# check_air_gap
SYS_NET_DIR="$T/net-down"; ALLOW_NETWORK=0
check_air_gap && pass "check_air_gap: air-gapped passes" || fail "check_air_gap: air-gapped passes"
SYS_NET_DIR="$T/net-up"; ALLOW_NETWORK=0
check_air_gap 2>/dev/null && fail "check_air_gap: network up refuses" \
    || pass "check_air_gap: network up refuses"
ALLOW_NETWORK=1
echo | check_air_gap 2>/dev/null && fail "check_air_gap: piped --allow-network refused" \
    || pass "check_air_gap: piped --allow-network refused"

# enumerate + resolve_id against the mock
enumerate >/dev/null
[[ $D_COUNT -eq 3 ]] && pass "enumerate: 3 disks" || fail "enumerate: 3 disks" "got $D_COUNT"
[[ "$(resolve_id 1)" == "0" ]] && pass "resolve_id: row 1 -> idx 0" \
    || fail "resolve_id: row 1 -> idx 0"
[[ "$(resolve_id WD-WMC4N0L12345)" == "0" ]] && pass "resolve_id: serial hit" \
    || fail "resolve_id: serial hit"
resolve_id NOSUCHDISK >/dev/null 2>&1 && fail "resolve_id: unknown id refused" \
    || pass "resolve_id: unknown id refused"

# dup-serial fixture
export MOCK_DUP=1
enumerate >/dev/null
resolve_id WD-WMC4N0L12345 >/dev/null 2>&1 && fail "resolve_id: dup serial refused" \
    || pass "resolve_id: dup serial refused"
refuse_dup_serial "WD-WMC4N0L12345" "/dev/sda" 2>/dev/null \
    && fail "refuse_dup_serial: dup refused" \
    || pass "refuse_dup_serial: dup refused"
export MOCK_DUP=0
enumerate >/dev/null  # back to the 3-disk fixture for the structural tests below

# check_target structural gates (unit, mocked disks: idx 1 = boot USB sdb)
( check_target 1 "$T/mnt" ) 2>/dev/null && fail "check_target: boot USB as target refused" \
    || pass "check_target: boot USB as target refused"
( check_target 0 "$T/mnt" ) 2>/dev/null && fail "check_target: non-USB target refused" \
    || pass "check_target: non-USB target refused"
CONFIG="$FIX/valid-full.json"; load_usb_config
[[ "$CFG_BACKUP_ENABLED" == "1" && "$CFG_BACKUP_KIND" == "direct-usb" ]] \
    && pass "load_usb_config: backup policy loaded" \
    || fail "load_usb_config: backup policy loaded" "enabled=$CFG_BACKUP_ENABLED kind=$CFG_BACKUP_KIND"
( check_backup_policy ) 2>/dev/null && pass "check_backup_policy: direct-usb passes" \
    || fail "check_backup_policy: direct-usb passes"
CONFIG="$FIX/backup-disabled.json"; load_usb_config
( check_backup_policy ) 2>/dev/null && fail "check_backup_policy: backup=false refused" \
    || pass "check_backup_policy: backup=false refused"
CONFIG="$FIX/backup-castle-smb.json"; load_usb_config
( check_backup_policy ) 2>/dev/null && fail "check_backup_policy: castle-smb refused on boot path" \
    || pass "check_backup_policy: castle-smb refused on boot path"
CONFIG="$FIX/backup-unknown-field.json"
( load_usb_config ) 2>/dev/null && fail "load_usb_config: unknown field fails closed" \
    || pass "load_usb_config: unknown field fails closed"
CONFIG="$T/nope.json"
( load_usb_config ) 2>/dev/null && fail "load_usb_config: missing file fails closed" \
    || pass "load_usb_config: missing file fails closed"

#--- INTEGRATION: subprocess ----------------------------------------------------
echo "== integration: subprocess =="
run() { env $BASE_ENV "$@"; }  # BASE_ENV: net-down, fake cmdline, mock lsblk first in PATH

# 1. enumerate-only
out="$(run "$BACKUP" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 0 && "$out" == *"PHOENIX BACKUP"* ]] && pass "no flags: enumerate and exit 0" \
    || fail "no flags: enumerate and exit 0" "rc=$rc"

# 2. missing --config
out="$(run "$BACKUP" --source WD-WMC4N0L12345 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"REFUSED: --config"* ]] && pass "missing --config refused" \
    || fail "missing --config refused" "rc=$rc"

# 3. wrong source serial
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --source NOSUCHDISK --target DATASSD0001 --target-mount "$T/mnt" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"No disk matches"* ]] && pass "wrong source serial refused" \
    || fail "wrong source serial refused" "rc=$rc"

# 4. source == boot USB
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --source PHOENIXSTICK9 --target DATASSD0001 --target-mount "$T/mnt" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"boot USB"* ]] && pass "boot USB as source refused" \
    || fail "boot USB as source refused" "rc=$rc"

# 5. source mounted
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --source DATASSD0001 --target WD-WMC4N0L12345 --target-mount "$T/mnt" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"mounted partitions"* ]] && pass "mounted source refused" \
    || fail "mounted source refused" "rc=$rc"

# 6. fake /dev nodes are refused by the block-device gate (the mock lsblk
#    fixture names disks that do not exist on this host -- the script must
#    never proceed past a non-block-device; the boot-USB-as-target gate
#    itself is covered at unit level above)
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --source WD-WMC4N0L12345 --target DATASSD0001 --target-mount "$T/mnt" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"not a block device"* ]] && pass "non-block-device source refused" \
    || fail "non-block-device source refused" "rc=$rc"

# 7. air-gap gate: network up, no --allow-network
out="$(env PHOENIX_PROC_CMDLINE=$T/cmdline PHOENIX_SYS_NET_DIR=$T/net-up "$BACKUP" --config "$FIX/valid-full.json" --source WD-WMC4N0L12345 --target DATASSD0001 --target-mount "$T/mnt" 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"AIR-GAPPED"* ]] && pass "network-up refuses without --allow-network" \
    || fail "network-up refuses without --allow-network" "rc=$rc"

# 8. --test-serial without the env var
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --source "$T/fakedisk.img" --target X --target-mount "$T/mnt" --test-serial ABC123 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 && "$out" == *"PHOENIX_BACKUP_TEST"* ]] && pass "--test-serial without env refused" \
    || fail "--test-serial without env refused" "rc=$rc"

# 9. --tool rescuezilla prints the checklist, writes nothing
before="$(find "$T/mnt" "$T/logs" "$T/proofs" -type f | wc -l)"
out="$(run "$BACKUP" --config "$FIX/valid-full.json" --tool rescuezilla 2>&1)" && rc=0 || rc=$?
after="$(find "$T/mnt" "$T/logs" "$T/proofs" -type f | wc -l)"
[[ $rc -eq 0 && "$out" == *"Rescuezilla"* && "$before" == "$after" ]] \
    && pass "--tool rescuezilla: checklist, nothing written" \
    || fail "--tool rescuezilla: checklist, nothing written" "rc=$rc before=$before after=$after"

# 10. --dry-run in test mode: walks the flow, writes NOTHING
before="$(find "$T/mnt" "$T/logs" "$T/proofs" -type f | wc -l)"
out="$(env $BASE_ENV PHOENIX_BACKUP_TEST=1 "$BACKUP" --config "$FIX/valid-full.json" --source "$T/fakedisk.img" --test-serial DRYRUN01 --target TARGETUSB1 --target-mount "$T/mnt" --log-dir "$T/logs" --proof-out "$T/proofs" --dry-run 2>&1)" && rc=0 || rc=$?
after="$(find "$T/mnt" "$T/logs" "$T/proofs" -type f | wc -l)"
[[ $rc -eq 0 && "$out" == *"DRY RUN"* && "$out" == *"DRYRUN01"* && "$before" == "$after" ]] \
    && pass "--dry-run: full walk, zero writes" \
    || fail "--dry-run: full walk, zero writes" "rc=$rc before=$before after=$after"

# 11. armed run in test mode: image + verify + proof, proof binds serial
out="$(env $BASE_ENV PHOENIX_BACKUP_TEST=1 "$BACKUP" --config "$FIX/valid-full.json" --source "$T/fakedisk.img" --test-serial IMGBIND42 --target TARGETUSB1 --target-mount "$T/mnt" --log-dir "$T/logs" --proof-out "$T/proofs" --image-name testimage 2>&1)" && rc=0 || rc=$?
img="$(find "$T/mnt" -name 'img-testimage.*' | head -n1)"
proof="$(find "$T/proofs" -name '*.proof' | head -n1)"
[[ $rc -eq 0 ]] || fail "armed test run: exit 0" "rc=$rc :: $out"
[[ -n "$img" && -s "$img" ]] && pass "armed test run: image written" \
    || fail "armed test run: image written" "img=$img"
if [[ -n "$proof" && -f "$proof" ]]; then
    p_format="$(grep -E '^format=' "$proof" | cut -d= -f2)"
    p_verified="$(grep -E '^verified=' "$proof" | cut -d= -f2)"
    p_serial="$(grep -E '^source_serial=' "$proof" | cut -d= -f2)"
    p_sha="$(grep -E '^sha256=' "$proof" | cut -d= -f2)"
    p_size="$(grep -E '^image_size_bytes=' "$proof" | cut -d= -f2)"
    real_sha="$(sha256sum "$img" | awk '{print $1}')"
    [[ "$p_format" == "phoenix-image-proof/1" ]] && pass "proof: format phoenix-image-proof/1" \
        || fail "proof: format phoenix-image-proof/1" "$p_format"
    [[ "$p_verified" == "YES" ]] && pass "proof: verified=YES" || fail "proof: verified=YES" "$p_verified"
    [[ "$p_serial" == "IMGBIND42" ]] && pass "proof: source_serial bound to imaged disk" \
        || fail "proof: source_serial bound to imaged disk" "$p_serial"
    [[ "$p_sha" =~ ^[0-9a-f]{64}$ && "$p_sha" == "$real_sha" ]] \
        && pass "proof: sha256 is real (matches image file)" \
        || fail "proof: sha256 is real (matches image file)" "$p_sha vs $real_sha"
    [[ "$p_size" =~ ^[0-9]+$ && "$p_size" -gt 0 ]] && pass "proof: positive image_size_bytes" \
        || fail "proof: positive image_size_bytes" "$p_size"
    [[ "$out" == *"Smoke check PASSED"* ]] && pass "armed test run: smoke check passed" \
        || fail "armed test run: smoke check passed"
    [[ "$out" == *"BACKUP COMPLETE"* ]] && pass "armed test run: BACKUP COMPLETE" \
        || fail "armed test run: BACKUP COMPLETE"
else
    fail "armed test run: proof emitted" "proof=$proof"
fi

#--- summary --------------------------------------------------------------------
echo "== summary =="
echo "PASS: $PASS  FAIL: $FAIL"
if (( FAIL > 0 )); then
    echo "Failed cases:"
    printf '  - %s\n' "${FAILED_CASES[@]}"
    exit 1
fi
echo "All backup interlock regression tests green."
