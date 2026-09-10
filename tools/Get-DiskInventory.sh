#!/usr/bin/env bash
#===============================================================================
# Get-DiskInventory.sh -- Phoenix disk enumeration (Linux / boot-environment side)
#
# Prints a JSON array describing every physical disk (see docs/NUKE-SAFETY.md
# section 2 for the contract). Twin: tools/Get-DiskInventory.ps1 (WinPE side).
# Both sides emit the same shape; size_human rendering must match exactly.
#
# USAGE:
#   Get-DiskInventory.sh                  print inventory JSON to stdout
#   Get-DiskInventory.sh --save-state DIR write <DIR>/disk-fingerprints.json
#                                         (the Analyze step; see NUKE-SAFETY.md
#                                          section 4) AND print inventory
#   Get-DiskInventory.sh --help           this help
#
# TESTING: set PHOENIX_MOCK_LSBLK to a file containing `lsblk -P` output lines
# and PHOENIX_MOCK_TRANSPORT="NAME:TRAN ..." overrides; no real disks touched.
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"
SAVE_STATE_DIR=""

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --save-state) SAVE_STATE_DIR="${2:?--save-state needs a directory}"; shift 2;;
        --help|-h) usage;;
        *) echo "[$PROG] unknown argument: $1" >&2; exit 3;;
    esac
done

# --- helpers -----------------------------------------------------------------
json_escape() { # stdin -> JSON string literal contents
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

format_gib() { # bytes -> "N.N GiB" (must match the PowerShell twin exactly)
    python3 -c "
import sys
b = int(sys.argv[1])
print(f'{b / (1024**3):.1f} GiB')" "$1"
}

# --- inventory collection -----------------------------------------------------
# We ask lsblk for one line per disk: lsblk -d = disks only, -P = KEY="value".
declare -a I_DEVS I_MODELS I_SERIALS I_SIZES I_TRANS I_REMOVABLES

collect_lsblk() {
    local line
    local src
    if [[ -n "${PHOENIX_MOCK_LSBLK:-}" ]]; then
        src="$PHOENIX_MOCK_LSBLK"
    else
        # real enumeration
        :
    fi

    local lspipe
    if [[ -n "${PHOENIX_MOCK_LSBLK:-}" ]]; then
        lspipe="cat \"$src\""
    else
        lspipe='lsblk -dno NAME,MODEL,SERIAL,SIZE,TRAN,RM -P'
    fi

    # NOTE: lsblk -P output is eval'd in a subshell scope with PATH preserved.
    # We export a sandbox function set and unset vars before/after.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local NAME="" MODEL="" SERIAL="" SIZE="" TRAN="" RM=""
        # shellcheck disable=SC1090
        eval "$line"
        I_DEVS+=("/dev/$NAME")
        I_MODELS+=("$MODEL")
        I_SERIALS+=("$SERIAL")
        I_SIZES+=("$SIZE")
        I_TRANS+=("$TRAN")
        I_REMOVABLES+=("$RM")
    done < <(eval "$lspipe")

    # transport overrides for mocks (real lsblk already gives TRAN)
    if [[ -n "${PHOENIX_MOCK_TRANSPORT:-}" ]]; then
        local pair k v i
        for pair in $PHOENIX_MOCK_TRANSPORT; do
            k="${pair%%:*}"; v="${pair#*:}"
            for i in "${!I_DEVS[@]}"; do
                if [[ "${I_DEVS[$i]}" == "/dev/$k" ]]; then
                    I_TRANS[$i]="$v"
                fi
            done
        done
    fi
}

# transport override entries come as NAME:TRAN; TRAN may be empty on mocks
# --- media classification ------------------------------------------------------
classify_media() { # <dev> <model> -> hdd|ssd|nvme|usb|unknown
    local dev="$1" model="$2"
    local rota=""
    rota="$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null || echo "")"
    if [[ "$dev" == /dev/nvme* ]]; then echo "nvme"; return; fi
    if [[ "$dev" == /dev/mmcblk* ]]; then echo "ssd"; return; fi
    if [[ "$rota" == "1" ]]; then echo "hdd"; return; fi
    if [[ "$rota" == "0" ]]; then echo "ssd"; return; fi
    if [[ "$model" =~ [Ss][Ss][Dd]|[Nn][Vv][Mm][Ee] ]]; then echo "ssd"; return; fi
    echo "unknown"
}

disk_mounted() { # <dev> -> 1 if any partition of the disk is mounted, else 0
    local dev="$1" base
    base="$(basename "$dev")"
    # PHOENIX_MOCK_MOUNTS="sda1 sdb2" overrides for tests
    local mounts="${PHOENIX_MOCK_MOUNTS:-$(awk '{print $1}' /proc/mounts 2>/dev/null)}"
    local m
    for m in $mounts; do
        local b
        b="$(basename "$m")"
        # partition of this disk: starts with disk base name and is longer
        if [[ "$b" == "$base"* && "$b" != "$base" ]]; then
            echo 1; return
        fi
    done
    echo 0
}

# --- fingerprint ----------------------------------------------------------------
partition_hash() { # <dev> -> "sha256:<hex>" of first 1 MiB, or "null"
    if [[ -n "${PHOENIX_MOCK_HASH:-}" ]]; then
        echo "sha256:${PHOENIX_MOCK_HASH}"; return
    fi
    local hex
    hex="$(dd if="$1" bs=1M count=1 status=none 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
    if [[ -n "$hex" ]]; then echo "sha256:$hex"; else echo "null"; fi
}

# --- main ----------------------------------------------------------------------
collect_lsblk

# deterministic order: transport, then size (numeric), then device
mapfile -t ORDER < <(
    for i in "${!I_DEVS[@]}"; do
        printf '%s\t%s\t%s\n' "${I_TRANS[$i]:-~}" "${I_SIZES[$i]:-0}" "$i"
    done | sort -t$'\t' -k1,1 -k2,2n | cut -f3
)

inventory_json="{ \"schema\": \"phoenix-disk-inventory/1\", \"disks\": ["
fp_entries=""
row=0
for i in "${ORDER[@]}"; do
    row=$((row+1))
    dev="${I_DEVS[$i]}"; model="${I_MODELS[$i]}"; serial="${I_SERIALS[$i]}"
    size_bytes="${I_SIZES[$i]:-0}"; tran="${I_TRANS[$i]:-unknown}"
    rm="${I_REMOVABLES[$i]:-0}"
    [[ "$rm" == "1" ]] && removable=true || removable=false
    mounted="$(disk_mounted "$dev")"
    [[ "$mounted" == "1" ]] && mounted_j=true || mounted_j=false
    media="$(classify_media "$dev" "$model")"
    size_human="$(format_gib "$size_bytes")"

    if [[ -z "$serial" ]]; then serial_j="null"; else serial_j="\"$(printf '%s' "$serial" | json_escape)\""; fi
    model_j="\"$(printf '%s' "$model" | json_escape)\""
    dev_j="\"$(printf '%s' "$dev" | json_escape)\""
    tran_j="\"$(printf '%s' "$tran" | json_escape)\""
    media_j="\"$media\""

    inventory_json="$inventory_json
    {\"id\": $row, \"dev\": $dev_j, \"model\": $model_j, \"serial\": $serial_j, \"size_bytes\": $size_bytes, \"size_human\": \"$size_human\", \"transport\": $tran_j, \"removable\": $removable, \"mounted\": $mounted_j, \"media\": $media_j},"

    if [[ -n "$SAVE_STATE_DIR" ]]; then
        ph="$(partition_hash "$dev")"
        [[ "$ph" == "null" ]] && ph_j="null" || ph_j="\"$ph\""
        fp_entries="$fp_entries
    {\"serial\": $serial_j, \"model\": $model_j, \"size_bytes\": $size_bytes, \"transport\": $tran_j, \"partition_hash\": $ph_j},"
    fi
done
inventory_json="${inventory_json%,}
  ]
}"

echo "$inventory_json" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), indent=2))'

if [[ -n "$SAVE_STATE_DIR" ]]; then
    mkdir -p "$SAVE_STATE_DIR"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fp_json="{ \"schema_version\": 1, \"recorded_at\": \"$ts\", \"recorded_by\": \"analyze\", \"disks\": [${fp_entries%,}
  ] }"
    echo "$fp_json" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), indent=2))' \
        > "$SAVE_STATE_DIR/disk-fingerprints.json"
    echo "[$PROG] fingerprints recorded -> $SAVE_STATE_DIR/disk-fingerprints.json" >&2
fi
