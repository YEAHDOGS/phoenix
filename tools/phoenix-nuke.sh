#!/usr/bin/env bash
#===============================================================================
# phoenix-nuke.sh -- Phoenix NUKE core (Linux rescue side)
#
# Nuclear disk sanitization for the Phoenix boot menu (Analyze / Backup /
# Nuke / Reinstall). The Windows-side twin is tools/Invoke-PhoenixNuke.ps1.
# Both implement the SAME interlock contract -- keep them in sync.
#
# SAFETY MODEL (exact rule parity with Invoke-PhoenixNuke.ps1):
#   1. Dry-run is the DEFAULT: no flags (or --dry-run/--whatif) ONLY
#      enumerates disks and exits 0. Destruction requires --nuke <id>.
#   2. Explicit enumeration: numbered table (device, model, serial, size,
#      bus, media, flags) is printed first.
#   3. Never auto-select: no default target, ever. <id> must be a row
#      number, a /dev node, or the exact serial. Wildcards (* ? [ ]) are
#      NEVER resolved -- fail closed. An identifier matching more than one
#      disk (e.g. duplicated serials) is an ambiguity refusal, never
#      first-match-wins.
#   4. Boot/USB self-protection: the boot disk (kernel cmdline root, or any
#      disk with mounted partitions) and USB-attached disks are refused
#      structurally UNLESS --override-boot-protection is given. The override
#      is logged as a WARNING and still requires the double-typed
#      confirmation.
#   5. Double-typed confirmation: the operator must type the target disk's
#      exact serial (or exact /dev path) TWICE, on a real terminal. Piped
#      or scripted stdin is refused structurally ([ -t 0 ]) -- a mismatch on
#      EITHER prompt aborts. Y/N is not accepted.
#   6. Audit record: every run writes timestamp, disk id, mode, and the
#      operator-confirmation evidence to a log file.
#   7. Final abort window: 5-second countdown after arming (Ctrl-C aborts;
#      --no-countdown only for VM tests).
#
# The destructive primitive is a full-device zero-fill (dd if=/dev/zero).
# WARNING: on flash media (SSD/NVMe/USB flash) a host-side overwrite is
# NIST 800-88 Clear at best -- overprovisioned flash is invisible to host
# writes. For firmware Purge on SSD/NVMe use tools/Invoke-Nuke.sh
# (ATA Secure Erase / NVMe crypto erase), which is the NIST-correct path.
#
# USAGE:
#   phoenix-nuke.sh                              enumerate only (dry-run)
#   phoenix-nuke.sh --dry-run | --whatif         same as above (explicit)
#   phoenix-nuke.sh --nuke <id>                  arm destruction of <id>
#   phoenix-nuke.sh --nuke <id> --log-dir <dir>  override audit log dir
#   phoenix-nuke.sh --nuke <id> --override-boot-protection
#       allow a boot/USB disk as the target (logged WARNING; confirmation
#       still required twice)
#   phoenix-nuke.sh --nuke <id> --no-countdown   skip the 5s abort window
#
# <id>: row number from the table, /dev node, or exact disk serial.
#
# Exit codes: 0 = enumerate/dry-run OK | 1 = error/refusal | 2 = aborted
# VM-ONLY TESTING. NEVER test destructive paths on bare metal.
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"

# --- options -----------------------------------------------------------------
NUKE_ID=""               # disk identifier selected by the operator
LOG_DIR=""               # default: ./phoenix-logs
OVERRIDE_BOOT_PROT=0     # --override-boot-protection
NO_COUNTDOWN=0
DRYRUN=0

# --- state -------------------------------------------------------------------
AUDITFILE=""
declare -a D_DEV D_MODEL D_SERIAL D_SIZE D_TRAN D_MEDIA D_FLAGS D_PROT
D_COUNT=0

#===============================================================================
# audit + helpers
#===============================================================================
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# audit <mode> [key=value ...] -- one structured line to console AND the
# audit file. Fields: timestamp, mode, disk id, operator confirmation.
audit() {
    local mode="$1"; shift
    local line="[$(ts)] mode=$mode"
    local kv
    for kv in "$@"; do line="$line $kv"; done
    line="$line override_boot_protection=$OVERRIDE_BOOT_PROT"
    echo "$line"
    if [[ -n "$AUDITFILE" ]]; then
        echo "$line" >> "$AUDITFILE"
    fi
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Phoenix NUKE core v$VERSION -- nuclear disk sanitization (Linux rescue side)

Usage:
  $PROG                                Enumerate disks and exit (dry-run, default)
  $PROG --dry-run | --whatif           Same as above (explicit)
  $PROG --nuke <id>                    Arm destruction of disk <id> (interactive)
  $PROG --nuke <id> --log-dir <dir>    Override the audit-log directory
  $PROG --nuke <id> --override-boot-protection
                                       Allow a boot/USB disk as the target
                                       (logged WARNING; confirmation still
                                       required twice)
  $PROG --nuke <id> --no-countdown     Skip the final 5s abort window (VM tests)
  $PROG --help                         This help

<id>: row number from the enumeration table, /dev node, or the disk's exact
      serial number. Wildcards are never resolved; ambiguous identifiers fail
      closed.

RULES: no flags = enumerate only. No default target. Boot disks and USB
disks are refused unless --override-boot-protection. Arming requires typing
the target disk's serial (or device path) TWICE on a real console --
redirected stdin can never arm a wipe. Full audit log is written to the log
directory. VM-ONLY TESTING. NEVER test destructive paths on bare metal.
EOF
}

#===============================================================================
# enumeration
#===============================================================================
# parent_disk <partition-or-disk> -> /dev/<disk>
parent_disk() {
    local node="$1" pk
    pk="$(lsblk -ndo PKNAME "$node" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then echo "/dev/$pk"; return; fi
    # sed fallback: strip trailing partition digits. The nvme/mmcblk/loop
    # substitutions must be tried FIRST and must not fall through to the
    # generic one (`t` skips to end of script after the first success).
    local base
    base="$(basename "$node")"
    base="$(echo "$base" | sed -E \
        -e 's/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(mmcblk[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(loop[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^([a-zA-Z]+)[0-9]+$/\1/')"
    echo "/dev/$base"
}

# detect_protected: a disk is PROTECTED ("boot-device") when the kernel
# cmdline names it as the root/boot device, or when ANY of its partitions is
# currently mounted. A live disk can never be a nuke target.
detect_protected() {
    local -a prot=()
    local cmdline tok rootdev
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    for tok in $cmdline; do
        case "$tok" in
            root=/dev/*|BOOT_IMAGE=/dev/*)
                rootdev="${tok#*=}"; rootdev="${rootdev%% *}"
                prot+=("$(parent_disk "$rootdev")")
                ;;
        esac
    done
    local disk mp
    while IFS= read -r disk; do
        while IFS= read -r mp; do
            if [[ -n "$mp" ]]; then prot+=("$disk"); break; fi
        done < <(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null | grep -v '^$' || true)
    done < <(lsblk -dnr -o PATH -e 7,11 2>/dev/null || true)  # skip loop(7), sr(11)
    printf '%s\n' "${prot[@]}"
}

classify_media() {  # classify_media <tran> <rota> -> MEDIA label
    local tran="$1" rota="$2"
    case "$tran" in
        nvme) echo "NVMe SSD" ;;
        sata) [[ "$rota" == "1" ]] && echo "HDD" || echo "SATA SSD" ;;
        usb)  [[ "$rota" == "1" ]] && echo "USB HDD" || echo "USB flash/SSD" ;;
        virtio|xen) echo "Virtual disk" ;;
        *)    echo "Unknown ($tran)" ;;
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
    local -a prot
    mapfile -t prot < <(detect_protected)
    local isprot p
    D_COUNT=0
    local line dev model serial size tran rm rota type media flags reason
    while IFS= read -r line; do
        # shellcheck disable=SC1091
        eval "$line"   # sets NAME MODEL SERIAL SIZE TRAN RM ROTA TYPE
        [[ "${TYPE:-}" == "disk" ]] || continue
        # NOTE: PATH is deliberately NOT in the column list -- eval would turn
        # PATH=/dev/... into a shell assignment and clobber the real PATH.
        # The device node is rebuilt from NAME instead.
        dev="/dev/${NAME:?}"
        [[ -z "$dev" ]] && continue
        model="${MODEL:-unknown}"
        serial="${SERIAL:-unknown}"
        media="$(classify_media "${TRAN:-?}" "${ROTA:-0}")"
        flags=""; reason=""
        isprot=0
        for p in "${prot[@]}"; do [[ "$p" == "$dev" ]] && { isprot=1; break; }; done
        if (( isprot == 1 )); then
            flags="BOOT-USB"; reason="boot-device"
        elif [[ "${TRAN:-}" == "usb" || "${RM:-0}" == "1" ]]; then
            flags="USB"; reason="usb-device"
        fi
        D_DEV+=("$dev"); D_MODEL+=("$model"); D_SERIAL+=("$serial")
        D_SIZE+=("$SIZE"); D_TRAN+=("${TRAN:-?}"); D_MEDIA+=("$media")
        D_FLAGS+=("$flags"); D_PROT+=("$reason")
        D_COUNT=$((D_COUNT+1))
    done < <(lsblk -P -b -d -o NAME,MODEL,SERIAL,SIZE,TRAN,RM,ROTA,TYPE -e 7,11 2>/dev/null || true)

    # Second pass: flag non-unique serials. A duplicated serial means typed
    # confirmation can no longer identify ONE disk -- identity failure, and
    # arming is refused no matter how the disk was selected.
    local i s
    for (( i=0; i<D_COUNT; i++ )); do
        s="${D_SERIAL[$i]}"
        [[ -z "$s" || "$s" == "unknown" ]] && continue
        if (( $(serial_count "$s") > 1 )); then
            if [[ -z "${D_FLAGS[$i]}" ]]; then D_FLAGS[$i]="DUP-SERIAL";
            else D_FLAGS[$i]="${D_FLAGS[$i]} DUP-SERIAL"; fi
        fi
    done

    echo "======================================================================"
    echo " PHOENIX NUKE CORE -- disk enumeration ($(ts))"
    echo "======================================================================"
    printf "%-3s %-12s %-28s %-22s %-9s %-6s %-14s %s\n" \
        "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "BUS" "MEDIA" "FLAGS"
    echo "----------------------------------------------------------------------"
    for (( i=0; i<D_COUNT; i++ )); do
        printf "%-3d %-12s %-28.28s %-22.22s %-9s %-6s %-14s %s\n" \
            "$((i+1))" "${D_DEV[$i]}" "${D_MODEL[$i]}" "${D_SERIAL[$i]}" \
            "$(human_size "${D_SIZE[$i]}")" "${D_TRAN[$i]}" "${D_MEDIA[$i]}" "${D_FLAGS[$i]}"
    done
    echo "----------------------------------------------------------------------"
    echo " $D_COUNT disk(s) detected. No --nuke given: dry-run, nothing destroyed."
    echo "======================================================================"
}

# serial_count <serial> -> number of enumerated disks reporting that serial
serial_count() {
    local s="$1" i n=0
    for (( i=0; i<D_COUNT; i++ )); do
        [[ "${D_SERIAL[$i]}" == "$s" ]] && n=$((n+1))
    done
    echo "$n"
}

# resolve_id <id> -> index into D_* arrays, or exit 1 (fail closed)
resolve_id() {
    local id="$1" i
    # Wildcards are never resolved -- not even to check "what would match".
    case "$id" in
        *[\*\?\[]*)
            echo "[$PROG] REFUSED: identifier '$id' contains wildcard characters -- wildcards are never resolved." >&2
            return 1 ;;
    esac
    # Row number.
    if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= D_COUNT )); then
        echo $((id-1)); return 0
    fi
    # Serial: must match EXACTLY ONE disk -- duplicated serials are an
    # ambiguity refusal, never first-match-wins.
    local first=-1 matches=0
    for (( i=0; i<D_COUNT; i++ )); do
        if [[ "${D_SERIAL[$i]}" == "$id" ]]; then
            matches=$((matches+1))
            (( first == -1 )) && first=$i
        fi
    done
    if (( matches > 1 )); then
        echo "[$PROG] REFUSED: identifier '$id' is ambiguous -- $matches disks report serial '$id'." >&2
        echo "[$PROG] Use a row number or /dev node instead; the serial alone" >&2
        echo "[$PROG] cannot identify one disk." >&2
        return 1
    fi
    if (( matches == 1 )); then echo "$first"; return 0; fi
    # /dev node: exact, literal match.
    for (( i=0; i<D_COUNT; i++ )); do
        if [[ "${D_DEV[$i]}" == "$id" ]]; then echo "$i"; return 0; fi
    done
    echo "[$PROG] REFUSED: no disk matches identifier '$id'." >&2
    return 1
}

# typed_confirm_twice <serial> <dev> -> 0 when the operator types the exact
# serial (or the exact /dev path) TWICE on a REAL terminal. Piped or
# scripted stdin is refused structurally: `echo $serial | ...` can never arm
# a wipe. A mismatch on either prompt aborts (exit path 2 via caller).
typed_confirm_twice() {
    local serial="$1" dev="$2"
    if [[ ! -t 0 ]]; then
        audit "REFUSED" "dev=$dev" "serial=$serial" "reason='stdin-redirected'"
        echo "[$PROG] REFUSED: confirmation stdin is not a terminal -- piped or scripted input cannot arm a wipe." >&2
        return 1
    fi
    local t1 t2 ok1=0 ok2=0
    read -r -p "Type the disk serial '$serial' to ARM (attempt 1 of 2): " t1
    read -r -p "Type the disk serial '$serial' AGAIN to confirm destruction (attempt 2 of 2): " t2
    t1="$(echo "$t1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    t2="$(echo "$t2" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "$t1" == "$serial" || "$t1" == "$dev" ]] && ok1=1
    [[ "$t2" == "$serial" || "$t2" == "$dev" ]] && ok2=1
    if (( ok1 == 1 && ok2 == 1 )); then
        audit "CONFIRMED" "dev=$dev" "serial=$serial" "typed1='$t1'" "typed2='$t2'"
        return 0
    fi
    audit "ABORTED" "dev=$dev" "serial=$serial" "typed1='$t1'" "typed2='$t2'"
    return 1
}

# do_zero_fill <dev> -- full-device overwrite. Logs the flash-media caveat.
do_zero_fill() {
    local dev="$1" media="$2"
    case "$media" in
        *SSD*|*NVMe*|*flash*)
            audit "WARNING" "dev=$dev" "reason='flash-media-zero-fill-is-Clear-at-best'"
            echo "[$PROG] WARNING: $media -- host-side zero-fill is NIST 800-88 Clear at best on flash media." >&2
            echo "[$PROG] WARNING: for firmware Purge on SSD/NVMe use tools/Invoke-Nuke.sh." >&2
            ;;
    esac
    audit "EXECUTING" "dev=$dev" "method='dd-zero'"
    local t0 t1
    t0="$(date +%s)"
    dd if=/dev/zero of="$dev" bs=4M status=progress conv=fsync 2>>"$AUDITFILE" || {
        audit "FAILED" "dev=$dev" "reason='dd-exit-nonzero'"
        die "dd failed on $dev -- see audit log."
    }
    t1="$(date +%s)"
    audit "COMPLETE" "dev=$dev" "elapsed_s=$((t1-t0))"
}

#===============================================================================
# main
#===============================================================================
main() {
    while (( $# > 0 )); do
        case "$1" in
            --nuke)      NUKE_ID="${2:?--nuke needs a disk id}"; shift 2 ;;
            --log-dir)   LOG_DIR="${2:?--log-dir needs a path}"; shift 2 ;;
            --override-boot-protection) OVERRIDE_BOOT_PROT=1; shift ;;
            --no-countdown) NO_COUNTDOWN=1; shift ;;
            --dry-run)   DRYRUN=1; shift ;;
            --whatif)    DRYRUN=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "Unknown option: $1 (see --help)" ;;
        esac
    done

    [[ $EUID -eq 0 ]] || die "Must run as root (block-device access required)."
    command -v lsblk >/dev/null 2>&1 || die "lsblk not found -- boot image is incomplete."

    # Audit log location.
    local dir="${LOG_DIR:-./phoenix-logs}"
    mkdir -p "$dir" || die "Cannot create log dir $dir"
    AUDITFILE="$dir/phoenix-nuke-audit-$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$AUDITFILE" || die "Cannot write audit file $AUDITFILE"

    enumerate

    if [[ -z "$NUKE_ID" || $DRYRUN -eq 1 ]]; then
        # Dry-run default: enumerate and exit. Nothing armed, nothing logged
        # beyond the enumeration audit record.
        local list="" i
        for (( i=0; i<D_COUNT; i++ )); do
            list="$list${D_DEV[$i]}:${D_SERIAL[$i]},"
        done
        audit "ENUMERATE_DRYRUN" "disks=$D_COUNT" "list='${list%,}'"
        exit 0
    fi

    # --- resolve the target: exact match or fail closed ---
    local idx
    if ! idx="$(resolve_id "$NUKE_ID")"; then
        audit "REFUSED" "id='$NUKE_ID'" "reason='unresolved-id'"
        die "No disk matches identifier '$NUKE_ID'."
    fi
    local dev="${D_DEV[$idx]}" model="${D_MODEL[$idx]}" serial="${D_SERIAL[$idx]}"
    local size="${D_SIZE[$idx]}" tran="${D_TRAN[$idx]}" media="${D_MEDIA[$idx]}"
    local prot="${D_PROT[$idx]}"

    # --- boot/USB self-protection (heuristic; explicit override only) ---
    if [[ -n "$prot" && $OVERRIDE_BOOT_PROT -eq 0 ]]; then
        audit "REFUSED" "dev=$dev" "serial=$serial" "model='$model'" \
              "size_bytes=$size" "reason='$prot'"
        die "REFUSED: $dev ($serial) is a ${prot//-/ } and is self-protected. Re-run with --override-boot-protection to proceed anyway."
    fi
    if [[ -n "$prot" ]]; then
        audit "WARNING" "dev=$dev" "serial=$serial" \
              "reason='boot-protection-overridden'" "was='$prot'"
        echo "[$PROG] WARNING: boot/USB self-protection OVERRIDDEN for $dev." >&2
    fi

    # --- structural refusals: identity first (fail fast on ambiguity),
    # --- then the device must be identifiable at all ---
    # Duplicated serials: typed confirmation cannot prove WHICH disk was
    # meant -- identity failure, refused no matter how the disk was selected.
    if [[ "$serial" != "unknown" && -n "$serial" ]] && (( $(serial_count "$serial") > 1 )); then
        audit "REFUSED" "dev=$dev" "serial=$serial" "reason='dup-serial'"
        die "REFUSED: serial '$serial' is reported by multiple disks -- identity ambiguous. Aborting."
    fi
    if [[ "$serial" == "unknown" || -z "$serial" ]]; then
        audit "REFUSED" "dev=$dev" "reason='no-serial'"
        die "REFUSED: $dev reports no serial number -- cannot satisfy typed confirmation. Aborting."
    fi

    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!  YOU ARE ABOUT TO IRREVERSIBLY DESTROY ALL DATA ON THIS DISK     !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  Device : $dev"
    echo "  Model  : $model"
    echo "  Serial : $serial"
    echo "  Size   : $(human_size "$size")"
    echo "  Media  : $media  (bus: $tran)"
    echo "  Method : dd if=/dev/zero (full-device zero-fill)"
    echo ""
    echo "  This is NOT recoverable. There is no undo."
    echo ""

    # --- double-typed confirmation, real console only ---
    if ! typed_confirm_twice "$serial" "$dev"; then
        echo "Aborted. Confirmation did not match on both prompts. Nothing was destroyed."
        exit 2
    fi
    echo "CONFIRMED twice -- destruction ARMED."

    # --- block-device sanity check, fresh and as late as possible: the
    # --- target must still be a real block device right before execution ---
    if [[ ! -b "$dev" ]]; then
        audit "ABORTED" "dev=$dev" "serial=$serial" "reason='not-a-block-device'"
        die "REFUSED: $dev is not a block device."
    fi

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
        audit "ABORTED" "dev=$dev" "serial=$serial" "reason='identity-changed'" "now='$reserial'"
        die "Device identity changed mid-run ('$reserial' != '$serial'). Aborting -- hardware state is not trustworthy."
    fi

    do_zero_fill "$dev" "$media"

    echo ""
    echo "NUKE COMPLETE: $dev destroyed (full-device zero-fill)."
    echo "Audit: $AUDITFILE"
}

main "$@"
