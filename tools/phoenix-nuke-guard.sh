#!/usr/bin/env bash
#===============================================================================
# phoenix-nuke-guard.sh -- interactive NUKE arming guard (Phoenix boot menu)
#
# A front gate for the boot menu's NUKE path (menu order: Analyze / Backup /
# NUKE / Reinstall). It does NOT contain any destructive primitive. On
# success it hands a validated device path to the caller, which can exec the
# real nuke tool (tools/phoenix-nuke.sh) with it.
#
# SAFETY CONTRACT:
#   1. Dry-run is the DEFAULT: no flags (or --dry-run/--whatif) ONLY
#      enumerates disks, prints what an armed run would do, and exits 0.
#      Destruction is only *prepared* with --nuke -- and even then nothing
#      is destroyed here.
#   2. Explicit enumeration: a numbered table (device, model, serial, size,
#      bus, flags) is printed first. Enumeration uses the eval-free
#      lsblk -P parser from phoenix-nuke.sh (parse_lsblk_pairs): firmware
#      MODEL/SERIAL strings are untrusted input and must never execute --
#      hostile $() and quote payloads are displayed as data only.
#   3. Exact typed target: the operator must TYPE the exact device path
#      (e.g. /dev/sda). Row numbers, serials, prefixes, partial paths, and
#      wildcards (* ? [ ]) are NOT accepted -- fail closed on anything that
#      is not the full /dev path of exactly one enumerated disk.
#   4. Exact confirmation phrase: after the device path, the operator must
#      type the literal phrase `NUKE /dev/sda` (the /dev path echoed back).
#      Case-sensitive, exact match. Anything else aborts.
#   5. Best-effort boot/system refusal: disks backing / , /boot, /boot/efi
#      (via /proc/mounts) or named by the kernel cmdline root= are flagged
#      BOOT and structurally refused unless --override-boot-protection
#      (logged as a WARNING; the typed confirmations are still required).
#   6. Real terminal only: confirmation is refused when stdin is not a tty
#      -- piped or scripted input can never arm a wipe.
#   7. Audit record: every run appends timestamp, mode, and the
#      operator-confirmation evidence to a log file.
#
# USAGE:
#   phoenix-nuke-guard.sh                    enumerate only (dry-run, exit 0)
#   phoenix-nuke-guard.sh --dry-run|--whatif same (explicit)
#   phoenix-nuke-guard.sh --nuke             arm: prompt for exact /dev path
#                                            + exact "NUKE <dev>" phrase
#   phoenix-nuke-guard.sh --nuke --log-dir <dir>
#   phoenix-nuke-guard.sh --nuke --override-boot-protection
#   phoenix-nuke-guard.sh --nuke --exec <cmd> [args...]
#       after arming, exec the given command with the validated /dev path
#       appended (e.g. --exec /path/to/phoenix-nuke.sh --nuke)
#
# Exit codes: 0 = dry-run OK / armed-and-handed-off | 1 = error/refusal |
# 2 = aborted by the operator.
# VM-ONLY TESTING. NEVER test destructive paths on bare metal.
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"

# --- options -----------------------------------------------------------------
NUKE=0
OVERRIDE_BOOT_PROT=0
DRYRUN=0
LOG_DIR=""
EXEC=()          # --exec command + args; validated /dev path is appended

# --- state -------------------------------------------------------------------
declare -a D_DEV D_MODEL D_SERIAL D_SIZE D_TRAN D_FLAGS D_PROT
D_COUNT=0
AUDITFILE=""

usage() { cat <<EOF
$PROG $VERSION -- interactive NUKE arming guard for the Phoenix boot menu.

SAFETY RULES: dry-run is the default (enumerate only). With --nuke the
operator must TYPE the exact /dev path of the target disk, then TYPE the
exact confirmation phrase "NUKE /dev/sda". Boot/system disks (kernel
cmdline root=, or any disk hosting /, /boot, /boot/efi) are structurally
refused unless --override-boot-protection. Confirmation happens on a real
terminal only -- piped stdin is refused. Nothing is destroyed by this
script; --exec hands the validated path to the real nuke tool.

USAGE:
  $PROG                          enumerate only (dry-run)
  $PROG --dry-run | --whatif      same (explicit)
  $PROG --nuke                   arm interactively
  $PROG --nuke --exec <cmd> ...  exec <cmd> ... <validated-/dev-path>

Exit codes: 0 = dry-run/armed | 1 = error/refusal | 2 = operator abort.
VM-ONLY TESTING. NEVER test destructive paths on bare metal.
EOF
}

#===============================================================================
# audit
#===============================================================================
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# audit <mode> [key=value ...] -- one structured line to console AND audit file.
audit() {
    local mode="$1"; shift
    local line="[$(ts)] mode=$mode"
    local kv
    for kv in "$@"; do line="$line $kv"; done
    echo "$line"
    [[ -n "$AUDITFILE" ]] && echo "$line" >> "$AUDITFILE"
}

#===============================================================================
# enumeration (eval-free lsblk -P parsing -- firmware strings are data only)
#===============================================================================
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

human_size() {
    local b="$1"
    if (( b >= 1000000000000 )); then printf "%d TB" $(( (b + 500000000000) / 1000000000000 ))
    elif (( b >= 1000000000 )); then printf "%d GB" $(( (b + 500000000) / 1000000000 ))
    elif (( b >= 1000000 )); then printf "%d MB" $(( (b + 500000) / 1000000 ))
    else printf "%d B" "$b"; fi
}

# parent_disk <partition-or-disk> -> /dev/<disk> (same algorithm as
# phoenix-nuke.sh: lsblk PKNAME first, sed fallback for partition suffixes)
parent_disk() {
    local node="$1" pk
    pk="$(lsblk -ndo PKNAME "$node" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then echo "/dev/$pk"; return; fi
    local base
    base="$(basename "$node")"
    base="$(echo "$base" | sed -E \
        -e 's/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(mmcblk[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^(loop[0-9]+)p[0-9]+$/\1/; t' \
        -e 's/^([a-zA-Z]+)[0-9]+$/\1/')"
    echo "/dev/$base"
}

# /proc overrides exist ONLY so tests can run deterministically; they are
# never set on the boot image.
PROC_MOUNTS="${PHOENIX_GUARD_PROC_MOUNTS:-/proc/mounts}"
PROC_CMDLINE="${PHOENIX_GUARD_PROC_CMDLINE:-/proc/cmdline}"

# detect_boot_disks -- print /dev/<disk> lines for disks that are
# best-effort system/boot disks: kernel cmdline root=/dev/X, or a disk with
# a partition mounted at /, /boot, /boot/efi.
detect_boot_disks() {
    local -a prot=()
    local cmdline tok rootdev
    cmdline="$(cat "$PROC_CMDLINE" 2>/dev/null || true)"
    for tok in $cmdline; do
        case "$tok" in
            root=/dev/*|BOOT_IMAGE=/dev/*)
                rootdev="${tok#*=}"; rootdev="${rootdev%% *}"
                prot+=("$(parent_disk "$rootdev")")
                ;;
        esac
    done
    local dev mp disk
    while read -r dev mp _rest; do
        case "$mp" in
            /|/boot|/boot/efi)
                disk="$(parent_disk "$dev")"
                prot+=("$disk")
                ;;
        esac
    done < <(cat "$PROC_MOUNTS" 2>/dev/null || true)
    printf '%s\n' "${prot[@]}" | sort -u
}

# disk_mounted <dev> -- true if ANY partition of the disk is mounted
disk_mounted() {
    local dev="$1" mp
    while read -r mp; do
        [[ -n "$mp" ]] && return 0
    done < <(lsblk -nr -o MOUNTPOINTS "$dev" 2>/dev/null | grep -v '^$' || true)
    return 1
}

# enumerate_disks -- fill D_* arrays; sets D_COUNT. Skips loop/ram devices.
enumerate_disks() {
    D_DEV=(); D_MODEL=(); D_SERIAL=(); D_SIZE=(); D_TRAN=(); D_FLAGS=(); D_PROT=()
    D_COUNT=0
    local line
    local bootlist
    bootlist="$(detect_boot_disks)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_lsblk_pairs "$line"
        [[ "${LP[TYPE]:-}" == "disk" ]] || continue
        local name="${LP[NAME]:-}"
        [[ -z "$name" ]] && continue
        case "$name" in loop*|ram*|md*|dm-*) continue ;; esac
        local dev="/dev/$name"
        local flags="" prot=0
        if grep -qxF "$dev" <<<"$bootlist"; then flags="BOOT "; prot=1; fi
        if disk_mounted "$dev"; then flags="${flags}MOUNTED "; prot=1; fi
        case "${LP[TRAN]:-}" in usb) flags="${flags}USB " ;; esac
        [[ "${LP[RM]:-0}" == "1" ]] && flags="${flags}REMOVABLE "
        D_DEV+=("$dev"); D_MODEL+=("${LP[MODEL]:-(unknown)}")
        D_SERIAL+=("${LP[SERIAL]:-(unknown)}")
        D_SIZE+=("${LP[SIZE]:-0}"); D_TRAN+=("${LP[TRAN]:-?}")
        D_FLAGS+=("$flags"); D_PROT+=("$prot")
        D_COUNT=$((D_COUNT+1))
    done < <(lsblk -P -b -d -o NAME,MODEL,SERIAL,SIZE,TRAN,RM,ROTA,TYPE 2>/dev/null || true)
}

print_table() {
    printf '%-3s %-12s %-20s %-14s %-9s %-8s %s\n' "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "BUS" "FLAGS"
    local i
    for ((i=0; i<D_COUNT; i++)); do
        printf '%-3s %-12s %-20.20s %-14.14s %-9s %-8s %s\n' \
            "$i" "${D_DEV[$i]}" "${D_MODEL[$i]}" "${D_SERIAL[$i]}" \
            "$(human_size "${D_SIZE[$i]}")" "${D_TRAN[$i]}" "${D_FLAGS[$i]}"
    done
}

#===============================================================================
# arming gates
#===============================================================================
# resolve_exact_dev <input> -- the operator must type the FULL /dev path of
# exactly one enumerated disk. Row numbers, serials, prefixes, partial paths
# and globs are refused (fail closed). Echoes the matched index.
resolve_exact_dev() {
    local input="$1"
    # shape gate: must look like /dev/<basename>, no globs, no whitespace
    case "$input" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    case "$input" in
        *[\*\?\[]* | *[[:space:]]*) return 1 ;;
    esac
    local i
    for ((i=0; i<D_COUNT; i++)); do
        if [[ "${D_DEV[$i]}" == "$input" ]]; then
            echo "$i"; return 0
        fi
    done
    return 1
}

# typed_confirm <prompt> <expected> -- read one line from the terminal and
# require an EXACT (case-sensitive, no extra whitespace) match.
typed_confirm() {
    local prompt="$1" expected="$2" got
    if [[ ! -t 0 ]]; then
        audit ABORTED reason="piped-stdin-refused"
        echo "REFUSED: confirmation requires a real terminal (stdin is not a tty)." >&2
        return 1
    fi
    printf '%s ' "$prompt" >&2
    IFS= read -r got || { audit ABORTED reason="eof-on-prompt"; return 1; }
    [[ "$got" == "$expected" ]]
}

#===============================================================================
# main
#===============================================================================
main() {
    while (($# > 0)); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --nuke) NUKE=1 ;;
            --dry-run|--whatif) DRYRUN=1 ;;
            --override-boot-protection) OVERRIDE_BOOT_PROT=1 ;;
            --log-dir) LOG_DIR="$2"; shift ;;
            --exec) shift; EXEC=("$@"); break ;;
            *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
        shift
    done

    mkdir -p "${LOG_DIR:-./phoenix-logs}" 2>/dev/null || true
    LOG_DIR="${LOG_DIR:-./phoenix-logs}"
    AUDITFILE="$LOG_DIR/nuke-guard.log"
    touch "$AUDITFILE" 2>/dev/null || AUDITFILE=""

    enumerate_disks
    audit ENUMERATE disks="$D_COUNT" mode="$([ "$NUKE" -eq 1 ] && echo arm || echo dry-run)"

    echo "=== Phoenix NUKE guard -- candidate disks ==="
    print_table
    echo

    if [[ "$NUKE" -ne 1 ]]; then
        # ---- dry-run: describe what an armed run would require ---------------
        echo "--dry-run: nothing will be touched. An armed run would require the"
        echo "operator to (1) type the EXACT device path of the target disk"
        echo "(row numbers, serials, prefixes and wildcards are refused), and"
        echo "(2) type the exact confirmation phrase \`NUKE <dev>\` on a real"
        echo "terminal. Disks flagged BOOT are refused unless"
        echo "--override-boot-protection."
        audit DRYRUN_PLAN
        exit 0
    fi

    # ---- arming path ---------------------------------------------------------
    echo "!!! ARMING -- nothing is destroyed yet; this gate validates intent."
    local typed
    if ! typed="$(prompt_exact_dev)"; then
        audit REFUSED reason="target-entry-refused"
        exit 1
    fi
    local idx
    if ! idx="$(resolve_exact_dev "$typed")"; then
        audit REFUSED reason="device-path-not-exact-match"
        echo "REFUSED: you must type the EXACT /dev path of ONE enumerated disk." >&2
        echo "Partial paths, row numbers, serials and wildcards are refused." >&2
        exit 1
    fi

    local dev="${D_DEV[$idx]}"
    if [[ "${D_PROT[$idx]}" -eq 1 && "$OVERRIDE_BOOT_PROT" -eq 0 ]]; then
        audit REFUSED target="$dev" reason="protected-disk" flags="${D_FLAGS[$idx]}"
        echo "REFUSED: $dev is flagged as a boot/system or mounted disk (${D_FLAGS[$idx]})." >&2
        echo "Refusing to arm. Use --override-boot-protection only if you are" >&2
        echo "certain this is the disk you want to destroy." >&2
        exit 1
    fi
    if [[ "${D_PROT[$idx]}" -eq 1 && "$OVERRIDE_BOOT_PROT" -eq 1 ]]; then
        audit WARNING target="$dev" reason="boot-protection-overridden"
        echo "WARNING: boot protection overridden for $dev -- logged." >&2
    fi

    local phrase="NUKE $dev"
    if ! typed_confirm "Type the exact confirmation phrase (case-sensitive):" "$phrase"; then
        audit ABORTED target="$dev" reason="confirmation-phrase-mismatch"
        echo "ABORTED: confirmation phrase did not match exactly. Expected: $phrase" >&2
        exit 2
    fi

    audit CONFIRMED target="$dev" operator_evidence="typed-exact-dev+phrase"
    echo "ARMED target=$dev"
    if ((${#EXEC[@]} > 0)); then
        "${EXEC[@]}" "$dev"
    fi
    exit 0
}

# prompt_exact_dev -- ask for the exact device path on a real terminal.
prompt_exact_dev() {
    if [[ ! -t 0 ]]; then
        echo "REFUSED: target entry requires a real terminal (stdin is not a tty)." >&2
        return 1
    fi
    local got
    printf 'Type the EXACT device path of the disk to destroy (e.g. /dev/sda): ' >&2
    IFS= read -r got || return 1
    printf '%s' "$got"
}

main "$@"
