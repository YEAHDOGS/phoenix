#!/usr/bin/env bash
#===============================================================================
# tools/lib/phoenix-disk-inventory.sh -- candidate disk enumeration + arming
# confirmation for the Phoenix NUKE path.
#
# This is the canonical gate every NUKE-path tool should use. It answers two
# questions and nothing else:
#
#   1. WHICH disks are even eligible?  (pdi_enumerate)
#      Lists candidate disks with model/serial/size/bus and an ARM CODE, and
#      EXCLUDES -- never lists as candidates -- the booted Phoenix USB itself
#      and any disk marked protected in phoenix-config.json
#      ("nuke": { "protectedDisks": [...] }, matched by serial or /dev path).
#      A summary line names the hidden disks so the operator can see that the
#      exclusion logic actually fired.
#
#   2. DID a human deliberately arm one?  (pdi_confirm_armed)
#      The operator must TYPE the target's exact serial OR its per-disk ARM
#      CODE on a real terminal. No single-keystroke confirmation, no
#      default-yes, no piped/scripted input (stdin must be a TTY), and disks
#      with no readable serial can never be armed.
#
# This library contains NO destructive primitive -- it never invokes any
# wipe, erase, format, or raw-write tool. It only reads: lsblk,
# /proc/cmdline, /proc/mounts, and the config file.
# Source it; do not execute it:
#   source "$REPO/tools/lib/phoenix-disk-inventory.sh"
#   pdi_enumerate            # fills PDI_* arrays, sets PDI_COUNT
#   pdi_print_table          # numbered candidate table with ARM CODE column
#
# TEST HOOKS (never set on the boot image -- tests only):
#   PHOENIX_PDI_LSBLK_FILE     file with mock `lsblk -P -b -d` output lines
#   PHOENIX_PDI_MOUNTED_FILE   file with "/dev/<node> <mountpoint>" lines
#                              (mock for `lsblk -nrpo NAME,MOUNTPOINTS <dev>`)
#   PHOENIX_PDI_PROC_CMDLINE   mock for /proc/cmdline
#   PHOENIX_PDI_PROC_MOUNTS    mock for /proc/mounts
#   PHOENIX_PDI_CONFIG         path to phoenix-config.json (default: search
#                              ./phoenix-config.json, then alongside the boot
#                              USB mount -- see pdi_default_config)
#
# Design notes (see docs/NUKE-INTERLOCKS.md for the full interlock spec):
#   - Firmware MODEL/SERIAL strings are untrusted data: the lsblk -P parser
#     is eval-free (same technique as phoenix-nuke-guard.sh).
#   - ARM CODE derivation is deterministic per disk identity so tests and the
#     PowerShell twin (tools/Get-PhoenixDiskInventory.ps1) agree byte for
#     byte: first 6 uppercase hex chars of
#     sha256("phoenix-nuke-arm|<serial>|<model>|<size-bytes>").
#     It is a transcription challenge, not a secret -- its job is forcing the
#     operator to read the row deliberately, on a real console.
#===============================================================================

# Refuse direct execution: this file is a library.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "phoenix-disk-inventory.sh is a library -- source it, do not execute it." >&2
    exit 1
fi

# --- state -------------------------------------------------------------------
declare -a PDI_DEV PDI_MODEL PDI_SERIAL PDI_SIZE PDI_TRAN PDI_FLAGS PDI_CODE
PDI_COUNT=0
# parallel array: why each excluded disk was hidden (for the summary line)
declare -a PDI_HIDDEN_DEV PDI_HIDDEN_WHY
PDI_HIDDEN_COUNT=0

#===============================================================================
# small utilities
#===============================================================================
pdi_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

pdi_human_size() {
    local b="${1:-0}"
    if (( b >= 1000000000000 )); then printf "%.1f TB" "$(awk -v b="$b" 'BEGIN{printf "%.1f", b/1000000000000}')"
    elif (( b >= 1000000000 )); then printf "%.1f GB" "$(awk -v b="$b" 'BEGIN{printf "%.1f", b/1000000000}')"
    elif (( b >= 1000000 )); then printf "%.1f MB" "$(awk -v b="$b" 'BEGIN{printf "%.1f", b/1000000}')"
    else printf "%d B" "$b"; fi
}

#===============================================================================
# eval-free lsblk -P parser (firmware strings are data, never code)
#===============================================================================
declare -A PDI_LP
pdi_parse_pairs() {
    local line="$1"
    PDI_LP=()
    while [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=\"(([^\"\\]|\\.)*)\"(.*)$ ]]; do
        local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        line="${BASH_REMATCH[4]}"
        val="${val//\\\\/\\}"
        val="${val//\\\"/\"}"
        PDI_LP["$key"]="$val"
    done
}

#===============================================================================
# data sources (real on boot, mockable in tests)
#===============================================================================
pdi_proc_cmdline() { echo "${PHOENIX_PDI_PROC_CMDLINE:-/proc/cmdline}"; }
pdi_proc_mounts()  { echo "${PHOENIX_PDI_PROC_MOUNTS:-/proc/mounts}"; }

# pdi_lsblk_enum -- emit the `lsblk -P -b -d` enumeration lines
pdi_lsblk_enum() {
    if [[ -n "${PHOENIX_PDI_LSBLK_FILE:-}" ]]; then
        cat "$PHOENIX_PDI_LSBLK_FILE"
    else
        lsblk -P -b -d -o NAME,MODEL,SERIAL,SIZE,TRAN,RM,ROTA,TYPE 2>/dev/null || true
    fi
}

# pdi_lsblk_mounted <dev> -- emit "/dev/<node> <mountpoint>" lines for the
# disk and its descendants (real: lsblk on the device; mock: filtered file)
pdi_lsblk_mounted() {
    local dev="$1" node mp
    if [[ -n "${PHOENIX_PDI_MOUNTED_FILE:-}" ]]; then
        while read -r node mp; do
            [[ -z "$node" ]] && continue
            case "$node" in
                "$dev"|"$dev"[0-9]*|"$dev"p[0-9]*) printf '%s %s\n' "$node" "$mp" ;;
            esac
        done < "$PHOENIX_PDI_MOUNTED_FILE"
    else
        lsblk -nrpo NAME,MOUNTPOINTS "$dev" 2>/dev/null || true
    fi
}

# parent_disk <partition-or-disk> -> /dev/<disk>
pdi_parent_disk() {
    local node="$1" pk=""
    if [[ -z "${PHOENIX_PDI_LSBLK_FILE:-}" ]]; then
        pk="$(lsblk -ndo PKNAME "$node" 2>/dev/null || true)"
    fi
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

# pdi_detect_boot_disks -- print /dev/<disk> lines for best-effort system/boot
# disks: kernel cmdline root=/dev/X or BOOT_IMAGE=/dev/X, or a disk with a
# partition mounted at /, /boot, or /boot/efi.
pdi_detect_boot_disks() {
    local -a prot=()
    local cmdline tok rootdev
    cmdline="$(cat "$(pdi_proc_cmdline)" 2>/dev/null || true)"
    for tok in $cmdline; do
        case "$tok" in
            root=/dev/*|BOOT_IMAGE=/dev/*)
                rootdev="${tok#*=}"; rootdev="${rootdev%% *}"
                prot+=("$(pdi_parent_disk "$rootdev")")
                ;;
        esac
    done
    local dev mp rest
    while read -r dev mp rest; do
        case "$mp" in
            /|/boot|/boot/efi)
                prot+=("$(pdi_parent_disk "$dev")")
                ;;
        esac
    done < <(cat "$(pdi_proc_mounts)" 2>/dev/null || true)
    printf '%s\n' "${prot[@]}" | sort -u
}

# pdi_disk_mounted <dev> -- true if the disk itself or ANY descendant
# partition is mounted
pdi_disk_mounted() {
    local dev="$1" node mp rest
    while read -r node mp rest; do
        [[ -n "$mp" ]] && return 0
    done < <(pdi_lsblk_mounted "$dev")
    return 1
}

#===============================================================================
# config: nuke.protectedDisks
#===============================================================================
# pdi_default_config -- best-effort locate of phoenix-config.json
pdi_default_config() {
    if [[ -n "${PHOENIX_PDI_CONFIG:-}" ]]; then echo "$PHOENIX_PDI_CONFIG"; return; fi
    if [[ -f ./phoenix-config.json ]]; then echo "./phoenix-config.json"; return; fi
    echo ""
}

# pdi_protected_list -- print one protected identifier per line, from
#   "nuke": { "protectedDisks": [ "SERIAL1", "/dev/sdb", ... ] }
# Boot-side parsing is flat-JSON only (no jq on the boot image), mirroring
# the config writer. Missing file / missing key => no output (not an error).
pdi_protected_list() {
    local cfg="$1" block entry
    [[ -n "$cfg" && -f "$cfg" ]] || return 0
    block="$(grep -o '"protectedDisks"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$cfg" 2>/dev/null | head -1 || true)"
    [[ -n "$block" ]] || return 0
    while IFS= read -r entry; do
        entry="${entry//\"/}"               # strip JSON quotes
        [[ -n "$entry" ]] && printf '%s\n' "$entry"
    done < <(echo "$block" | grep -o '"[^"]*"' | tail -n +2)
}

# pdi_is_protected <dev> <serial> -- true if the config protects this disk
# (matched by serial OR /dev path; comparison is exact, case-sensitive)
pdi_is_protected() {
    local dev="$1" serial="$2" cfg entry
    cfg="$(pdi_default_config)"
    [[ -n "$cfg" ]] || return 1
    while IFS= read -r entry; do
        [[ "$entry" == "$serial" || "$entry" == "$dev" ]] && return 0
    done < <(pdi_protected_list "$cfg")
    return 1
}

#===============================================================================
# arm codes
#===============================================================================
# pdi_arm_code <serial> <model> <size-bytes> -- deterministic 6-char uppercase
# hex transcription challenge, derived from stable disk identity. NOT a
# secret: it forces the operator to read the enumeration row deliberately.
# Must match tools/Get-PhoenixDiskInventory.ps1 byte for byte.
pdi_arm_code() {
    local serial="$1" model="$2" size="$3"
    printf 'phoenix-nuke-arm|%s|%s|%s' "$serial" "$model" "$size" \
        | sha256sum | cut -c1-6 | tr 'a-f' 'A-F'
}

#===============================================================================
# enumeration: the candidate list (boot USB + protected disks are EXCLUDED)
#===============================================================================
# pdi_enumerate -- fill PDI_* candidate arrays; excluded disks go to
# PDI_HIDDEN_* with a reason. Sets PDI_COUNT / PDI_HIDDEN_COUNT.
pdi_enumerate() {
    PDI_DEV=(); PDI_MODEL=(); PDI_SERIAL=(); PDI_SIZE=(); PDI_TRAN=()
    PDI_FLAGS=(); PDI_CODE=(); PDI_COUNT=0
    PDI_HIDDEN_DEV=(); PDI_HIDDEN_WHY=(); PDI_HIDDEN_COUNT=0

    local bootlist line
    bootlist="$(pdi_detect_boot_disks)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pdi_parse_pairs "$line"
        [[ "${PDI_LP[TYPE]:-}" == "disk" ]] || continue
        local name="${PDI_LP[NAME]:-}"
        [[ -z "$name" ]] && continue
        case "$name" in loop*|ram*|md*|dm-*) continue ;; esac
        local dev="/dev/$name"
        local model="${PDI_LP[MODEL]:-(unknown)}"
        local serial="${PDI_LP[SERIAL]:-}"
        local size="${PDI_LP[SIZE]:-0}"
        local tran="${PDI_LP[TRAN]:-?}"
        local flags=""

        # --- exclusions (structural, not advisory) ---
        if grep -qxF "$dev" <<<"$bootlist"; then
            PDI_HIDDEN_DEV+=("$dev"); PDI_HIDDEN_WHY+=("BOOT-USB")
            PDI_HIDDEN_COUNT=$((PDI_HIDDEN_COUNT+1)); continue
        fi
        if pdi_disk_mounted "$dev"; then
            PDI_HIDDEN_DEV+=("$dev"); PDI_HIDDEN_WHY+=("MOUNTED")
            PDI_HIDDEN_COUNT=$((PDI_HIDDEN_COUNT+1)); continue
        fi
        if pdi_is_protected "$dev" "$serial"; then
            PDI_HIDDEN_DEV+=("$dev"); PDI_HIDDEN_WHY+=("PROTECTED(config)")
            PDI_HIDDEN_COUNT=$((PDI_HIDDEN_COUNT+1)); continue
        fi

        # --- candidate: flags, arm code ---
        [[ -z "$serial" ]] && serial="(unknown)" && flags="NO-SERIAL "
        case "$tran" in usb) flags="${flags}USB " ;; esac
        [[ "${PDI_LP[RM]:-0}" == "1" ]] && flags="${flags}REMOVABLE "
        local code
        code="$(pdi_arm_code "$serial" "$model" "$size")"

        PDI_DEV+=("$dev"); PDI_MODEL+=("$model"); PDI_SERIAL+=("$serial")
        PDI_SIZE+=("$size"); PDI_TRAN+=("$tran"); PDI_FLAGS+=("$flags")
        PDI_CODE+=("$code"); PDI_COUNT=$((PDI_COUNT+1))
    done < <(pdi_lsblk_enum)
}

pdi_print_table() {
    printf '%-3s %-12s %-20s %-14s %-9s %-8s %-8s %s\n' \
        "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "BUS" "ARM-CODE" "FLAGS"
    local i
    for ((i=0; i<PDI_COUNT; i++)); do
        printf '%-3s %-12s %-20.20s %-14.14s %-9s %-8s %-8s %s\n' \
            "$i" "${PDI_DEV[$i]}" "${PDI_MODEL[$i]}" "${PDI_SERIAL[$i]}" \
            "$(pdi_human_size "${PDI_SIZE[$i]}")" "${PDI_TRAN[$i]}" \
            "${PDI_CODE[$i]}" "${PDI_FLAGS[$i]}"
    done
}

pdi_print_hidden() {
    local i
    for ((i=0; i<PDI_HIDDEN_COUNT; i++)); do
        echo "  hidden: ${PDI_HIDDEN_DEV[$i]} (${PDI_HIDDEN_WHY[$i]})"
    done
}

# pdi_run -- dry-run entry: enumerate, print candidates + hidden summary.
# Exit 0 always; nothing here can arm or destroy.
pdi_run() {
    pdi_enumerate
    echo "=== Phoenix NUKE -- candidate disks (dry-run: nothing will be touched) ==="
    pdi_print_table
    echo
    if (( PDI_HIDDEN_COUNT > 0 )); then
        echo "Excluded from candidacy ($PDI_HIDDEN_COUNT):"
        pdi_print_hidden
    else
        echo "Excluded from candidacy: none"
    fi
    echo
    echo "To arm a wipe, a NUKE-path tool must call pdi_confirm_armed with the"
    echo "target's ARM-CODE (or exact serial), typed by the operator on a real"
    echo "terminal. Row numbers, /dev paths, Y/N and piped input are refused."
    return 0
}

#===============================================================================
# confirmation gate
#===============================================================================
# pdi_confirm_armed <serial> <arm-code> -- prompt on a real terminal and
# require the operator to type the target's ARM CODE or its exact serial.
# Exact match, case-sensitive, no extra whitespace. Returns 0 = armed.
# Structural refusals: stdin not a TTY (piped/scripted input can never arm);
# serial empty or "(unknown)" (no serial, no arming).
pdi_confirm_armed() {
    local serial="$1" code="$2" got
    if [[ -z "$serial" || "$serial" == "(unknown)" ]]; then
        echo "REFUSED: disk has no readable serial -- cannot be armed." >&2
        return 1
    fi
    if [[ ! -t 0 ]]; then
        echo "REFUSED: confirmation requires a real terminal (stdin is not a tty)." >&2
        return 1
    fi
    printf 'Type the ARM-CODE (or exact serial) of the disk to arm: ' >&2
    IFS= read -r got || { echo "ABORTED: no input." >&2; return 1; }
    if [[ "$got" == "$code" || "$got" == "$serial" ]]; then
        echo "ARMED [$(pdi_ts)] evidence=typed-arm-code-or-serial" >&2
        return 0
    fi
    echo "ABORTED: input did not match the ARM-CODE or the exact serial." >&2
    return 1
}
