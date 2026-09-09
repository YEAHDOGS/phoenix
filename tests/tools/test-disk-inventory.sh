#!/usr/bin/env bash
#===============================================================================
# test-disk-inventory.sh -- regression harness for
#   tools/lib/phoenix-disk-inventory.sh   (bash -- executed for real)
#   tools/Get-PhoenixDiskInventory.ps1    (WinPE twin; pwsh is not installed
#                                          here, so the .ps1 is checked for
#                                          structural + formula parity only --
#                                          the same convention as the other
#                                          suites)
#
# Tests the NUKE enumeration exclusions and the typed-confirmation gate
# WITHOUT any destructive path, on this machine, with fully mocked data
# sources (PHOENIX_PDI_* test hooks). Nothing here can destroy data:
#   - the library contains NO destructive primitive (a preflight grep fails
#     the suite if nwipe/hdparm/nvme/dd/mkfs/shred/blkdiscard ever appear),
#   - fixture disks are fake /dev/sd* paths that do not exist on the host,
#   - real lsblk//proc/config are never consulted (all hooks are set).
#
# Coverage:
#   STATIC: bash -n; library refuses direct execution; no destructive
#     primitives; twin .ps1 carries the identical arm-code derivation
#     formula (sha256("phoenix-nuke-arm|serial|model|size"), 6 hex, upper).
#   ENUMERATION (mocked lsblk/proc/config fixtures):
#     boot USB excluded (cmdline BOOT_IMAGE=), config-protected disks
#     excluded (by serial AND by /dev path), mounted disks excluded,
#     loop/ram devices never enumerated, serial-less disks listed with
#     NO-SERIAL flag (but can never be armed), hidden-summary names each
#     excluded disk with its reason, missing config => no protected
#     exclusions, hostile firmware MODEL strings are data (no execution).
#   ARM CODES: deterministic, 6 uppercase hex, unique per disk, recomputed
#     independently via sha256sum; python3 cross-check of the derivation
#     formula (the same string the .ps1 twin must hash).
#   CONFIRMATION GATE: piped stdin (correct code, correct serial, "yes",
#     "NUKE <code>") is refused structurally; on a real pty the wrong code,
#     "yes", and empty input are refused while the correct ARM-CODE and the
#     exact serial are accepted; serial "(unknown)" can never be armed.
#   DRY-RUN: pdi_run exits 0, prints the candidate table and hidden summary.
#
# Deliberately NOT covered here (needs the boot environment / WinPE):
#   real lsblk//proc enumeration on hardware, and executing the .ps1 twin.
#   Destructive paths are VM-only (docs/NUKE-TEST-PLAN.md) and never run here.
#
# Usage: bash tests/tools/test-disk-inventory.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/tools/lib/phoenix-disk-inventory.sh"
PS1F="$REPO/tools/Get-PhoenixDiskInventory.ps1"
T="$(mktemp -d /tmp/phoenix-pdi-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- preflight: static ----------------------------------------------------------
echo "== static =="
[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 1; }
[[ -f "$PS1F" ]] || { echo "FATAL: $PS1F not found"; exit 1; }
bash -n "$LIB" && pass "bash -n: library parses" || fail "bash -n: library parses"

# library refuses direct execution (it must be sourced)
rc=0
out="$(bash "$LIB" 2>&1)" || rc=$?
(( rc != 0 )) && [[ "$out" == *"source it"* ]] \
    && pass "library refuses direct execution" \
    || fail "library refuses direct execution" "rc=$rc out='$out'"

# the library must never gain a destructive primitive
if grep -nE 'nwipe|hdparm|nvme |nvme-cli|\bdd\b|mkfs|shred|blkdiscard|sg_format|cryptsetup' "$LIB" >/dev/null; then
    fail "library contains no destructive primitives" "forbidden token found"
else
    pass "library contains no destructive primitives"
fi

# twin parity: identical arm-code derivation formula in the .ps1
grep -qF 'phoenix-nuke-arm|' "$PS1F" \
    && pass ".ps1 arm-code derivation prefix matches" \
    || fail ".ps1 arm-code derivation prefix matches"
grep -qF 'Substring(0, 6).ToUpper()' "$PS1F" \
    && pass ".ps1 arm-code truncation+uppercase matches" \
    || fail ".ps1 arm-code truncation+uppercase matches"
grep -qF 'phoenix-nuke-arm|%s|%s|%s' "$LIB" \
    && pass "bash arm-code derivation formula present" \
    || fail "bash arm-code derivation formula present"
grep -q "IsInputRedirected" "$PS1F" \
    && pass ".ps1 refuses redirected-stdin confirmation" \
    || fail ".ps1 refuses redirected-stdin confirmation"

#--- fixtures -------------------------------------------------------------------
echo "== fixtures =="
cat > "$T/lsblk.txt" <<'EOF'
NAME="sda" MODEL="Samsung SSD 870" SERIAL="SATA001" SIZE="1000204886016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"
NAME="sdb" MODEL="SanDisk Ultra" SERIAL="USB002" SIZE="32000000000" TRAN="usb" RM="1" ROTA="1" TYPE="disk"
NAME="sdc" MODEL="Kingston NV1" SERIAL="NVME003" SIZE="500107862016" TRAN="nvme" RM="0" ROTA="0" TYPE="disk"
NAME="sdd" MODEL="WD Blue" SERIAL="WD004" SIZE="2000398934016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"
NAME="sde" MODEL="Seagate Data" SERIAL="DATA005" SIZE="4000787030016" TRAN="sata" RM="0" ROTA="1" TYPE="disk"
NAME="sdf" MODEL="Crucial MX500" SERIAL="" SIZE="500107862016" TRAN="sata" RM="0" ROTA="0" TYPE="disk"
NAME="sdg" MODEL="Evil\"; $(touch /tmp/pdi-pwned-marker) #" SERIAL="EVIL006" SIZE="1000000" TRAN="sata" RM="0" ROTA="1" TYPE="disk"
NAME="loop0" MODEL="" SERIAL="" SIZE="100000000" TRAN="" RM="0" ROTA="1" TYPE="loop"
EOF
cat > "$T/mounted.txt" <<'EOF'
/dev/sde1 /data
/dev/sde2 /backup
EOF
printf 'BOOT_IMAGE=/dev/sdb1 quiet\n' > "$T/cmdline.txt"
: > "$T/mounts.txt"
cat > "$T/config.json" <<'EOF'
{
  "schemaVersion": 1,
  "nuke": {
    "protectedDisks": [ "NVME003", "/dev/sdd" ]
  }
}
EOF

export PHOENIX_PDI_LSBLK_FILE="$T/lsblk.txt"
export PHOENIX_PDI_MOUNTED_FILE="$T/mounted.txt"
export PHOENIX_PDI_PROC_CMDLINE="$T/cmdline.txt"
export PHOENIX_PDI_PROC_MOUNTS="$T/mounts.txt"
export PHOENIX_PDI_CONFIG="$T/config.json"

# source the real library with all data sources mocked
# shellcheck disable=SC1090
source "$LIB"

#--- enumeration exclusions -----------------------------------------------------
echo "== enumeration exclusions =="
pdi_enumerate

(( PDI_COUNT == 3 )) && pass "3 candidates (sda, sdf, sdg)" \
    || fail "3 candidates (sda, sdf, sdg)" "got $PDI_COUNT"

has_dev() { # has_dev <dev> -> 0/1 in PDI_DEV
    local d; for d in "${PDI_DEV[@]}"; do [[ "$d" == "$1" ]] && return 0; done; return 1; }
has_dev /dev/sda && pass "candidate: /dev/sda" || fail "candidate: /dev/sda"
has_dev /dev/sdf && pass "candidate: /dev/sdf (no serial)" || fail "candidate: /dev/sdf (no serial)"
has_dev /dev/sdg && pass "candidate: /dev/sdg (hostile model)" || fail "candidate: /dev/sdg (hostile model)"
has_dev /dev/sdb && fail "excluded: boot USB /dev/sdb not a candidate" \
    || pass "excluded: boot USB /dev/sdb not a candidate"
has_dev /dev/sdc && fail "excluded: protected-by-serial /dev/sdc not a candidate" \
    || pass "excluded: protected-by-serial /dev/sdc not a candidate"
has_dev /dev/sdd && fail "excluded: protected-by-dev /dev/sdd not a candidate" \
    || pass "excluded: protected-by-dev /dev/sdd not a candidate"
has_dev /dev/sde && fail "excluded: mounted /dev/sde not a candidate" \
    || pass "excluded: mounted /dev/sde not a candidate"
has_dev /dev/loop0 && fail "excluded: loop device never enumerated" \
    || pass "excluded: loop device never enumerated"

(( PDI_HIDDEN_COUNT == 4 )) && pass "4 hidden disks" \
    || fail "4 hidden disks" "got $PDI_HIDDEN_COUNT"
hidden_why() { # hidden_why <dev> -> reason or empty
    local i; for ((i=0;i<PDI_HIDDEN_COUNT;i++)); do
        [[ "${PDI_HIDDEN_DEV[$i]}" == "$1" ]] && { printf '%s' "${PDI_HIDDEN_WHY[$i]}"; return 0; }; done
    return 1; }
[[ "$(hidden_why /dev/sdb)" == "BOOT-USB" ]] && pass "hidden reason: sdb=BOOT-USB" \
    || fail "hidden reason: sdb=BOOT-USB" "got '$(hidden_why /dev/sdb)'"
[[ "$(hidden_why /dev/sdc)" == "PROTECTED(config)" ]] && pass "hidden reason: sdc=PROTECTED(config)" \
    || fail "hidden reason: sdc=PROTECTED(config)" "got '$(hidden_why /dev/sdc)'"
[[ "$(hidden_why /dev/sdd)" == "PROTECTED(config)" ]] && pass "hidden reason: sdd=PROTECTED(config)" \
    || fail "hidden reason: sdd=PROTECTED(config)" "got '$(hidden_why /dev/sdd)'"
[[ "$(hidden_why /dev/sde)" == "MOUNTED" ]] && pass "hidden reason: sde=MOUNTED" \
    || fail "hidden reason: sde=MOUNTED" "got '$(hidden_why /dev/sde)'"

# serial-less disk is listed but flagged NO-SERIAL
no_serial_flag=0
for ((i=0;i<PDI_COUNT;i++)); do
    if [[ "${PDI_DEV[$i]}" == "/dev/sdf" && "${PDI_FLAGS[$i]}" == *"NO-SERIAL"* ]]; then
        no_serial_flag=1
    fi
done
(( no_serial_flag == 1 )) && pass "serial-less disk flagged NO-SERIAL" \
    || fail "serial-less disk flagged NO-SERIAL"

# hostile firmware MODEL is data, never executed
[[ -f /tmp/pdi-pwned-marker ]] && fail "hostile MODEL not executed" \
    || pass "hostile MODEL not executed"
evil_model=0
for ((i=0;i<PDI_COUNT;i++)); do
    if [[ "${PDI_DEV[$i]}" == "/dev/sdg" ]]; then
        [[ "${PDI_MODEL[$i]}" == *'$(touch'* ]] && evil_model=1
    fi
done
(( evil_model == 1 )) && pass "hostile MODEL preserved as data" \
    || fail "hostile MODEL preserved as data"

# missing config => no protected exclusions (sdc/sdd become candidates)
export PHOENIX_PDI_CONFIG="$T/does-not-exist.json"
pdi_enumerate
has_dev /dev/sdc && pass "missing config: sdc becomes candidate" \
    || fail "missing config: sdc becomes candidate"
export PHOENIX_PDI_CONFIG="$T/config.json"
pdi_enumerate

# config without the nuke key => no exclusions either
printf '{ "schemaVersion": 1 }\n' > "$T/nokey.json"
export PHOENIX_PDI_CONFIG="$T/nokey.json"
pdi_enumerate
has_dev /dev/sdc && pass "config w/o nuke key: sdc becomes candidate" \
    || fail "config w/o nuke key: sdc becomes candidate"
export PHOENIX_PDI_CONFIG="$T/config.json"
pdi_enumerate

#--- arm codes ------------------------------------------------------------------
echo "== arm codes =="
code_sda1="$(pdi_arm_code "SATA001" "Samsung SSD 870" "1000204886016")"
code_sda2="$(pdi_arm_code "SATA001" "Samsung SSD 870" "1000204886016")"
[[ "$code_sda1" == "$code_sda2" ]] && pass "arm code deterministic" \
    || fail "arm code deterministic" "'$code_sda1' vs '$code_sda2'"
[[ "$code_sda1" =~ ^[0-9A-F]{6}$ ]] && pass "arm code is 6 uppercase hex" \
    || fail "arm code is 6 uppercase hex" "got '$code_sda1'"
code_other="$(pdi_arm_code "NVME003" "Kingston NV1" "500107862016")"
[[ "$code_sda1" != "$code_other" ]] && pass "arm code unique per disk" \
    || fail "arm code unique per disk"

# table's code for sda matches the independently recomputed one
table_code=""
for ((i=0;i<PDI_COUNT;i++)); do
    [[ "${PDI_DEV[$i]}" == "/dev/sda" ]] && table_code="${PDI_CODE[$i]}"
done
[[ "$table_code" == "$code_sda1" ]] && pass "table ARM-CODE matches derivation" \
    || fail "table ARM-CODE matches derivation" "table='$table_code' fn='$code_sda1'"

# independent cross-check of the derivation formula (what the .ps1 must hash)
expected="$(printf 'phoenix-nuke-arm|%s|%s|%s' "SATA001" "Samsung SSD 870" "1000204886016" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:6].upper())')"
[[ "$code_sda1" == "$expected" ]] && pass "derivation formula cross-checked via python3" \
    || fail "derivation formula cross-checked via python3" "bash='$code_sda1' py='$expected'"

#--- confirmation gate: piped stdin can never arm --------------------------------
echo "== confirmation: piped input refused =="
refused_pipe() { # refused_pipe <label> <input>
    if printf '%s\n' "$2" | pdi_confirm_armed "SATA001" "$code_sda1" >/dev/null 2>&1; then
        fail "piped input refused: $1"
    else
        pass "piped input refused: $1"
    fi
}
refused_pipe "correct ARM-CODE" "$code_sda1"
refused_pipe "exact serial" "SATA001"
refused_pipe "yes" "yes"
refused_pipe "NUKE <code>" "NUKE $code_sda1"
refused_pipe "empty" ""

#--- confirmation gate: real pty -------------------------------------------------
echo "== confirmation: pty matrix =="
# util-linux `script` scrubs the environment, so inject function bodies via
# declare -f into a temp child script (same technique as the other suites).
pty_confirm() { # pty_confirm <typed> <serial> <code> -> rc of pdi_confirm_armed on a real pty
    local child="$T/pty-child.sh"
    { declare -f pdi_confirm_armed; declare -f pdi_ts
      printf 'pdi_confirm_armed %q %q\n' "$2" "$3"; } > "$child"
    printf '%s\n' "$1" | script -qec "bash $child" /dev/null >/dev/null 2>&1
}
pty_case() { # pty_case <label> <typed> <serial> <code> <expect-0|expect-fail>
    local rc
    pty_confirm "$2" "$3" "$4" && rc=0 || rc=$?
    if [[ "$5" == "expect-0" ]]; then
        (( rc == 0 )) && pass "pty: $1" || fail "pty: $1" "rc=$rc, expected 0"
    else
        (( rc != 0 )) && pass "pty: $1" || fail "pty: $1" "rc=$rc, expected nonzero"
    fi
}
pty_case "correct ARM-CODE accepted" "$code_sda1" "SATA001" "$code_sda1" expect-0
pty_case "exact serial accepted" "SATA001" "SATA001" "$code_sda1" expect-0
pty_case "wrong code refused" "000000" "SATA001" "$code_sda1" expect-fail
pty_case "'yes' refused" "yes" "SATA001" "$code_sda1" expect-fail
pty_case "empty refused" "" "SATA001" "$code_sda1" expect-fail
pty_case "trailing space refused" "$code_sda1 " "SATA001" "$code_sda1" expect-fail
pty_case "lowercase code refused (case-sensitive)" "$(echo "$code_sda1" | tr 'A-F' 'a-f')" \
    "SATA001" "$code_sda1" expect-fail
pty_case "unknown serial never arms" "$code_sda1" "(unknown)" "$code_sda1" expect-fail

#--- dry-run --------------------------------------------------------------------
echo "== dry-run =="
out="$(pdi_run 2>&1)"; rc=$?
(( rc == 0 )) && pass "pdi_run exits 0" || fail "pdi_run exits 0" "rc=$rc"
[[ "$out" == *"ARM-CODE"* ]] && pass "pdi_run prints candidate table" \
    || fail "pdi_run prints candidate table"
[[ "$out" == *"hidden: /dev/sdb (BOOT-USB)"* ]] && pass "pdi_run hidden summary names boot USB" \
    || fail "pdi_run hidden summary names boot USB"
[[ "$out" == *"hidden: /dev/sdc (PROTECTED(config))"* ]] && pass "pdi_run hidden summary names protected disk" \
    || fail "pdi_run hidden summary names protected disk"
if grep -E "^0 |^1 |^2 " <<<"$out" | grep -q "/dev/sdb\|/dev/sdc\|/dev/sdd\|/dev/sde"; then
    fail "pdi_run never lists excluded disks as candidates"
else
    pass "pdi_run never lists excluded disks as candidates"
fi

#--- summary ----------------------------------------------------------------------
echo "== summary =="
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    echo "FAILED CASES:"
    printf '  - %s\n' "${FAILED_CASES[@]}"
    exit 1
fi
echo "ALL GREEN"
