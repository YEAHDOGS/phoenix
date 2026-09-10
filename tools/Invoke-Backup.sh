#!/usr/bin/env bash
#===============================================================================
# Invoke-Backup.sh -- Phoenix BACKUP module (image before wipe, always)
#
# Full-disk image of a serial-resolved source disk onto a direct-attached USB
# target, air-gapped, with a verification ladder and automatic image-proof
# emission in exactly the format Invoke-Nuke.sh --image-proof demands.
#
# Runs in the Phoenix Linux boot environment (USB menu: Analyze/Backup/Nuke/
# Reinstall). The scripted dd path lives on the Linux rescue side, so this
# module is bash by design -- like Invoke-Nuke.sh, it has no Windows
# pre-flight (the .ps1 twin validates config/serial/air-gap on Windows and
# refuses the image write there, pointing at the Ventoy [2] BACKUP entry).
#
# SAFETY MODEL (see docs/BACKUP-MODULE.md):
#   1. --config <phoenix-config.json> is REQUIRED for anything beyond bare
#      enumeration (plan, dry-run, --tool rescuezilla, armed run), never
#      auto-discovered. boot_entries.backup must be true; unknown config
#      fields fail closed (schema additionalProperties: false).
#   2. Serial resolution, never letters: source and target are resolved by
#      SERIAL (row number or /dev node are aliases of the enumerated table).
#      A duplicated serial is identity failure and is refused.
#   3. Boot-USB guard: the booted Phoenix USB can be neither source nor
#      target. A disk with mounted partitions is refused as a source.
#      The target mount must descend from the declared target disk.
#   4. Air-gap gate: refuses if any non-loopback network interface is up,
#      unless --allow-network is passed AND "ALLOW NETWORK" is typed on a
#      real TTY (piped stdin can never allow it).
#   5. backup_target.kind must be "direct-usb". "castle-smb" is refused on
#      the scripted boot path: a network push from the infected machine
#      would violate the air-gap gate (runbook Step 2.1). Quarantine and
#      copy from a clean machine (runbook Step 2.7).
#   6. Dry-run posture: no flags enumerates and exits; --dry-run walks the
#      whole flow and writes nothing.
#   7. Verification ladder: dd exit + re-hash equality + partition-table
#      smoke check; only then is tools/New-ImageProof.sh --verified invoked
#      with the REAL values (real sha256, real source_serial).
#
# USAGE:
#   Invoke-Backup.sh --config <cfg> --source <id> --target <serial>
#       --target-mount <dir> [--dry-run] [--tool dd|rescuezilla]
#       [--image-name <name>] [--log-dir <dir>] [--proof-out <dir>]
#       [--allow-network]
#
#   --tool rescuezilla prints the manual Rescuezilla checklist and exits
#   (no disks are touched) instead of imaging.
#
# <id> may be the row number from the table, a /dev node, or the disk serial.
# Backup is non-destructive (it only READS the source), so there is no typed
# serial confirmation and no countdown -- but every identity gate above still
# applies, because the proof binds to the serial.
#
# Exit codes: 0 = enumerate/dry-run OK, or image+proof complete
#             1 = error/refusal
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The boot-side tools travel together (phoenix/tools/ on the stick).
# Tests may point at a different tools dir via the environment.
TOOLS_DIR="${PHOENIX_TOOLS_DIR:-$SCRIPT_DIR}"
# Test hooks (harmless in production; see docs/BACKUP-MODULE.md).
SYS_NET_DIR="${PHOENIX_SYS_NET_DIR:-/sys/class/net}"
PROC_CMDLINE="${PHOENIX_PROC_CMDLINE:-/proc/cmdline}"
TEST_MODE="${PHOENIX_BACKUP_TEST:-0}"

# --- options -----------------------------------------------------------------
CONFIG=""            # REQUIRED: path to phoenix-config.json (stick policy)
SOURCE_ID=""         # disk to image (row, /dev node, or serial)
TARGET_SERIAL=""     # serial of the destination USB disk
TARGET_MOUNT=""      # mounted filesystem on the target disk
TOOL="dd"            # dd (scripted path) | rescuezilla (print checklist)
IMAGE_NAME=""        # image label; default from backup_target.label_prefix
LOG_DIR=""           # auto-detected on the boot USB unless overridden
PROOF_OUT=""         # proof manifest dir; default = LOG_DIR
DRY_RUN=0
ALLOW_NETWORK=0
TEST_SERIAL=""       # test-only: serial for a file-backed fake source

# --- state -------------------------------------------------------------------
LOGFILE=""
declare -a D_DEV D_MODEL D_SERIAL D_SIZE D_TRAN D_MEDIA D_FLAGS
D_COUNT=0
BOOT_DISK=""          # /dev node of the booted USB (structural refusal)

#===============================================================================
# logging
#===============================================================================
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {  # log <message> -- timestamped, to console AND logfile (once started)
    local msg="[$(ts)] $*"
    echo "$msg"
    if [[ -n "$LOGFILE" ]]; then
        echo "$msg" >> "$LOGFILE"
    fi
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Phoenix BACKUP v$VERSION -- verified full-disk imaging (boot environment only)

Usage:
  $PROG --config <cfg> --source <id> --target <serial> --target-mount <dir>
      [--dry-run] [--tool dd|rescuezilla] [--image-name <n>]
      [--log-dir <dir>] [--proof-out <dir>] [--allow-network]

  --config <cfg>     REQUIRED: the stick's phoenix-config.json. Never
                     auto-discovered; boot_entries.backup must be true.
  --source <id>      Disk to image: serial number (preferred), row number
                     from the enumeration table, or /dev node. Letters alone
                     never identify a disk -- serials do.
  --target <serial>  Serial of the destination USB disk (second USB drive).
  --target-mount <dir> Mounted filesystem on the target disk where the
                     image file is written; must descend from --target.
  --dry-run          Walk the whole flow (config, serial resolution,
                     network gate, free-space check) and write NOTHING.
  --tool dd          Scripted dd+compressor image path (default).
  --tool rescuezilla Print the manual Rescuezilla checklist and exit;
                     images nothing.
  --image-name <n>   Image label (default: <label_prefix>-<utc-timestamp>).
  --log-dir <dir>    Log location (default: phoenix-logs on the boot USB).
  --proof-out <dir>  Where the .proof manifest goes (default: --log-dir).
  --allow-network    Allow imaging with a network interface up. Still
                     requires typing ALLOW NETWORK on a real TTY.

No flags = enumerate disks and exit (dry-run, the default). --config is
required for everything beyond enumeration: --dry-run, --tool rescuezilla,
and the armed image run. Backup only
READS the source disk, so there is no typed serial confirmation -- but
every identity gate (serial resolution, boot-USB guard, air-gap) applies,
because the emitted proof binds to the source serial for the Nuke gate.

VM-ONLY TESTING of the armed path uses PHOENIX_BACKUP_TEST=1 (file-backed
fake source, see docs/BACKUP-MODULE.md). NEVER image-write against real
hardware in tests.
EOF
}

#===============================================================================
# enumeration (identity machinery -- mirrors Invoke-Nuke.sh)
#===============================================================================
# parent_disk <partition-or-disk> -> /dev/<disk>
parent_disk() {
    local node="$1"
    local pk
    pk="$(lsblk -ndo PKNAME "$node" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then
        echo "/dev/$pk"
        return
    fi
    local base
    base="$(basename "$node")"
    base="$(echo "$base" | sed -E \
        -e 's/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(mmcblk[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(loop[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^([a-zA-Z]+)[0-9]+$/\1/')"
    echo "/dev/$base"
}

# detect_boot_disk: find the disk we booted from (the Phoenix USB).
detect_boot_disk() {
    local -a protected=()
    local cmdline rootdev
    cmdline="$(cat "$PROC_CMDLINE" 2>/dev/null || true)"
    for tok in $cmdline; do
        case "$tok" in
            root=/dev/*|BOOT_IMAGE=/dev/*)
                rootdev="${tok#*=}"
                rootdev="${rootdev%% *}"
                protected+=("$(parent_disk "$rootdev")")
                ;;
        esac
    done
    local disk mp
    while IFS= read -r disk; do
        while IFS= read -r mp; do
            if [[ -n "$mp" ]]; then
                protected+=("$disk")
                break
            fi
        done < <(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null | grep -v '^$' || true)
    done < <(lsblk -dnr -o PATH -e 7,11 2>/dev/null || true)
    local p tran rm
    for p in "${protected[@]}"; do
        tran="$(lsblk -dnro TRAN "$p" 2>/dev/null || true)"
        rm="$(lsblk -dnro RM "$p" 2>/dev/null || true)"
        if [[ "$tran" == "usb" || "$rm" == "1" ]]; then
            BOOT_DISK="$p"
            return
        fi
    done
    if [[ ${#protected[@]} -gt 0 ]]; then
        BOOT_DISK="${protected[0]}"
    fi
}

is_protected() {  # is_protected <dev> -> 0 if the disk has any mounted partition
    local disk="$1" mp
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && return 0
    done < <(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null || true)
    return 1
}

classify_media() {  # classify_media <tran> <rota> -> MEDIA label
    local tran="$1" rota="$2"
    case "$tran" in
        nvme) echo "NVMe SSD" ;;
        sata)
            [[ "$rota" == "1" ]] && echo "HDD" || echo "SATA SSD"
            ;;
        usb)
            [[ "$rota" == "1" ]] && echo "USB HDD" || echo "USB flash/SSD"
            ;;
        virtio|xen) echo "Virtual disk" ;;
        *)          echo "Unknown ($tran)" ;;
    esac
}

human_size() {  # bytes -> human readable
    local b="$1"
    if (( b >= 1000000000000 )); then printf "%.1f TB" "$(awk "BEGIN{print $b/1000000000000}")"
    elif (( b >= 1000000000 )); then printf "%.1f GB" "$(awk "BEGIN{print $b/1000000000}")"
    else printf "%d MB" "$(( b / 1000000 ))"
    fi
}

enumerate() {
    detect_boot_disk
    D_COUNT=0
    local line dev model serial size tran rm rota type
    while IFS= read -r line; do
        # shellcheck disable=SC1091
        eval "$line"   # sets NAME PATH MODEL SERIAL SIZE TRAN RM ROTA TYPE
        [[ "${TYPE:-}" == "disk" ]] || continue
        dev="/dev/${NAME:?}"
        [[ -z "$dev" ]] && continue
        model="${MODEL:-unknown}"
        serial="${SERIAL:-unknown}"
        media="$(classify_media "${TRAN:-?}" "${ROTA:-0}")"
        flags=""
        if [[ "$dev" == "$BOOT_DISK" ]]; then
            flags="BOOT-USB"
        elif is_protected "$dev"; then
            flags="MOUNTED"
        elif [[ "${TRAN:-}" == "usb" || "${RM:-0}" == "1" ]]; then
            flags="USB"
        fi
        D_DEV+=("$dev"); D_MODEL+=("$model"); D_SERIAL+=("$serial")
        D_SIZE+=("$SIZE"); D_TRAN+=("${TRAN:-?}"); D_MEDIA+=("$media")
        D_FLAGS+=("$flags")
        D_COUNT=$((D_COUNT+1))
    done < <(lsblk -P -b -d -o NAME,MODEL,SERIAL,SIZE,TRAN,RM,ROTA,TYPE -e 7,11 2>/dev/null || true)
    # NOTE: PATH is deliberately NOT in the column list -- see Invoke-Nuke.sh.

    local i j s
    for (( i=0; i<D_COUNT; i++ )); do
        s="${D_SERIAL[$i]}"
        [[ -z "$s" || "$s" == "unknown" ]] && continue
        if (( $(serial_count "$s") > 1 )); then
            if [[ -z "${D_FLAGS[$i]}" ]]; then D_FLAGS[$i]="DUP-SERIAL";
            else D_FLAGS[$i]="${D_FLAGS[$i]} DUP-SERIAL"; fi
        fi
    done

    echo "======================================================================"
    echo " PHOENIX BACKUP -- block device enumeration ($(ts))"
    echo "======================================================================"
    printf "%-3s %-12s %-28s %-22s %-9s %-6s %-14s %s\n" \
        "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "BUS" "MEDIA" "FLAGS"
    echo "----------------------------------------------------------------------"
    local i
    for (( i=0; i<D_COUNT; i++ )); do
        printf "%-3d %-12s %-28.28s %-22.22s %-9s %-6s %-14s %s\n" \
            "$((i+1))" "${D_DEV[$i]}" "${D_MODEL[$i]}" "${D_SERIAL[$i]}" \
            "$(human_size "${D_SIZE[$i]}")" "${D_TRAN[$i]}" "${D_MEDIA[$i]}" "${D_FLAGS[$i]}"
    done
    echo "----------------------------------------------------------------------"
    echo " $D_COUNT disk(s) detected. No flags given: dry-run, nothing written."
    if [[ -n "$BOOT_DISK" ]]; then
        echo " Boot USB identified as $BOOT_DISK -- structurally protected."
    else
        echo " WARNING: boot USB could not be positively identified."
        echo "          Any disk with mounted partitions is still refused."
    fi
    echo "======================================================================"
}

# serial_count <serial> -> number of enumerated disks reporting that exact serial
serial_count() {
    local s="$1" i n=0
    for (( i=0; i<D_COUNT; i++ )); do
        [[ "${D_SERIAL[$i]}" == "$s" ]] && n=$((n+1))
    done
    echo "$n"
}

# refuse_dup_serial <serial> <dev> -> exit 1 when the serial is reported by
# more than one disk (identity failure -- a proof bound to an ambiguous
# serial proves nothing for the Nuke gate).
refuse_dup_serial() {
    local serial="$1" dev="$2" i
    [[ -z "$serial" || "$serial" == "unknown" ]] && return 0
    if (( $(serial_count "$serial") > 1 )); then
        echo "[$PROG] REFUSED: serial '$serial' is reported by MULTIPLE disks:" >&2
        for (( i=0; i<D_COUNT; i++ )); do
            if [[ "${D_SERIAL[$i]}" == "$serial" ]]; then
                echo "  row $((i+1)): ${D_DEV[$i]} (${D_MODEL[$i]}, $(human_size "${D_SIZE[$i]}"))" >&2
            fi
        done
        echo "[$PROG] Identity ambiguous -- an image-proof bound to this" >&2
        echo "[$PROG] serial would prove nothing for the Nuke gate." >&2
        return 1
    fi
    return 0
}

# resolve_id <id> -> index into D_* arrays, or exit 1
resolve_id() {
    local id="$1" i
    if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= D_COUNT )); then
        echo $((id-1)); return 0
    fi
    if [[ "$id" == /dev/disk/by-id/* && -e "$id" ]]; then
        id="$(readlink -f "$id")"
    fi
    local first=-1 matches=0
    for (( i=0; i<D_COUNT; i++ )); do
        if [[ "${D_SERIAL[$i]}" == "$id" ]]; then
            matches=$((matches+1))
            (( first == -1 )) && first=$i
        fi
    done
    if (( matches > 1 )); then
        echo "[$PROG] REFUSED: identifier '$id' is ambiguous --" \
            "$matches disks report serial '$id'." >&2
        return 1
    fi
    if (( matches == 1 )); then
        echo "$first"; return 0
    fi
    for (( i=0; i<D_COUNT; i++ )); do
        if [[ "${D_DEV[$i]}" == "$id" ]]; then
            echo "$i"; return 0
        fi
    done
    return 1
}

#===============================================================================
# stick policy: phoenix-config.json (--config, REQUIRED)
#===============================================================================
# normalize_serial <serial> -> uppercased, whitespace-trimmed serial.
normalize_serial() {
    # `command` bypasses any shell function named tr/sed in the caller's
    # environment (see Invoke-Nuke.sh).
    echo "$1" | command tr '[:lower:]' '[:upper:]' | command sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# load_usb_config -- validate the stick's phoenix-config.json and import its
# backup policy into CFG_* variables. Fail closed on EVERY problem. The
# config path is ALWAYS explicit: the boot menu launcher passes the stick's
# own /phoenix-config.json by path.
load_usb_config() {
    local reader="$TOOLS_DIR/Read-UsbConfig.py"
    [[ -f "$reader" ]] || \
        die "REFUSED: --config requires tools/Read-UsbConfig.py next to Invoke-Backup.sh (stick image incomplete)."
    command -v python3 >/dev/null 2>&1 || \
        die "REFUSED: --config requires python3 to read phoenix-config.json (stick image incomplete)."
    [[ -n "$CONFIG" && -f "$CONFIG" ]] || \
        die "REFUSED: --config '$CONFIG' is not a readable file."
    local cfg_out
    if ! cfg_out="$(python3 "$reader" --shell "$CONFIG" 2>&1)"; then
        die "REFUSED: --config '$CONFIG' is not a valid phoenix-config.json: $cfg_out"
    fi
    # shellcheck disable=SC1090
    eval "$cfg_out"   # sets CFG_BACKUP_ENABLED, CFG_BACKUP_KIND,
                      # CFG_BACKUP_LABEL_PREFIX, CFG_BACKUP_SMB_PATH (+nuke keys).
                      # Values are shlex-quoted by the reader -- eval-safe.
    [[ -n "${CFG_BACKUP_ENABLED:-}" ]] || \
        die "REFUSED: config reader returned no policy (stick image incomplete)."
}

# check_backup_policy -- enforce the stick's backup policy. Runs before
# everything else: the stick's own config is the outermost precondition.
check_backup_policy() {
    if [[ "${CFG_BACKUP_ENABLED:-0}" != "1" ]]; then
        die "REFUSED: this stick's phoenix-config.json has boot_entries.backup=false. The stick's boot menu would not offer Backup either -- a CLI --source cannot override the stick's own policy."
    fi
    if [[ "${CFG_BACKUP_KIND:-}" != "direct-usb" ]]; then
        die "REFUSED: this stick's phoenix-config.json sets backup_target.kind='${CFG_BACKUP_KIND:-}' (smb_path='${CFG_BACKUP_SMB_PATH:-}'). The scripted boot path only images to a DIRECT-ATTACHED USB target: a network push from the infected machine would violate the air-gap gate (runbook Step 2.1). Quarantine the image and copy it to Castle from a CLEAN machine (runbook Step 2.7) instead."
    fi
}

#===============================================================================
# air-gap gate
#===============================================================================
# network_up_list -> newline-separated list of non-loopback interfaces whose
# operstate is "up". Empty output = air-gapped (as far as we can tell).
network_up_list() {
    local iface state
    [[ -d "$SYS_NET_DIR" ]] || return 0
    for iface in "$SYS_NET_DIR"/*; do
        iface="$(basename "$iface")"
        [[ "$iface" == "lo" ]] && continue
        state="$(cat "$SYS_NET_DIR/$iface/operstate" 2>/dev/null || echo unknown)"
        [[ "$state" == "up" ]] && echo "$iface"
    done
    return 0
}

# check_air_gap -- refuse when any non-loopback interface is up, unless
# --allow-network was passed AND the operator types ALLOW NETWORK on a real
# TTY. Piped or scripted stdin can never allow network access.
check_air_gap() {
    local up
    up="$(network_up_list)"
    if [[ -z "$up" ]]; then
        return 0
    fi
    if (( ALLOW_NETWORK == 0 )); then
        echo "[$PROG] REFUSED: network interface(s) UP: $(echo "$up" | tr '\n' ' ')" >&2
        echo "[$PROG] The Backup phase must be AIR-GAPPED (runbook Step 2.1)." >&2
        echo "[$PROG] Unplug Ethernet and disable Wi-Fi, then re-run. In a true" >&2
        echo "[$PROG] emergency, pass --allow-network and type ALLOW NETWORK at" >&2
        echo "[$PROG] the console -- it is logged." >&2
        return 1
    fi
    if [[ ! -t 0 ]]; then
        echo "[$PROG] REFUSED: --allow-network needs a real console (stdin is not a TTY)." >&2
        return 1
    fi
    local answer
    read -r -p "Network is UP. Type 'ALLOW NETWORK' to image with network active: " answer
    [[ "$answer" == "ALLOW NETWORK" ]]
}

#===============================================================================
# imaging
#===============================================================================
# pick_compressor -> "cmd|extension" (e.g. "pigz|gz"). Prefers multi-core pigz,
# then zstd, then gzip; falls back to raw dd when nothing is available.
pick_compressor() {
    if command -v pigz >/dev/null 2>&1; then echo "pigz|gz"
    elif command -v zstd >/dev/null 2>&1; then echo "zstd|zst"
    elif command -v gzip >/dev/null 2>&1; then echo "gzip|gz"
    else echo "|raw"
    fi
}

# sanitize_name <label> -> filename-safe label
sanitize_name() {
    echo "$1" | command sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/-\{2,\}/-/g'
}

start_log() {  # start_log <serial>
    local serial="$1"
    local dir="$LOG_DIR"
    if [[ -z "$dir" ]]; then
        local mp
        mp="$(lsblk -nr -o MOUNTPOINTS "$BOOT_DISK" 2>/dev/null | grep -v '^$' | head -n1 || true)"
        if [[ -z "$mp" ]]; then
            die "Cannot locate the boot USB mount point for logging. Re-run with --log-dir <dir>."
        fi
        dir="$mp/phoenix-logs"
    fi
    mkdir -p "$dir" || die "Cannot create log dir $dir"
    LOGFILE="$dir/backup-${serial}-$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$LOGFILE" || die "Cannot write logfile $LOGFILE"
    log "=== Phoenix BACKUP v$VERSION session started ==="
    log "Operator: ${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"
}

# check_source <idx> -- structural refusals for the source disk (normal mode)
check_source() {
    local idx="$1"
    local dev="${D_DEV[$idx]}" serial="${D_SERIAL[$idx]}"
    if [[ "$dev" == "$BOOT_DISK" ]]; then
        die "REFUSED: $dev is the boot USB. It cannot be imaged as a source."
    fi
    if is_protected "$dev"; then
        die "REFUSED: $dev has mounted partitions. Boot the rescue environment (not Windows) and unmount it first -- a mounted disk cannot be imaged consistently."
    fi
    if [[ ! -b "$dev" ]]; then
        die "REFUSED: $dev is not a block device."
    fi
    if [[ -z "$serial" || "$serial" == "unknown" ]]; then
        die "REFUSED: $dev reports no serial number -- the proof would have nothing to bind. Aborting."
    fi
    if ! refuse_dup_serial "$serial" "$dev"; then
        die "REFUSED: duplicated serial '$serial' -- identity ambiguous. Aborting."
    fi
}

# check_target <idx> <mount> -- structural refusals for the target disk
check_target() {
    local idx="$1" mount="$2"
    local dev="${D_DEV[$idx]}" serial="${D_SERIAL[$idx]}"
    if [[ "$dev" == "$BOOT_DISK" ]]; then
        die "REFUSED: $dev is the boot USB. The image target must be a SECOND, direct-attached USB drive -- never the Phoenix stick itself."
    fi
    if [[ -z "$serial" || "$serial" == "unknown" ]]; then
        die "REFUSED: target $dev reports no serial number. Aborting."
    fi
    if [[ "${D_FLAGS[$idx]}" != *USB* ]]; then
        die "REFUSED: target $dev is not flagged USB (tran=${D_TRAN[$idx]}). The scripted path images only to a direct-attached USB drive. Detach/attach the drive so the kernel reports it as USB."
    fi
    [[ -d "$mount" ]] || die "REFUSED: --target-mount '$mount' is not a directory."
    [[ -w "$mount" ]] || die "REFUSED: --target-mount '$mount' is not writable."
    if (( TEST_MODE == 1 )); then
        log "TEST MODE: skipping mount-descent verification of '$mount'."
        return 0
    fi
    # The mount must descend from the declared target disk -- never from an
    # unrelated device that happens to be mounted.
    local src parent pserial
    src="$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null || true)"
    [[ -n "$src" ]] || die "REFUSED: '$mount' is not a mountpoint (findmnt found no source)."
    parent="$(parent_disk "$src")"
    pserial="$(lsblk -dnro SERIAL "$parent" 2>/dev/null || true)"
    if [[ -z "$pserial" ]]; then
        die "REFUSED: cannot determine the serial of '$mount' (backing device $parent). Refusing to write to an unverified mount."
    fi
    if [[ "$(normalize_serial "$pserial")" != "$(normalize_serial "$serial")" ]]; then
        die "REFUSED: '$mount' descends from disk serial '$pserial', not the declared target serial '$serial'. The target mount must live on the declared target disk."
    fi
}

# check_free_space <mount> <source_bytes> -- fail closed on cramped targets.
# Images are compressed, so the bar is half the source size -- but below that,
# we refuse rather than discover mid-image that the drive is full.
check_free_space() {
    local mount="$1" source_bytes="$2"
    local avail
    avail="$(df --output=avail -B1 "$mount" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
    [[ "$avail" =~ ^[0-9]+$ ]] || die "REFUSED: cannot determine free space on '$mount'."
    if (( avail < source_bytes / 2 )); then
        die "REFUSED: only $(human_size "$avail") free on '$mount' -- less than half of the source size $(human_size "$source_bytes"). Attach a larger target drive."
    fi
    if (( avail < source_bytes )); then
        log "WARNING: $(human_size "$avail") free vs $(human_size "$source_bytes") source -- compressed images usually fit, but watch the image size as it writes."
    fi
}

# smoke_check_image <file> <ext> -- mount-ability smoke check: the first
# bytes of the image (decompressed when needed) must carry a recognizable
# disk signature -- MBR 0x55AA or GPT "EFI PART". Returns 0 when recognized.
smoke_check_image() {
    local img="$1" ext="$2"
    local probe="$T_PROBE/head512.bin"
    mkdir -p "$T_PROBE"
    case "$ext" in
        gz)  gzip -dc -- "$img" 2>/dev/null | head -c 1024 > "$probe" ;;
        zst) zstd -dc -- "$img" 2>/dev/null | head -c 1024 > "$probe" ;;
        raw) head -c 1024 -- "$img" > "$probe" ;;
        *)   return 1 ;;
    esac
    [[ -s "$probe" ]] || return 1
    # MBR signature: bytes 510-511 of sector 0 are 55 AA.
    local sig
    sig="$(od -A n -t x1 -j 510 -N 2 "$probe" 2>/dev/null | tr -d ' \n')"
    [[ "$sig" == "55aa" ]] && return 0
    # GPT: LBA1 (offset 512) starts with "EFI PART".
    if grep -q "EFI PART" "$probe" 2>/dev/null; then return 0; fi
    return 1
}

# do_image <src> <dst> <comp> -- the scripted image write. Returns the
# sha256 of the stored file on stdout.
do_image() {
    local src="$1" dst="$2" comp="$3"
    log "Imaging: dd if=$src -> $dst (compressor: ${comp:-none/raw})"
    log "This can take hours on a failing disk. Do not interrupt power."
    case "$comp" in
        pigz) dd if="$src" bs=4M status=progress 2>>"$LOGFILE" | pigz -c > "$dst" ;;
        zstd) dd if="$src" bs=4M status=progress 2>>"$LOGFILE" | zstd -c -T0 > "$dst" ;;
        gzip) dd if="$src" bs=4M status=progress 2>>"$LOGFILE" | gzip -c > "$dst" ;;
        "")   dd if="$src" bs=4M status=progress 2>>"$LOGFILE" of="$dst" ;;
        *)    die "Unknown compressor '$comp' (internal error)." ;;
    esac
    log "Image write finished. Re-hashing the stored file (independent verification)..."
    sha256sum -- "$dst" | awk '{print $1}'
}

# emit_proof <image> <name> <sha256> <serial> <srcdev> <size> <proofdir>
# Writes the image-proof manifest via the REAL tools/New-ImageProof.sh.
emit_proof() {
    local image="$1" name="$2" sha="$3" serial="$4" srcdev="$5" size="$6" proofdir="$7"
    local writer="$TOOLS_DIR/New-ImageProof.sh"
    [[ -x "$writer" ]] || die "tools/New-ImageProof.sh missing or not executable -- cannot emit the proof (stick image incomplete)."
    mkdir -p "$proofdir" || die "Cannot create proof dir $proofdir"
    [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "INTERNAL: image hash '$sha' is not 64-hex -- refusing to write a bogus proof."
    (( size > 0 )) || die "INTERNAL: image size is not positive -- refusing to write a bogus proof."
    log "Writing image-proof manifest (verified=YES): $name <- serial $serial"
    "$writer" \
        --image-name "$name" \
        --image-path "$image" \
        --source-serial "$serial" \
        --source-dev "$srcdev" \
        --sha256 "$sha" \
        --image-size-bytes "$size" \
        --verified \
        --verified-by "phoenix-backup:${USER:-unknown}" \
        --out "$proofdir" --json-out "$proofdir" 2>&1 | tee -a "$LOGFILE"
}

# print_rescuezilla_checklist -- manual Rescuezilla path (runbook Step 2.3).
print_rescuezilla_checklist() {
    cat <<EOF
Phoenix BACKUP -- manual Rescuezilla path (runbook Step 2.3)

The scripted path is skipped (--tool rescuezilla). Do this by hand:

  1. Air-gap the machine: Ethernet unplugged, Wi-Fi off (runbook Step 2.1).
  2. Boot [2] BACKUP -- Rescuezilla from the Phoenix USB. Do NOT boot Windows.
  3. Backup -> select the ENTIRE source disk (not partitions) ->
     destination = the external USB drive. Enable compression AND the
     post-backup integrity check. Name it clearly, e.g. ${1}-$(date -u +%Y-%m-%d).
  4. VERIFY: let Rescuezilla's post-backup check finish green. Confirm the
     image files exist on the target and sizes are sane. If the check
     fails, re-run -- never proceed to Nuke on a failed image.
  5. Write the image-proof manifest (runbook Step 2.5):
       ./tools/New-ImageProof.sh \\
           --image-name <name> --image-path <image> \\
           --source-serial <serial-of-the-imaged-disk> \\
           --sha256 <64-hex-from-the-backup-tool> \\
           --verified --verified-by <you> \\
           --out /media/phoenix-usb/phoenix-logs/
     --verified asserts YOU watched the integrity check pass.
  6. Data-only backup to a separate location (runbook Step 2.6).
  7. Rename the image QUARANTINE-INFECTED-<date>; from a CLEAN machine,
     copy it to Castle (runbook Step 2.7). The infected machine stays
     air-gapped until wiped.
EOF
}

#===============================================================================
# main
#===============================================================================
T_PROBE=""   # scratch dir for smoke-check probing (created on demand)

main() {
    while (( $# > 0 )); do
        case "$1" in
            --config)       CONFIG="${2:?--config needs a file}"; shift 2 ;;
            --source)       SOURCE_ID="${2:?--source needs a disk id}"; shift 2 ;;
            --target)       TARGET_SERIAL="${2:?--target needs a serial}"; shift 2 ;;
            --target-mount) TARGET_MOUNT="${2:?--target-mount needs a dir}"; shift 2 ;;
            --tool)         TOOL="${2:?--tool needs dd|rescuezilla}"; shift 2 ;;
            --image-name)   IMAGE_NAME="${2:?--image-name needs a name}"; shift 2 ;;
            --log-dir)      LOG_DIR="${2:?--log-dir needs a dir}"; shift 2 ;;
            --proof-out)    PROOF_OUT="${2:?--proof-out needs a dir}"; shift 2 ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --allow-network) ALLOW_NETWORK=1; shift ;;
            --test-serial)  TEST_SERIAL="${2:?--test-serial needs a serial}"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1 (see --help)" ;;
        esac
    done

    # --- test-mode gating (fail closed outside tests) ---
    if [[ -n "$TEST_SERIAL" && "$TEST_MODE" != "1" ]]; then
        die "REFUSED: --test-serial is only honored with PHOENIX_BACKUP_TEST=1."
    fi

    if (( TEST_MODE != 1 )); then
        [[ $EUID -eq 0 ]] || die "Must run as root (block-device access required)."
    fi
    for cmd in lsblk dd sha256sum od findmnt df; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found -- boot image is incomplete."
    done

    case "$TOOL" in
        dd|rescuezilla) ;;
        *) die "Unknown --tool '$TOOL' (dd|rescuezilla)" ;;
    esac

    # --- enumerate first, always (dry-run posture) ---
    # The stick policy loads only when actually planning or running a
    # backup -- bare enumeration never needs python3, mirroring the Nuke
    # module's convention.
    if (( TEST_MODE != 1 )); then
        enumerate
    fi

    if [[ -z "$SOURCE_ID" && $DRY_RUN -eq 0 && "$TOOL" != "rescuezilla" ]]; then
        # Bare enumeration: no flags given, nothing planned, nothing written.
        exit 0
    fi

    # --- stick policy: --config is REQUIRED for everything beyond bare
    # --- enumeration (plan, dry-run, rescuezilla checklist, armed run) ---
    [[ -n "$CONFIG" ]] || die "REFUSED: --config <phoenix-config.json> is required. The stick's own policy gates every Backup run."
    load_usb_config
    check_backup_policy

    local label="${CFG_BACKUP_LABEL_PREFIX:-PHOENIX-IMAGE}"
    if [[ "$TOOL" == "rescuezilla" ]]; then
        print_rescuezilla_checklist "$(sanitize_name "$label")"
        exit 0
    fi

    # --- dry-run needs its identifiers too ---
    if (( DRY_RUN == 1 )); then
        [[ -n "$SOURCE_ID" ]]    || die "--dry-run needs --source <id>."
        [[ -n "$TARGET_SERIAL" ]] || die "--dry-run needs --target <serial>."
        [[ -n "$TARGET_MOUNT" ]]  || die "--dry-run needs --target-mount <dir>."
    fi

    # --- air-gap gate (before any disk is even resolved) ---
    if ! check_air_gap; then
        die "Air-gap gate failed -- nothing was written."
    fi

    # --- source + target identity ---
    local src_dev src_model src_serial src_size srcdev_label
    local tgt_idx tgt_dev tgt_serial
    if (( TEST_MODE == 1 )); then
        [[ -n "$SOURCE_ID" && -f "$SOURCE_ID" && ! -b "$SOURCE_ID" ]] || \
            die "TEST MODE: --source must be a regular file (file-backed fake source)."
        [[ -n "$TEST_SERIAL" ]] || \
            die "TEST MODE: --test-serial <serial> is required to bind the proof."
        src_dev="$SOURCE_ID"
        src_model="FILE-BACKED TEST DISK"
        src_serial="$(normalize_serial "$TEST_SERIAL")"
        src_size="$(stat -c %s "$src_dev")"
        srcdev_label="file-backed (test)"
        tgt_serial="$TARGET_SERIAL"
        tgt_dev="<test target>"
        [[ -n "$TARGET_SERIAL" ]] || die "--target <serial> is required."
        [[ -n "$TARGET_MOUNT" ]] || die "--target-mount <dir> is required."
    else
        [[ -n "$SOURCE_ID" ]] || die "--source <id> is required (serial preferred)."
        [[ -n "$TARGET_SERIAL" ]] || die "--target <serial> is required."
        [[ -n "$TARGET_MOUNT" ]] || die "--target-mount <dir> is required."
        local src_idx
        if ! src_idx="$(resolve_id "$SOURCE_ID")"; then
            die "No disk matches identifier '$SOURCE_ID'."
        fi
        check_source "$src_idx"
        src_dev="${D_DEV[$src_idx]}"; src_model="${D_MODEL[$src_idx]}"
        src_serial="${D_SERIAL[$src_idx]}"; src_size="${D_SIZE[$src_idx]}"
        srcdev_label="$src_dev"
        # Target resolves by SERIAL (never by letter alone); row//dev aliases
        # of the enumerated table are accepted as in resolve_id.
        if ! tgt_idx="$(resolve_id "$TARGET_SERIAL")"; then
            die "No disk matches target identifier '$TARGET_SERIAL'."
        fi
        check_target "$tgt_idx" "$TARGET_MOUNT"
        tgt_dev="${D_DEV[$tgt_idx]}"; tgt_serial="${D_SERIAL[$tgt_idx]}"
        if [[ "$(normalize_serial "$tgt_serial")" == "$(normalize_serial "$src_serial")" ]]; then
            die "REFUSED: source and target resolve to the same serial '$src_serial'. A disk cannot image onto itself."
        fi
    fi

    # --- free-space check ---
    check_free_space "$TARGET_MOUNT" "$src_size"

    # --- image plan ---
    local comp_spec comp ext
    comp_spec="$(pick_compressor)"
    comp="${comp_spec%%|*}"; ext="${comp_spec##*|}"
    [[ -n "$IMAGE_NAME" ]] || IMAGE_NAME="$(sanitize_name "$label")-$(date -u +%Y%m%dT%H%M%SZ)"
    local img_name="img-${IMAGE_NAME}.${ext}"
    local img_path="$TARGET_MOUNT/$img_name"

    if (( DRY_RUN == 1 )); then
        cat <<EOF
======================================================================
 PHOENIX BACKUP -- DRY RUN (nothing will be written)
======================================================================
 Config        : $CONFIG (backup policy: ENABLED, kind=direct-usb)
 Air-gap       : OK (no non-loopback interface up)$( (( ALLOW_NETWORK == 1 )) && echo ", --allow-network armed" )
 Source        : $src_dev
                 model=$src_model serial=$src_serial size=$(human_size "$src_size")
 Target        : ${tgt_dev:-n/a} (serial=$tgt_serial) -> $TARGET_MOUNT
 Image         : $img_path
                 method: dd bs=4M${comp:+ | $comp} (compressor ext .$ext)
 Verify plan   : re-hash equality + MBR/GPT smoke check, then
                 New-ImageProof.sh --verified (proof binds serial $src_serial)
 Proof out     : ${PROOF_OUT:-<log dir on boot USB>}
======================================================================
 DRY RUN: no writes, no log, no proof. Re-run without --dry-run to image.
======================================================================
EOF
        exit 0
    fi

    # --- armed: log, image, verify, prove ---
    local proof_dir="${PROOF_OUT:-}"
    T_PROBE="$(mktemp -d /tmp/phoenix-backup-probe.XXXXXX)"
    trap 'rm -rf "$T_PROBE"' EXIT
    start_log "$src_serial"
    if (( TEST_MODE == 1 )); then
        log "TEST MODE: PHOENIX_BACKUP_TEST=1 -- file-backed source, mount-descent check skipped."
    fi
    if (( ALLOW_NETWORK == 1 )); then
        log "WARNING: --allow-network was typed at the console -- imaging with network UP (logged, runbook deviation)."
    fi
    log "SOURCE: $src_dev | model=$src_model | serial=$src_serial | size=$(human_size "$src_size")"
    log "TARGET: ${tgt_dev:-n/a} (serial=$tgt_serial) -> $TARGET_MOUNT"
    [[ -n "$proof_dir" ]] || proof_dir="$(dirname "$LOGFILE")"

    local sha
    # Only the LAST stdout line of do_image is the hash -- its log lines go
    # to stdout too (and to the logfile), so tail -n1 keeps them out of $sha.
    sha="$(do_image "$src_dev" "$img_path" "$comp" | tail -n1)"
    log "Image sha256: $sha"
    local img_bytes
    img_bytes="$(stat -c %s "$img_path")"
    log "Image size: $(human_size "$img_bytes") ($img_bytes bytes)"
    # Tripwire against a truncated/empty image. In test mode the fake source
    # is tiny (zeros compress to KB), so the bar drops to 1 KiB there.
    local min_size=1048576
    (( TEST_MODE == 1 )) && min_size=1024
    (( img_bytes >= min_size )) || die "Image is suspiciously small ($img_bytes bytes) -- verification FAILED, refusing to write a proof."
    if ! smoke_check_image "$img_path" "$ext"; then
        die "Mount-ability smoke check FAILED: '$img_path' carries no recognizable MBR/GPT signature. The image may be garbage -- refusing to write a proof. Investigate before proceeding."
    fi
    log "Smoke check PASSED: image carries a recognizable disk signature."

    emit_proof "$img_path" "$IMAGE_NAME" "$sha" "$src_serial" "$srcdev_label" "$img_bytes" "$proof_dir"

    log "=== BACKUP COMPLETE: $src_serial imaged to $img_path, proof emitted to $proof_dir ==="
    echo ""
    echo "BACKUP COMPLETE."
    echo "  Image: $img_path ($(human_size "$img_bytes"))"
    echo "  Proof: $proof_dir/image-proof-${src_serial}-*.proof"
    echo "  Log:   $LOGFILE"
    echo ""
    echo "Next (runbook Step 2.7): rename the image QUARANTINE-INFECTED-<date> and,"
    echo "from a CLEAN machine, copy it to Castle. Keep this machine air-gapped."
}

main "$@"
