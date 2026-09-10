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
#   2. Explicit enumeration: numbered candidate table (device, model, serial,
#      size, bus, media, ARM-CODE, flags) is printed first. Disks declared
#      protected in phoenix-config.json are EXCLUDED from the table and
#      named in a hidden summary instead -- they are never candidates.
#   3. Never auto-select: no default target, ever. <id> must be a row
#      number, a /dev node, or the exact serial. Wildcards (* ? [ ]) are
#      NEVER resolved -- fail closed. An identifier matching more than one
#      disk (e.g. duplicated serials) is an ambiguity refusal, never
#      first-match-wins.
#   4. Config-protected disks are EXCLUDED, not warned: a serial or /dev
#      path listed in phoenix-config.json -> "nuke": { "protectedDisks":
#      [...] } never becomes a candidate row, is named in a hidden summary,
#      and cannot be armed -- not even with --override-boot-protection.
#      Use it for the backup vault, the Castle drive, anything irreplaceable.
#      (pdi_is_protected from tools/lib/phoenix-disk-inventory.sh.)
#   5. Boot/USB self-protection: the boot disk (kernel cmdline root, or any
#      disk with mounted partitions) and USB-attached disks are refused
#      structurally UNLESS --override-boot-protection is given. The override
#      is logged as a WARNING and still requires the typed confirmations.
#   6. Typed confirmation, TWO stages, both on a real terminal:
#      (a) ARM-CODE transcription challenge (docs/NUKE-INTERLOCKS.md §2/§3):
#          the operator types the target's 6-char ARM-CODE -- a deterministic
#          sha256 over serial|model|size-bytes -- or its exact serial. This
#          binds the typed identity to the serial AND the displayed size
#          shown in the enumeration row: the operator cannot arm a disk they
#          did not read deliberately. Piped input refused ([ -t 0 ]).
#      (b) Double-typed serial confirmation (two attempts, serial or device
#          path, exact match). A mismatch on EITHER prompt aborts.
#   7. Audit record: every run writes timestamp, disk id, mode, and the
#      operator-confirmation evidence to a log file.
#   8. Final abort window: 5-second countdown after arming (Ctrl-C aborts;
#      --no-countdown only for VM tests).
#   9. Image-proof gate (runbook invariant 1: verified image or no wipe):
#      --nuke refuses unless --image-proof <file> names a VALID proof
#      manifest (format phoenix-image-proof/1, verified=YES, 64-hex sha256,
#      positive image_size_bytes, source_serial matching the nuke target --
#      written in the Backup phase with tools/New-ImageProof.sh). This gate
#      runs FIRST, before every other structural check. --skip-image-gate
#      exists for true emergencies only: it demands the typed phrase
#      'NUKE WITHOUT BACKUP' on a real console and is audit-logged.
#      Mirrors tools/Invoke-Nuke.sh check_image_proof/typed_skip_image_gate.
#      KNOWN GAP: the Windows twin Invoke-PhoenixNuke.ps1 does not have this
#      gate yet -- contract parity work item for a follow-up run.
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
#   phoenix-nuke.sh --image-proof <f> --nuke <id> arm only when <f> is a valid
#                                    image-proof manifest (verified=YES,
#                                    source_serial bound to the target)
#                                    -- REQUIRED unless --skip-image-gate
#   phoenix-nuke.sh --skip-image-gate --nuke <id> emergency: arm with NO
#                                    verified image (typed 'NUKE WITHOUT
#                                    BACKUP' on a real console, audit-logged)
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

VERSION="0.2.0"
PROG="$(basename "$0")"

# --- canonical interlock library ---------------------------------------------
# tools/lib/phoenix-disk-inventory.sh is the NUKE-path gate library
# (docs/NUKE-INTERLOCKS.md). This script sources it for:
#   pdi_arm_code       deterministic ARM-CODE transcription challenge
#                        (sha256 of "phoenix-nuke-arm|<serial>|<model>|<size>")
#   pdi_is_protected   config-declared protected-disk exclusions
#                        (phoenix-config.json -> "nuke": { "protectedDisks": [] })
#   pdi_confirm_armed  the TTY-only typed arm-code confirmation gate
# The library contains NO destructive primitive -- read-only helpers.
_PDI_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/phoenix-disk-inventory.sh"
if [[ -f "$_PDI_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$_PDI_LIB"
else
    echo "[$PROG] FATAL: cannot find tools/lib/phoenix-disk-inventory.sh" >&2
    exit 1
fi
unset _PDI_LIB

# --- options -----------------------------------------------------------------
NUKE_ID=""               # disk identifier selected by the operator
LOG_DIR=""               # default: ./phoenix-logs
OVERRIDE_BOOT_PROT=0     # --override-boot-protection
NO_COUNTDOWN=0
DRYRUN=0
IMAGE_PROOF=""           # path to a phoenix-image-proof manifest (gate: required)
SKIP_IMAGE_GATE=0        # emergency escape hatch; needs TTY-typed phrase

# --- state -------------------------------------------------------------------
AUDITFILE=""
declare -a D_DEV D_MODEL D_SERIAL D_SIZE D_TRAN D_MEDIA D_FLAGS D_PROT D_CODE
D_COUNT=0
# parallel arrays: disks excluded from candidacy (never rows, never armable)
declare -a D_HIDDEN_DEV D_HIDDEN_WHY
D_HIDDEN_COUNT=0

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
  $PROG --image-proof <f> --nuke <id>  Arm only when <f> is a valid image-proof
                                       manifest (tools/New-ImageProof.sh) bound
                                       to the target's serial. REQUIRED unless
                                       --skip-image-gate is given.
  $PROG --skip-image-gate --nuke <id>  Emergency only: arm with NO verified image
                                       on record. Requires typing
                                       'NUKE WITHOUT BACKUP' on a real console.
  $PROG --nuke <id> --override-boot-protection
                                       Allow a boot/USB disk as the target
                                       (logged WARNING; confirmation still
                                       required twice)
  $PROG --nuke <id> --no-countdown     Skip the final 5s abort window (VM tests)
  $PROG --help                         This help

<id>: row number from the enumeration table, /dev node, or the disk's exact
      serial number. Wildcards are never resolved; ambiguous identifiers fail
      closed.

RULES: no flags = enumerate only. No default target. --nuke requires
--image-proof <file> (runbook invariant 1: never wipe before a VERIFIED
image exists) -- this gate runs before every other check. Disks declared
protected in phoenix-config.json are excluded from candidacy entirely and
can never be armed. Boot disks and USB disks are refused unless
--override-boot-protection. Arming requires typing the target disk's
ARM-CODE (or exact serial) once, then its serial (or device path) TWICE --
all on a real console; redirected stdin can never arm a wipe. Full audit
log is written to the log directory. VM-ONLY TESTING. NEVER test
destructive paths on bare metal.
EOF
}

#===============================================================================
# enumeration
#===============================================================================
# parse_lsblk_pairs <line> -- fill the LP assoc array with KEY=VALUE pairs
# from one `lsblk -P` output line. This parser NEVER evals: model/serial
# strings come from device firmware, and a USB device can report arbitrary
# bytes -- a hostile MODEL='Evil"; $(rm -rf /); echo "' must parse as data,
# never execute. Handles util-linux -P escaping (\" and \\) on the way in.
declare -A LP
parse_lsblk_pairs() {
    local line="$1"
    LP=()
    while [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=\"(([^\"\\]|\\.)*)\"(.*)$ ]]; do
        local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        line="${BASH_REMATCH[4]}"
        # unescape util-linux -P sequences: \\ -> \ first, then \" -> "
        val="${val//\\\\/\\}"
        val="${val//\\\"/\"}"
        LP["$key"]="$val"
    done
}

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
    D_HIDDEN_COUNT=0
    D_HIDDEN_DEV=(); D_HIDDEN_WHY=()
    local line dev model serial size tran rm rota type media flags reason
    while IFS= read -r line; do
        # Parse the lsblk -P line with the eval-free parser. Model/serial
        # values come from device firmware and are UNTRUSTED input --
        # parsing them with `eval` would let a hostile USB device execute
        # arbitrary shell. parse_lsblk_pairs extracts KEY="VALUE" pairs
        # as pure data.
        parse_lsblk_pairs "$line"
        [[ "${LP[TYPE]:-}" == "disk" ]] || continue
        # NOTE: the device node is rebuilt from NAME instead of trusting a
        # PATH column -- keeps $PATH (the shell's) out of firmware data.
        dev="/dev/${LP[NAME]:-}"
        [[ -z "${LP[NAME]:-}" ]] && continue
        model="${LP[MODEL]:-unknown}"
        serial="${LP[SERIAL]:-unknown}"
        # --- config-protected exclusion (structural, not advisory) ---
        # A disk named in phoenix-config.json -> "nuke": { "protectedDisks":
        # [...] } (by serial or /dev path) is EXCLUDED from candidacy: it
        # never becomes a numbered row, so no identifier can select it and
        # --override-boot-protection cannot reach it. (NUKE-INTERLOCKS.md §1)
        if pdi_is_protected "$dev" "$serial"; then
            D_HIDDEN_DEV+=("$dev")
            D_HIDDEN_WHY+=("PROTECTED(config)")
            D_HIDDEN_COUNT=$((D_HIDDEN_COUNT+1))
            continue
        fi
        media="$(classify_media "${LP[TRAN]:-?}" "${LP[ROTA]:-0}")"
        flags=""; reason=""
        isprot=0
        for p in "${prot[@]}"; do [[ "$p" == "$dev" ]] && { isprot=1; break; }; done
        if (( isprot == 1 )); then
            flags="BOOT-USB"; reason="boot-device"
        elif [[ "${LP[TRAN]:-}" == "usb" || "${LP[RM]:-0}" == "1" ]]; then
            flags="USB"; reason="usb-device"
        fi
        D_DEV+=("$dev"); D_MODEL+=("$model"); D_SERIAL+=("$serial")
        D_SIZE+=("${LP[SIZE]:-0}"); D_TRAN+=("${LP[TRAN]:-?}"); D_MEDIA+=("$media")
        D_FLAGS+=("$flags"); D_PROT+=("$reason")
        # Per-disk ARM-CODE: deterministic transcription challenge derived
        # from serial|model|size-bytes -- the typed token binds the serial
        # AND the displayed size shown in this row (NUKE-INTERLOCKS.md §2).
        D_CODE+=("$(pdi_arm_code "$serial" "$model" "${LP[SIZE]:-0}")")
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
    printf "%-3s %-12s %-28s %-22s %-9s %-6s %-14s %-8s %s\n" \
        "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "BUS" "MEDIA" "ARM-CODE" "FLAGS"
    echo "----------------------------------------------------------------------"
    for (( i=0; i<D_COUNT; i++ )); do
        printf "%-3d %-12s %-28.28s %-22.22s %-9s %-6s %-14s %-8s %s\n" \
            "$((i+1))" "${D_DEV[$i]}" "${D_MODEL[$i]}" "${D_SERIAL[$i]}" \
            "$(human_size "${D_SIZE[$i]}")" "${D_TRAN[$i]}" "${D_MEDIA[$i]}" \
            "${D_CODE[$i]}" "${D_FLAGS[$i]}"
    done
    echo "----------------------------------------------------------------------"
    if (( D_HIDDEN_COUNT > 0 )); then
        echo " Excluded from candidacy ($D_HIDDEN_COUNT) -- cannot be armed, not even"
        echo " with --override-boot-protection:"
        for (( i=0; i<D_HIDDEN_COUNT; i++ )); do
            echo "   hidden: ${D_HIDDEN_DEV[$i]} (${D_HIDDEN_WHY[$i]})"
        done
        echo "----------------------------------------------------------------------"
    fi
    echo " $D_COUNT candidate disk(s). No --nuke given: dry-run, nothing destroyed."
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

# check_image_proof <proof-file> <target-serial> -> 0 when the file is a
# VALID image-proof manifest (tools/New-ImageProof.sh) whose source_serial
# matches the nuke target. Refusal reasons go to stderr. A proof is the
# machine-readable form of runbook invariant 1 ("verified image or no wipe");
# verified=YES means the Backup phase's integrity check passed, and the
# serial binding stops a proof for disk A from arming a wipe of disk B.
# Mirrors tools/Invoke-Nuke.sh (bash parity).
check_image_proof() {
    local f="$1" target="$2"
    [[ -n "$f" && -f "$f" ]] || {
        echo "[$PROG] REFUSED: --image-proof '$f' is not a readable file." >&2
        return 1
    }
    local format="" verified="" sha256="" pserial="" psize="" line k v
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *"="* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            format)           format="$v" ;;
            verified)         verified="$v" ;;
            sha256)           sha256="$v" ;;
            source_serial)    pserial="$v" ;;
            image_size_bytes) psize="$v" ;;
        esac
    done < "$f"
    [[ "$format" == "phoenix-image-proof/1" ]] || {
        echo "[$PROG] REFUSED: proof '$f' has unknown/missing format '$format'" >&2
        echo "[$PROG] (want phoenix-image-proof/1). Write it with tools/New-ImageProof.sh." >&2
        return 1
    }
    [[ "$verified" == "YES" ]] || {
        echo "[$PROG] REFUSED: proof '$f' is not VERIFIED (verified='$verified')." >&2
        echo "[$PROG] The image must pass its integrity check before any wipe." >&2
        return 1
    }
    [[ "$sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo "[$PROG] REFUSED: proof '$f' lacks a valid 64-hex sha256 checksum." >&2
        return 1
    }
    [[ "$psize" =~ ^[0-9]+$ && "$psize" -gt 0 ]] || {
        echo "[$PROG] REFUSED: proof '$f' has no positive image_size_bytes." >&2
        return 1
    }
    [[ -n "$pserial" && "$pserial" != "unknown" ]] || {
        echo "[$PROG] REFUSED: proof '$f' names no source disk serial." >&2
        return 1
    }
    [[ "$pserial" == "$target" ]] || {
        echo "[$PROG] REFUSED: proof '$f' covers disk serial '$pserial'," >&2
        echo "[$PROG] but the nuke target is serial '$target'. A proof is bound" >&2
        echo "[$PROG] to the disk it images -- it cannot arm a different disk." >&2
        return 1
    }
    return 0
}

# typed_skip_image_gate -> 0 when the operator types the exact emergency
# phrase on a real TTY. Same structural rule as typed_confirm_twice: piped
# stdin can never skip the image gate.
typed_skip_image_gate() {
    if [[ ! -t 0 ]]; then
        echo "Refused: --skip-image-gate needs a real console (stdin is not a TTY)." >&2
        return 1
    fi
    local answer
    read -r -p "Type 'NUKE WITHOUT BACKUP' to wipe with NO verified image on record: " answer
    [[ "$answer" == "NUKE WITHOUT BACKUP" ]]
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
            --image-proof) IMAGE_PROOF="${2:?--image-proof needs a file}"; shift 2 ;;
            --skip-image-gate) SKIP_IMAGE_GATE=1; shift ;;
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

    # --- image-proof gate (runbook invariant 1: verified image or no wipe) ---
    # Runs FIRST, before every other structural check: no verified image on
    # record means no wipe, full stop.
    if [[ -n "$IMAGE_PROOF" ]]; then
        if ! check_image_proof "$IMAGE_PROOF" "$serial"; then
            audit "REFUSED" "dev=$dev" "serial=$serial" "reason='image-proof-gate'"
            die "Image-proof gate failed -- nothing was destroyed."
        fi
        audit "IMAGE-PROOF" "dev=$dev" "serial=$serial" "proof='$IMAGE_PROOF'"
    elif (( SKIP_IMAGE_GATE == 0 )); then
        audit "REFUSED" "dev=$dev" "serial=$serial" "reason='no-image-proof'"
        die "REFUSED: --nuke requires --image-proof <file> (a verified full-disk image manifest -- write one with tools/New-ImageProof.sh in the Backup phase). Runbook invariant 1: never wipe before a VERIFIED image exists. --skip-image-gate is for true emergencies only."
    else
        if ! typed_skip_image_gate; then
            audit "REFUSED" "dev=$dev" "serial=$serial" "reason='skip-image-gate-not-confirmed'"
            die "Image-gate skip not confirmed on a real console -- nothing was destroyed."
        fi
        audit "WARNING" "dev=$dev" "serial=$serial" \
              "reason='image-proof-gate-skipped'" "phrase='NUKE WITHOUT BACKUP'"
    fi

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

    # --- ARM-CODE transcription challenge (NUKE-INTERLOCKS.md §2/§3) ---
    # First typed gate, real console only. The code binds serial + model +
    # displayed size (sha256 of the identity tuple), so typing it proves the
    # operator read THIS enumeration row deliberately -- a disk that was not
    # looked at cannot be armed. Exact match, one attempt; failure aborts
    # (exit 2) before the double-typed serial confirmation is even offered.
    echo "  ARM-CODE for this disk: ${D_CODE[$idx]}"
    echo "  (shown in the table above; type it exactly -- it binds the serial"
    echo "   AND the size displayed for this disk)"
    echo ""
    if ! pdi_confirm_armed "$serial" "${D_CODE[$idx]}"; then
        audit "ABORTED" "dev=$dev" "serial=$serial" "reason='arm-code-mismatch'"
        echo "Aborted. The ARM-CODE (or exact serial) did not match. Nothing was destroyed."
        exit 2
    fi
    audit "ARM-CODE" "dev=$dev" "serial=$serial" "arm_code=${D_CODE[$idx]}"
    echo "ARM-CODE accepted -- transcription challenge passed."
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
