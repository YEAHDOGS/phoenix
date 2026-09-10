#!/usr/bin/env bash
#===============================================================================
# Invoke-Analyze.sh -- Phoenix ANALYZE module (read-only triage payload)
#
# Collects disk enumeration + hardware inventory + malware-triage data on the
# Phoenix Linux boot side (USB menu entry [1] ANALYZE - SystemRescue) WITHOUT
# booting the suspect OS and WITHOUT mounting or writing to any suspect disk.
#
# SAFETY MODEL (see docs/ANALYZE-MODULE.md):
#   1. READ-ONLY BY CONSTRUCTION: the script never mounts, never writes to,
#      and never issues destructive commands to any block device. Any disk
#      with mounted partitions is still enumerated (data needed) but flagged
#      in the report's notes; the script never mounts or unmounts anything.
#   2. NO NETWORK: only interface *state* (operstate) is read. Nothing is
#      brought up, no packets are sent, no firmware updates are attempted.
#   3. NO SUSPECT-OS BOOT: all data comes from the rescue kernel (sysfs,
#      procfs, NVRAM, dmidecode). Offline filesystem inspection happens later
#      on the staging machine against the mounted *image* (see the
#      ANALYSIS-TOOLKIT.md workflow).
#   4. IMAGE FIRST: this module never assumes an image exists, and its report
#      carries image_proof_hint only when --image-proof <file> names a valid
#      proof -- it does not gate on it.
#   5. ENUMERATION CONTRACT: serial-resolved identity like Invoke-Nuke.sh /
#      Invoke-Backup.sh (row number, /dev node, or serial all resolve to the
#      enumerated table). Duplicate serials are flagged DUP-SERIAL and break
#      identity: the report refuses to pick one, and the *note* says so.
#   6. CONFIG HONESTY: --config <phoenix-config.json> is optional. When given
#      it must validate (Validate-UsbConfig.py) and boot_entries.analyze must
#      be true, else the script refuses -- the stick must not offer Analyze
#      unless the builder enabled it.
#
# OUTPUT: human table on stdout (enumerate mode) and/or a JSON report
# (phoenix-analyze-report, report_version 1) written ATOMICALLY (temp file +
# rename) to --out <dir>. The report is the handoff artifact the staging
# machine and the task board consume.
#
# USAGE:
#   Invoke-Analyze.sh                                  enumerate, print table, exit 0
#   Invoke-Analyze.sh --write --out /mnt/usb/reports   same + write JSON report
#   Invoke-Analyze.sh --boot-device <id>                mark the Phoenix USB in the table
#   Invoke-Analyze.sh --config /phoenix-config.json    fail closed unless analyze enabled
#   Invoke-Analyze.sh --image-proof /path/to/proof     record proof binding in report
#
# Test hooks (environment, default in brackets):
#   PHOENIX_SYSFS_ROOT [/sys]  PHOENIX_PROC_ROOT [/proc]
#   PHOENIX_DEV_ROOT   [/dev]  PHOENIX_BOOT_DEVICE (the menu launcher's own device)
#
# Exit codes: 0 = ok | 1 = error/refusal | 2 = usage error
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${PHOENIX_TOOLS_DIR:-$SCRIPT_DIR}"

SYSFS="${PHOENIX_SYSFS_ROOT:-/sys}"
PROCFS="${PHOENIX_PROC_ROOT:-/proc}"
DEVFS="${PHOENIX_DEV_ROOT:-/dev}"

CONFIG="" BOOT_ID="" IMAGE_PROOF="" OUT_DIR="" WRITE=0
BOOT_DEVICE_NAME=""   # resolved kernel device name of the Phoenix USB

# --- usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $PROG [--config <phoenix-config.json>] [--boot-device <id>]
             [--image-proof <file>] [--write --out <dir>] [--version] [--help]

Read-only triage: enumerate disks, inventory hardware, emit a JSON report.
Never mounts, never writes to, never destroys anything.
EOF
}

# --- option parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)      CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --boot-device) BOOT_ID="$2"; shift 2 ;;
        --image-proof) IMAGE_PROOF="$2"; shift 2 ;;
        --write)       WRITE=1; shift ;;
        --out)         OUT_DIR="$2"; shift 2 ;;
        --version)     echo "$PROG $VERSION"; exit 0 ;;
        --help|-h)     usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ $WRITE -eq 1 && -z "$OUT_DIR" ]]; then
    echo "ERROR: --write requires --out <dir>" >&2; exit 2
fi
if [[ -n "$OUT_DIR" && ! -d "$OUT_DIR" ]]; then
    echo "ERROR: --out is not a directory: $OUT_DIR" >&2; exit 1
fi

# --- JSON helpers ------------------------------------------------------------
jstr() {  # JSON-escape a string to stdout
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown"; }
# NOTE: bash treats TAB as IFS *whitespace* (adjacent tabs collapse, so empty
# fields vanish). lsblk/sysfs fields can be empty, so the python parse below
# joins with \x1f (unit separator, never IFS-whitespace) and every tab-split
# read uses IFS="$SEP".
SEP="$(printf '\037')"

notes_add() { NOTES+=("$1"); }
declare -a NOTES=()

# --- config honesty ----------------------------------------------------------
if [[ -n "$CONFIG" ]]; then
    [[ -f "$CONFIG" ]] || { echo "ERROR: --config file not found: $CONFIG" >&2; exit 1; }
    if ! python3 "$TOOLS_DIR/Validate-UsbConfig.py" "$CONFIG" >/dev/null 2>&1; then
        echo "ERROR: --config failed validation: $CONFIG (fail closed)" >&2; exit 1
    fi
    # Read-UsbConfig.py prints shell exports; check boot_entries.analyze.
    ANALYZE_ENABLED=""
    while IFS='=' read -r k v; do
        case "$k" in
            CFG_ANALYZE_ENABLED) ANALYZE_ENABLED="$v" ;;
        esac
    done < <(python3 "$TOOLS_DIR/Read-UsbConfig.py" --shell "$CONFIG" 2>/dev/null || true)
    if [[ "$ANALYZE_ENABLED" != "1" && "$ANALYZE_ENABLED" != "true" ]]; then
        echo "ERROR: stick policy: boot_entries.analyze is not enabled (fail closed)" >&2
        exit 1
    fi
fi

# --- helpers -----------------------------------------------------------------
sys_block_dir() { printf '%s/block' "$SYSFS"; }

is_excluded_dev() {  # loop/ram/zram/dm/md are never suspect disks
    case "$1" in loop*|ram*|zram*|dm-*|md*|fd*) return 0 ;; esac
    return 1
}

read1() {  # read1 <file> -> contents or ""
    local f="$1"
    [[ -r "$f" ]] && tr -d '\0' < "$f" 2>/dev/null | head -c 512 || true
}

resolve_boot_device() {
    local id="${BOOT_ID:-${PHOENIX_BOOT_DEVICE:-}}"
    [[ -z "$id" ]] && return 0
    # Accept serial, /dev node, row number (resolved later), or kernel name.
    local guess="${id##*/}"
    if [[ -d "$(sys_block_dir)/$guess" ]]; then
        BOOT_DEVICE_NAME="$guess"
    else
        notes_add "boot-device id '$id' did not resolve to a block device; report marks none"
    fi
}

media_type_for() {  # $1=rotational(0/1), $2=transport
    case "$2" in nvme|NVMe) echo "SSD" ;;
        *) case "$1" in 1) echo "HDD" ;; 0) echo "SSD" ;; *) echo "unknown" ;; esac ;;
    esac
}

# --- disk enumeration: lsblk fast path ---------------------------------------
declare -a D_NAMES=() D_MODELS=() D_SERIALS=() D_SIZES=() D_TRANS=() D_ROTA=()
declare -a D_RM=() D_MEDIA=() D_MOUNTED=()

lsblk_enumerate() {
    command -v lsblk >/dev/null 2>&1 || return 1
    local json
    json="$(lsblk -bdnJ -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,RM 2>/dev/null)" || return 1
    local n
    n="$(printf '%s' "$json" | python3 -c '
import json,sys
try:
    devs=json.load(sys.stdin)["blockdevices"]
except Exception: devs=[]
for d in devs:
    def val(x):
        return "" if x is None else str(x)   # keep JSON false as "False"; None as empty
    # -d already restricts lsblk to whole disks; the type key is absent
    # unless explicitly requested in -o, so no type filter here.
    print("\x1f".join(val(d.get(k)) for k in ("name","size","model","serial","tran","rota","rm")))
' 2>/dev/null)" || return 1
    [[ -z "$n" ]] && return 1
    local line
    while IFS="$SEP" read -r name size model serial tran rota rm; do
        is_excluded_dev "$name" && continue
        # lsblk -J reports rota as true/false (JSON bool); normalize to 0/1.
        case "$rota" in 1|true|True) rota=1 ;; 0|false|False) rota=0 ;; *) rota="" ;; esac
        case "$rm" in 1|true|True) rm=1 ;; 0|false|False) rm=0 ;; *) rm="" ;; esac
        D_NAMES+=("$name"); D_SIZES+=("$size"); D_MODELS+=("$model")
        D_SERIALS+=("$serial"); D_TRANS+=("$tran"); D_ROTA+=("$rota"); D_RM+=("$rm")
        D_MEDIA+=("$(media_type_for "$rota" "$tran")")
        D_MOUNTED+=("$(disk_is_mounted "$name" && echo yes || echo no)")
    done <<< "$n"
    return 0
}

# --- disk enumeration: /sys fallback ------------------------------------------
sysfs_enumerate() {
    local bd name
    for bd in "$(sys_block_dir)"/*; do
        [[ -d "$bd" ]] || continue
        name="$(basename "$bd")"
        is_excluded_dev "$name" && continue
        local size_sectors size_bytes
        size_sectors="$(read1 "$bd/size")"; size_sectors="${size_sectors//[!0-9]/}"
        size_bytes="$(( ${size_sectors:-0} * 512 ))"
        local model serial rota rm tran
        model="$(read1 "$bd/device/model")"
        serial="$(read1 "$bd/device/serial")"
        [[ -z "$serial" && -d "$SYSFS/class/nvme/$name" ]] && serial="$(read1 "$SYSFS/class/nvme/$name/serial")"
        rota="$(read1 "$bd/queue/rotational")"; rota="${rota//[!01]/}"
        rm="$(read1 "$bd/removable")"; rm="${rm//[!01]/}"
        tran=""
        if [[ -L "$bd/device" ]]; then
            case "$(readlink "$bd/device")" in
                *nvme*) tran="nvme" ;; *usb*) tran="usb" ;;
                *ata*|*scsi*) tran="sata" ;;
            esac
        fi
        D_NAMES+=("$name"); D_SIZES+=("$size_bytes")
        D_MODELS+=("$model"); D_SERIALS+=("$serial")
        D_TRANS+=("$tran"); D_ROTA+=("$rota"); D_RM+=("$rm")
        D_MEDIA+=("$(media_type_for "${rota:-x}" "$tran")")
        D_MOUNTED+=("$(disk_is_mounted "$name" && echo yes || echo no)")
    done
}

disk_is_mounted() {  # $1=kernel name -> true if any partition is mounted
    local name="$1" mounts
    mounts="$PROCFS/mounts"
    [[ -r "$mounts" ]] || return 1
    grep -qE "^$DEVFS/$name(p[0-9]+|[0-9]+)? " "$mounts" 2>/dev/null
}

resolve_id_to_index() {  # $1=id -> index into D_* (row number, /dev node, serial, kernel name)
    local id="$1" guess="${1##*/}" i
    if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= ${#D_NAMES[@]} )); then
        echo $((id - 1)); return 0
    fi
    for i in "${!D_NAMES[@]}"; do
        if [[ "${D_NAMES[$i]}" == "$guess" ]]; then echo "$i"; return 0; fi
    done
    for i in "${!D_SERIALS[@]}"; do
        if [[ -n "${D_SERIALS[$i]}" && "${D_SERIALS[$i]}" == "$id" ]]; then echo "$i"; return 0; fi
    done
    return 1
}

# --- hardware inventory -------------------------------------------------------
hw_cpu() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/,"",$2); print $2; exit}'
    else
        grep -m1 'model name' "$PROCFS/cpuinfo" 2>/dev/null | cut -d: -f2 | sed 's/^ *//'
    fi
}
hw_cpu_count() {
    if command -v nproc >/dev/null 2>&1; then nproc 2>/dev/null
    else grep -c '^processor' "$PROCFS/cpuinfo" 2>/dev/null; fi
}
hw_ram_total_kb() {
    if command -v dmidecode >/dev/null 2>&1; then
        dmidecode -t memory 2>/dev/null | awk '/Size: [0-9]+ MB/ {s+=$2} END {print s*1024}' | grep -E '^[0-9]+$' || true
    fi
    # Fallback always available in a Linux boot env.
    grep -m1 '^MemTotal:' "$PROCFS/meminfo" 2>/dev/null | awk '{print $2}'
}
hw_dmi() {  # $1 = dmi id file name
    read1 "$SYSFS/class/dmi/id/$1"
}
hw_secure_boot() {
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        echo "enabled"; return 0
    fi
    local sb="$SYSFS/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [[ -r "$sb" ]]; then
        # First 4 bytes are attributes; the 5th byte is the value.
        [[ "$(od -An -tu1 -j4 -N1 "$sb" 2>/dev/null | tr -d ' ')" == "1" ]] && { echo "enabled"; return 0; }
        echo "disabled"; return 0
    fi
    echo "unknown"
}
hw_tpm() {
    [[ -e "$DEVFS/tpm0" || -d "$SYSFS/class/tpm/tpm0" ]] && { echo "present"; return 0; }
    echo "absent"
}
hw_net_ifaces() {  # SEP-separated iface, operstate
    local d
    for d in "$SYSFS"/class/net/*; do
        [[ -d "$d" ]] || continue
        local ifname state
        ifname="$(basename "$d")"; state="$(read1 "$d/operstate")"
        printf '%s%s%s\n' "$ifname" "$SEP" "${state:-unknown}"
    done
}
hw_boot_entries() {  # efibootmgr -v (NVRAM only -- no disk access); "" when absent
    command -v efibootmgr >/dev/null 2>&1 || return 0
    efibootmgr -v 2>/dev/null | head -c 4096 || true
}

# --- smart capability (non-invasive identify only) ---------------------------
disk_smart_support() {  # $1=kernel name -> yes/no/unknown
    command -v smartctl >/dev/null 2>&1 || { echo "unknown"; return 0; }
    local out
    out="$(smartctl -i "$DEVFS/$1" 2>/dev/null | grep -i 'SMART support is' | head -1 || true)"
    case "$out" in
        *Enabled*) echo "yes" ;; *Disabled*|*Unavailable*) echo "no" ;; *) echo "unknown" ;;
    esac
}

# --- enumerate ----------------------------------------------------------------
if ! lsblk_enumerate; then
    notes_add "lsblk unavailable; enumerated via $SYSFS/block fallback"
    sysfs_enumerate
fi
resolve_boot_device

if [[ ${#D_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: no disks enumerated; refusing to emit an empty report" >&2
    exit 1
fi

# Duplicate-serial identity check: analyze never resolves one disk from a
# shared serial; the report flags DUP-SERIAL and refuses row identity.
declare -A SEEN_SERIAL=()
declare -a D_DUP=()
for i in "${!D_NAMES[@]}"; do
    D_DUP[$i]="no"
    s="${D_SERIALS[$i]}"
    [[ -z "$s" || "$s" == "unknown" ]] && continue
    if [[ -n "${SEEN_SERIAL[$s]:-}" ]]; then
        D_DUP[$i]="yes"; D_DUP[${SEEN_SERIAL[$s]}]="yes"
        notes_add "DUP-SERIAL: serial '$s' reported by ${D_NAMES[${SEEN_SERIAL[$s]}]} and ${D_NAMES[$i]}; identity ambiguous, serial resolution refused"
    else
        SEEN_SERIAL[$s]="$i"
    fi
done

for i in "${!D_NAMES[@]}"; do
    if [[ "${D_MOUNTED[$i]}" == "yes" ]]; then
        notes_add "mounted: ${D_NAMES[$i]} has mounted partitions; enumerated read-only, nothing mounted/unmounted"
    fi
done

# --- image-proof hint ---------------------------------------------------------
# A proof is only a *hint* here (analyze never gates on it). Structural
# validity reuses the same field rules as Invoke-Nuke.sh check_image_proof,
# minus the target-serial binding (analyze has no single target).
proof_structurally_valid() {
    local f="$1" format="" verified="" sha256="" pserial="" psize="" line k v
    [[ -n "$f" && -f "$f" ]] || return 1
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
    [[ "$format" == "phoenix-image-proof/1" ]] || return 1
    [[ "$verified" == "YES" ]] || return 1
    [[ "$sha256" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    [[ "$psize" =~ ^[0-9]+$ && "$psize" -gt 0 ]] || return 1
    [[ -n "$pserial" && "$pserial" != "unknown" ]] || return 1
    PROOF_SERIAL="$pserial"
    return 0
}
PROOF_VALID="no"; PROOF_SERIAL=""
if [[ -n "$IMAGE_PROOF" ]]; then
    if proof_structurally_valid "$IMAGE_PROOF"; then
        PROOF_VALID="yes"
    else
        notes_add "image-proof '$IMAGE_PROOF' missing or invalid; treated as absent"
    fi
fi

# --- human table --------------------------------------------------------------
printf 'Phoenix ANALYZE triage (%s) -- read-only, suspect OS never booted\n' "$(now_utc)"
printf '%-4s %-10s %-14s %-20s %-8s %-7s %s\n' ROW DEVICE SERIAL MODEL SIZE MEDIA FLAGS
for i in "${!D_NAMES[@]}"; do
    flags=""
    [[ "${D_NAMES[$i]}" == "$BOOT_DEVICE_NAME" ]] && flags="${flags}BOOT-USB"
    [[ "${D_DUP[$i]}" == "yes" ]] && flags="${flags:+$flags }DUP-SERIAL"
    [[ "${D_MOUNTED[$i]}" == "yes" ]] && flags="${flags:+$flags }MOUNTED"
    printf '%-4s %-10s %-14s %-20s %-8s %-7s %s\n' \
        "$((i+1))" "/dev/${D_NAMES[$i]}" "${D_SERIALS[$i]:-?}" \
        "${D_MODELS[$i]:-?}" "${D_SIZES[$i]}" "${D_MEDIA[$i]}" "$flags"
done
printf '\nHardware: CPU=%s x%s | RAM=%s kB | BIOS=%s %s | SecureBoot=%s | TPM=%s\n' \
    "$(hw_cpu)" "$(hw_cpu_count)" "$(hw_ram_total_kb)" \
    "$(hw_dmi bios_vendor)" "$(hw_dmi bios_version)" \
    "$(hw_secure_boot)" "$(hw_tpm)"
printf 'Network (state only, no traffic):\n'
hw_net_ifaces | while IFS="$SEP" read -r ifname state; do printf '  %-12s %s\n' "$ifname" "$state"; done
if [[ ${#NOTES[@]} -gt 0 ]]; then
    printf 'Notes:\n'
    printf '  - %s\n' "${NOTES[@]}"
fi

# --- JSON report --------------------------------------------------------------
if [[ $WRITE -eq 1 ]]; then
    tmp="$(mktemp "$OUT_DIR/.analyze-report.XXXXXX")" || { echo "ERROR: cannot stage report in $OUT_DIR" >&2; exit 1; }
    {
        printf '{\n  "report": "phoenix-analyze-report",\n  "report_version": 1,\n'
        printf '  "tool": "Invoke-Analyze.sh %s",\n  "collected_at": ' "$VERSION"; jstr "$(now_utc)"; printf ',\n'
        printf '  "machine": {\n'
        printf '    "cpu": '; jstr "$(hw_cpu)"; printf ',\n'
        printf '    "cpu_count": %s,\n' "$(hw_cpu_count)"
        printf '    "ram_total_kb": %s,\n' "$(hw_ram_total_kb)"
        printf '    "bios_vendor": '; jstr "$(hw_dmi bios_vendor)"; printf ',\n'
        printf '    "bios_version": '; jstr "$(hw_dmi bios_version)"; printf ',\n'
        printf '    "system_product": '; jstr "$(hw_dmi product_name)"; printf ',\n'
        printf '    "secure_boot": '; jstr "$(hw_secure_boot)"; printf ',\n'
        printf '    "tpm": '; jstr "$(hw_tpm)"; printf ',\n'
        printf '    "network_interfaces": ['
        first=1
        while IFS="$SEP" read -r ifname state; do
            [[ $first -eq 0 ]] && printf ', '
            printf '{"name": '; jstr "$ifname"; printf ', "state": '; jstr "$state"; printf '}'
            first=0
        done < <(hw_net_ifaces)
        printf '],\n'
        printf '    "efi_boot_entries": '; jstr "$(hw_boot_entries)"; printf '\n  },\n'
        printf '  "disks": [\n'
        for i in "${!D_NAMES[@]}"; do
            [[ $i -gt 0 ]] && printf ',\n'
            printf '    {"row": %s, "device": ' "$((i+1))"; jstr "/dev/${D_NAMES[$i]}"; printf ', '
            printf '"model": '; jstr "${D_MODELS[$i]}"; printf ', '
            printf '"serial": '; jstr "${D_SERIALS[$i]}"; printf ', '
            printf '"size_bytes": %s, ' "${D_SIZES[$i]:-0}"
            printf '"transport": '; jstr "${D_TRANS[$i]}"; printf ', '
            printf '"media": '; jstr "${D_MEDIA[$i]}"; printf ', '
            printf '"removable": %s, ' "$([[ "${D_RM[$i]}" == "1" ]] && echo true || echo false)"
            printf '"smart_support": '; jstr "$(disk_smart_support "${D_NAMES[$i]}")"; printf ', '
            printf '"dup_serial": %s, ' "$([[ "${D_DUP[$i]}" == "yes" ]] && echo true || echo false)"
            printf '"has_mounted_partitions": %s, ' "$([[ "${D_MOUNTED[$i]}" == "yes" ]] && echo true || echo false)"
            printf '"is_boot_usb": %s}' "$([[ "${D_NAMES[$i]}" == "$BOOT_DEVICE_NAME" ]] && echo true || echo false)"
        done
        printf '\n  ],\n'
        printf '  "image_proof": {"provided": %s, "valid": %s, "source_serial": ' \
            "$([[ -n "$IMAGE_PROOF" ]] && echo true || echo false)" \
            "$([[ "$PROOF_VALID" == "yes" ]] && echo true || echo false)"
        jstr "$PROOF_SERIAL"; printf '},\n'
        printf '  "notes": ['
        for ni in "${!NOTES[@]}"; do
            [[ $ni -gt 0 ]] && printf ', '
            jstr "${NOTES[$ni]}"
        done
        printf ']\n}\n'
    } > "$tmp"
    # Fail closed: the report is JSON-parseable or it does not land.
    if ! python3 -m json.tool "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "ERROR: generated report failed JSON parse; nothing written" >&2
        exit 1
    fi
    REPORT="$OUT_DIR/phoenix-analyze-report-$(date -u +%Y%m%dT%H%M%SZ).json"
    mv "$tmp" "$REPORT"
    echo "Report written: $REPORT"
fi

exit 0
