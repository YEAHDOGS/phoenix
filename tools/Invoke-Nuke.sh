#!/usr/bin/env bash
#===============================================================================
# Invoke-Nuke.sh -- Phoenix NUKE module (the nuclear option)
#
# Completely and irreversibly destroys all data on a selected block device.
# Runs in the Phoenix Linux boot environment (USB menu: Analyze/Backup/Nuke/
# Reinstall). nwipe, hdparm and nvme-cli are Linux-only, and the boot menu
# has no PowerShell -- so this module is bash by design. There is no Windows
# pre-flight: destruction cannot be armed from a live Windows session anyway,
# and the interlocks must live where the destruction happens.
#
# SAFETY MODEL (see docs/NUKE-SAFETY.md):
#   1. Dry-run default: no flags (or --whatif) ONLY enumerates disks and exits.
#   2. Explicit enumeration: numbered table (model, serial, size, bus) first.
#   3. Never auto-select: no default target, ever.
#   4. Boot-USB guard: the booted USB (and any disk with mounted partitions)
#      is structurally refused -- not a warning, a hard block.
#   5. Typed confirmation: operator must type the target's serial (or
#      "NUKE <serial>"), not Y/N. Logged with timestamp.
#   6. Method per media (NIST 800-88): HDD -> nwipe (Clear);
#      SATA SSD -> ATA Secure Erase (Purge); NVMe -> nvme format --ses=1
#      (Purge); firmware purge unsupported -> nwipe fallback, logged warning.
#   7. Full logging to a file on the USB.
#
# USAGE:
#   Invoke-Nuke.sh                        enumerate only (dry-run), exit 0
#   Invoke-Nuke.sh --whatif               same as above
#   Invoke-Nuke.sh --nuke <id>            arm destruction of disk <id>
#   Invoke-Nuke.sh --method gutmann --verify-all --nuke <id>
#
# <id> may be the row number from the table, a /dev node, a /dev/disk/by-id
# path, or the disk serial number.
#
# Exit codes: 0 = enumerate/dry-run OK | 1 = error/refusal | 2 = user aborted
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"

# --- options -----------------------------------------------------------------
NUKE_ID=""            # disk identifier selected by the operator
METHOD_OVERRIDE="auto" # auto | dod522022m | gutmann | dodshort | zero
VERIFY="last"         # nwipe verify mode: off | last | all
LOG_DIR=""            # auto-detected on the boot USB unless overridden
NO_COUNTDOWN=0
WHATIF=0

# --- state -------------------------------------------------------------------
LOGFILE=""
declare -a D_DEV D_MODEL D_SERIAL D_SIZE D_TRAN D_MEDIA D_FLAGS
D_COUNT=0
BOOT_DISK=""          # /dev node of the booted USB (structural refusal)

#===============================================================================
# logging
#===============================================================================
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {  # log <message>  -- timestamped, to console AND logfile (once armed)
    local msg="[$(ts)] $*"
    echo "$msg"
    if [[ -n "$LOGFILE" ]]; then
        echo "$msg" >> "$LOGFILE"
    fi
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Phoenix NUKE v$VERSION -- nuclear disk sanitization (boot environment only)

Usage:
  $PROG                        Enumerate disks and exit (dry-run, the default)
  $PROG --whatif               Same as above
  $PROG --nuke <id>            Arm destruction of disk <id> (interactive)
  $PROG --method <m> --nuke <id>   Override HDD overwrite method
  $PROG --verify-all --nuke <id>    Verify every pass (slower, stronger)
  $PROG --log-dir <dir> --nuke <id> Override log location
  $PROG --no-countdown --nuke <id>  Skip the final 5s abort window
  $PROG --help                 This help

<id>: row number from the enumeration table, /dev node,
      /dev/disk/by-id/... path, or disk serial number.

Methods per media (NIST 800-88, see docs/NUKE-SAFETY.md):
  HDD (spinning)  -> nwipe DoD 5220.22-M 7-pass      (Clear)
  SATA SSD        -> ATA Secure Erase via hdparm     (Purge)
  NVMe SSD        -> nvme format --ses=1 crypto erase (Purge)
  Firmware purge unsupported -> nwipe fallback with logged warning.

RULES: no flags = enumerate only. No default target. The boot USB and any
disk with mounted partitions are refused structurally. Arming requires
typing the target disk's serial number. Full log is written to the USB.
VM-ONLY TESTING. NEVER test destructive paths on bare metal.
EOF
}

#===============================================================================
# enumeration
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
    # fallback: strip trailing partition digits (sda1 -> sda, nvme0n1p2 -> nvme0n1,
    # mmcblk0p1 -> mmcblk0). The nvme/mmcblk/loop substitutions must be tried
    # FIRST and must not fall through to the generic one: a second pass would
    # re-strip the disk name itself (nvme0n1 -> nvme0n). `t` skips to end of
    # script after the first successful substitution.
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
# A disk is "protected" (refused as a target) if ANY of its partitions is
# currently mounted, or if the kernel cmdline names it as root/boot device.
detect_boot_disk() {
    local -a protected=()

    # 1. kernel cmdline: root=/dev/..., BOOT_IMAGE=/dev/...
    local cmdline rootdev
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    for tok in $cmdline; do
        case "$tok" in
            root=/dev/*|BOOT_IMAGE=/dev/*)
                rootdev="${tok#*=}"
                rootdev="${rootdev%% *}"
                protected+=("$(parent_disk "$rootdev")")
                ;;
        esac
    done

    # 2. any disk with a mounted descendant partition
    local disk mp
    while IFS= read -r disk; do
        while IFS= read -r mp; do
            if [[ -n "$mp" ]]; then
                protected+=("$disk")
                break
            fi
        done < <(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null | grep -v '^$' || true)
    done < <(lsblk -dnr -o PATH -e 7,11 2>/dev/null || true)  # exclude loop(7), sr(11)

    # Prefer the removable/USB one as THE boot USB, else the first protected.
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
        dev="/dev/${NAME:?}"   # rebuilt from NAME; see PATH note below
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
    # NOTE: PATH is deliberately NOT in the column list. `eval` below would
    # turn PATH=/dev/... into a shell assignment and clobber the real PATH,
    # silently breaking every external call afterwards (is_protected, awk in
    # human_size, ...). The device node is rebuilt from NAME instead.

    # --- print the numbered table ---
    echo "======================================================================"
    echo " PHOENIX NUKE -- block device enumeration ($(ts))"
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
    echo " $D_COUNT disk(s) detected. No flags given: dry-run, nothing destroyed."
    if [[ -n "$BOOT_DISK" ]]; then
        echo " Boot USB identified as $BOOT_DISK -- structurally protected."
    else
        echo " WARNING: boot USB could not be positively identified."
        echo "          Any disk with mounted partitions is still refused."
    fi
    echo "======================================================================"
}

# resolve_id <id> -> index into D_* arrays, or exit 1
resolve_id() {
    local id="$1" i
    # row number
    if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= D_COUNT )); then
        echo $((id-1)); return 0
    fi
    # /dev/disk/by-id/... -> canonical /dev node
    if [[ "$id" == /dev/disk/by-id/* && -e "$id" ]]; then
        id="$(readlink -f "$id")"
    fi
    for (( i=0; i<D_COUNT; i++ )); do
        if [[ "${D_DEV[$i]}" == "$id" || "${D_SERIAL[$i]}" == "$id" ]]; then
            echo "$i"; return 0
        fi
    done
    return 1
}

#===============================================================================
# wipe methods
#===============================================================================
method_for() {  # method_for <media> -> method tag
    local media="$1"
    case "$METHOD_OVERRIDE" in
        dod522022m|gutmann|dodshort|zero)
            echo "nwipe:$METHOD_OVERRIDE"; return ;;
    esac
    case "$media" in
        "NVMe SSD")   echo "nvme-format-ses1" ;;
        "SATA SSD")   echo "ata-secure-erase" ;;
        "HDD"|"USB HDD") echo "nwipe:dod522022m" ;;
        "USB flash/SSD") echo "nwipe:dodshort" ;;
        "Virtual disk")  echo "nwipe:dodshort" ;;
        *)            echo "nwipe:dodshort" ;;
    esac
}

nist_level_for() {  # nist_level_for <method> -> NIST 800-88 level
    case "$1" in
        nvme-format-ses1|nvme-sanitize|ata-secure-erase) echo "Purge" ;;
        nwipe:*) echo "Clear" ;;
    esac
}

check_nwipe()  { command -v nwipe >/dev/null 2>&1 || die "nwipe not found in PATH -- install it in the boot image."; }
check_hdparm() { command -v hdparm >/dev/null 2>&1 || die "hdparm not found in PATH -- install it in the boot image."; }
check_nvme()   { command -v nvme >/dev/null 2>&1 || die "nvme-cli not found in PATH -- install it in the boot image."; }

do_nwipe() {  # do_nwipe <dev> <nwipe-method>
    local dev="$1" m="$2"
    check_nwipe
    log "Launching nwipe: method=$m verify=$VERIFY device=$dev"
    # NOTE: --autonuke is only ever passed WITH an explicit device that has
    # already survived the boot-USB guard, mount guard, and serial confirmation.
    # A bare --autonuke (wipe everything) is never invoked by this script.
    nwipe --autonuke --nogui --verify="$VERIFY" --method="$m" \
          --logfile="$LOGFILE.nwipe" "$dev"
}

do_ata_secure_erase() {  # do_ata_secure_erase <dev> ; falls back to nwipe
    local dev="$1"
    check_hdparm
    local info sec
    info="$(hdparm -I "$dev" 2>/dev/null || true)"
    sec="$(echo "$info" | sed -n '/^Security:/,/^$/p')"

    if echo "$sec" | grep -qiE 'not[[:space:]]+supported'; then
        log "WARNING: ATA Security feature set NOT supported on $dev."
        log "WARNING: falling back to nwipe (NIST Clear only -- SSD overprovisioned"
        log "WARNING: areas may retain data; see docs/NUKE-SAFETY.md)."
        do_nwipe "$dev" "dodshort"
        return
    fi
    if echo "$sec" | grep -qE '^[[:space:]]+frozen$'; then
        die "Drive $dev is in SECURITY FROZEN state. Suspend/resume the machine once (sleep/wake), then re-run. Refusing to proceed."
    fi
    if echo "$sec" | grep -qiE 'not[[:space:]]+enabled'; then
        : # expected: security not yet enabled
    fi

    local pw="phoenix-nuke"
    log "Setting ATA security password and issuing SECURE ERASE on $dev ..."
    if echo "$sec" | grep -qi 'enhanced erase'; then
        log "Using ENHANCED secure erase (firmware-preferred)."
        hdparm --user-master u --security-set-pass "$pw" "$dev" >>"$LOGFILE" 2>&1
        hdparm --user-master u --security-erase-enhanced "$pw" "$dev" >>"$LOGFILE" 2>&1
    else
        hdparm --user-master u --security-set-pass "$pw" "$dev" >>"$LOGFILE" 2>&1
        hdparm --user-master u --security-erase "$pw" "$dev" >>"$LOGFILE" 2>&1
    fi
    log "ATA Secure Erase completed on $dev (firmware reports success)."
}

do_nvme_purge() {  # do_nvme_purge <dev> ; falls back to sanitize, then nwipe
    local dev="$1"
    check_nvme
    local ctrl="${dev%n[0-9]*}"   # /dev/nvme0n1 -> /dev/nvme0
    [[ "$ctrl" == "$dev" ]] && ctrl="$dev"
    local idctrl
    idctrl="$(nvme id-ctrl -H "$ctrl" 2>/dev/null || true)"

    if echo "$idctrl" | grep -qi 'crypto erase.*supported'; then
        log "Issuing NVMe Format with Secure Erase Setting=1 (crypto erase) on $dev ..."
        nvme format "$dev" --ses=1 --force >>"$LOGFILE" 2>&1
        log "NVMe crypto erase completed on $dev."
        return
    fi
    if echo "$idctrl" | grep -qi 'sanitize.*supported\|block erase.*supported'; then
        log "WARNING: crypto erase unsupported; falling back to NVMe Sanitize (block erase) on $ctrl ..."
        nvme sanitize "$ctrl" -a 2 >>"$LOGFILE" 2>&1   # -a 2 = block erase
        log "NVMe sanitize completed on $ctrl."
        return
    fi
    log "WARNING: NVMe Format crypto erase and Sanitize both unsupported on $dev."
    log "WARNING: falling back to nwipe (NIST Clear only -- see docs/NUKE-SAFETY.md)."
    do_nwipe "$dev" "dodshort"
}

#===============================================================================
# arming + destruction
#===============================================================================
start_log() {  # start_log <serial>
    local serial="$1"
    local dir="$LOG_DIR"
    if [[ -z "$dir" ]]; then
        # default: a logs dir on the boot USB's mounted partition
        local mp
        mp="$(lsblk -nr -o MOUNTPOINTS "$BOOT_DISK" 2>/dev/null | grep -v '^$' | head -n1 || true)"
        if [[ -z "$mp" ]]; then
            die "Cannot locate the boot USB mount point for logging. Re-run with --log-dir <dir>."
        fi
        dir="$mp/phoenix-logs"
    fi
    mkdir -p "$dir" || die "Cannot create log dir $dir"
    LOGFILE="$dir/nuke-${serial}-$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$LOGFILE" || die "Cannot write logfile $LOGFILE"
    log "=== Phoenix NUKE v$VERSION session started ==="
    log "Operator: ${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"
}

arm_and_nuke() {
    local idx="$1"
    local dev="${D_DEV[$idx]}" model="${D_MODEL[$idx]}" serial="${D_SERIAL[$idx]}"
    local size="${D_SIZE[$idx]}" tran="${D_TRAN[$idx]}" media="${D_MEDIA[$idx]}"
    local flags="${D_FLAGS[$idx]}"

    # --- structural refusals (not warnings) ---
    if [[ "$dev" == "$BOOT_DISK" ]]; then
        die "REFUSED: $dev is the boot USB. It cannot be nuked, structurally."
    fi
    if is_protected "$dev"; then
        die "REFUSED: $dev has mounted partitions. Unmount/detach it first; mounted media cannot be nuked."
    fi
    if [[ ! -b "$dev" ]]; then
        die "REFUSED: $dev is not a block device."
    fi
    if [[ "$serial" == "unknown" || -z "$serial" ]]; then
        die "REFUSED: $dev reports no serial number -- cannot satisfy typed confirmation. Aborting."
    fi

    local method nist
    method="$(method_for "$media")"
    nist="$(nist_level_for "$method")"

    start_log "$serial"

    log "TARGET: $dev | model=$model | serial=$serial | size=$(human_size "$size") | bus=$tran | media=$media"
    log "METHOD: $method (NIST 800-88 level: $nist)"

    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!  YOU ARE ABOUT TO IRREVERSIBLY DESTROY ALL DATA ON THIS DISK     !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  Device : $dev"
    echo "  Model  : $model"
    echo "  Serial : $serial"
    echo "  Size   : $(human_size "$size")"
    echo "  Media  : $media  (bus: $tran)"
    echo "  Method : $method   [NIST 800-88: $nist]"
    echo ""
    echo "  This is NOT recoverable. There is no undo."
    echo ""

    # --- typed confirmation: serial (or "NUKE <serial>"), never Y/N ---
    local answer
    read -r -p "Type the disk serial to arm ('$serial') or 'NUKE $serial': " answer
    local typed="$answer"
    if [[ "$typed" =~ ^[Nn][Uu][Kk][Ee][[:space:]]+(.+)$ ]]; then
        typed="${BASH_REMATCH[1]}"
    fi
    # trim whitespace
    typed="$(echo "$typed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$typed" != "$serial" ]]; then
        log "ABORTED by operator: typed confirmation did not match serial."
        echo "Aborted. Confirmation did not match. Nothing was destroyed."
        exit 2
    fi
    log "CONFIRMED: operator typed serial '$serial' at $(ts) -- destruction ARMED."

    # --- final abort window ---
    if (( NO_COUNTDOWN == 0 )); then
        echo ""
        echo "Armed. Starting destruction in 5 seconds -- press Ctrl-C to abort."
        for s in 5 4 3 2 1; do echo -n "$s... "; sleep 1; done
        echo ""
    fi

    # --- last-second re-verification: the device must still be the same disk ---
    local reserial
    reserial="$(lsblk -dnro SERIAL "$dev" 2>/dev/null || true)"
    if [[ "$reserial" != "$serial" ]]; then
        log "ABORTED: device $dev serial changed between confirmation and execution ('$reserial' != '$serial')."
        die "Device identity changed mid-run. Aborting -- hardware state is not trustworthy."
    fi
    log "Re-verified device identity: serial still '$serial'. Executing."

    local t0 t1
    t0="$(date +%s)"
    case "$method" in
        nwipe:*)            do_nwipe "$dev" "${method#nwipe:}" ;;
        ata-secure-erase)   do_ata_secure_erase "$dev" ;;
        nvme-format-ses1)   do_nvme_purge "$dev" ;;
        *)                  die "Unknown method tag: $method" ;;
    esac
    t1="$(date +%s)"

    log "=== NUKE COMPLETE: $dev ($serial) destroyed via $method in $((t1-t0))s ==="
    echo ""
    echo "NUKE COMPLETE: $dev destroyed via $method (NIST 800-88: $nist)."
    echo "Log: $LOGFILE"
}

#===============================================================================
# main
#===============================================================================
main() {
    while (( $# > 0 )); do
        case "$1" in
            --nuke)         NUKE_ID="${2:?--nuke needs a disk id}"; shift 2 ;;
            --method)       METHOD_OVERRIDE="${2:?--method needs a value}"; shift 2 ;;
            --verify-all)   VERIFY="all"; shift ;;
            --verify-off)   VERIFY="off"; shift ;;
            --log-dir)      LOG_DIR="${2:?--log-dir needs a path}"; shift 2 ;;
            --no-countdown) NO_COUNTDOWN=1; shift ;;
            --whatif)       WHATIF=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1 (see --help)" ;;
        esac
    done

    [[ $EUID -eq 0 ]] || die "Must run as root (block-device access required)."
    command -v lsblk >/dev/null 2>&1 || die "lsblk not found -- boot image is incomplete."

    case "$METHOD_OVERRIDE" in
        auto|dod522022m|gutmann|dodshort|zero) ;;
        *) die "Unknown --method '$METHOD_OVERRIDE' (auto|dod522022m|gutmann|dodshort|zero)" ;;
    esac

    enumerate

    if [[ -z "$NUKE_ID" || $WHATIF -eq 1 ]]; then
        # Dry-run default: enumerate and exit. Nothing is armed, nothing logged.
        exit 0
    fi

    local idx
    if ! idx="$(resolve_id "$NUKE_ID")"; then
        die "No disk matches identifier '$NUKE_ID'."
    fi
    arm_and_nuke "$idx"
}

main "$@"
