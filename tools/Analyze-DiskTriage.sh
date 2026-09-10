#!/usr/bin/env bash
#===============================================================================
# Analyze-DiskTriage.sh -- Phoenix ANALYZE phase flow (Linux / boot-environment)
#
# READ-ONLY disk triage that runs BEFORE the Backup phase of the emergency
# runbook. Enumerates every disk, inventories partitions, runs heuristic
# filesystem scans (suspicious indicators, clearly labeled HEURISTIC), and
# writes a phoenix-triage-report/1 JSON report to the operator-supplied state
# dir. Twin: tools/Analyze-DiskTriage.ps1 (WinPE side).
#
# THIS TOOL CANNOT WRITE TO A TARGET DISK. It self-verifies that guarantee on
# startup: analyze_assert_readonly() fails the run closed if any file in the
# Analyze toolchain (this script, the lib, the PowerShell twin) contains a
# forbidden write pattern. Reads are via lsblk/sysfs only; partitions the
# flow mounts itself are always `mount -o ro` (see analyze_ro_mount).
#
# USAGE:
#   Analyze-DiskTriage.sh --save-state DIR [--mount-ro] [--help]
#
#   --save-state DIR   required: where triage-report.json goes. Must NOT be on
#                      a triaged disk (gated); normally the Phoenix boot USB.
#   --mount-ro         also scan partitions that are not already mounted, by
#                      mounting them READ-ONLY (never rw). Default: scan only
#                      partitions the boot environment already mounted.
#
# TESTING: fully mockable, no real disks:
#   PHOENIX_MOCK_LSBLK / PHOENIX_MOCK_MOUNTS / PHOENIX_MOCK_PARTITIONS (see lib)
#   PHOENIX_ANALYZE_TEMP_MAX_KB -- temp-dir heuristic threshold
#   PHOENIX_MOCK_REPORT_DEVICE   -- fake df backing device for the state dir
#   PHOENIX_MOCK_SCAN_ROOT=<dir> -- fake root containing per-partition mount
#                      trees named by partition dev basename (sda1/, sda2/, ...)
#                      used instead of real mountpoints in tests
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
PROG="$(basename "$0")"
LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
LIB="$LIB_DIR/analyze-gates.sh"
PS1_TWIN="$(cd "$(dirname "$0")" && pwd)/Analyze-DiskTriage.ps1"

SAVE_STATE_DIR=""
MOUNT_RO=0

usage() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --save-state) SAVE_STATE_DIR="${2:?--save-state needs a directory}"; shift 2;;
        --mount-ro)   MOUNT_RO=1; shift;;
        --help|-h)    usage;;
        *) echo "[$PROG] unknown argument: $1" >&2; exit 3;;
    esac
done

[[ -n "$SAVE_STATE_DIR" ]] \
    || { echo "[$PROG] --save-state DIR is required (see --help)." >&2; exit 3; }

# --- 0. read-only self-check ----------------------------------------------------
# shellcheck disable=SC1090
source "$LIB"
analyze_assert_readonly "$LIB" "$0" "$PS1_TWIN" \
    || { echo "[$PROG] ABORTED: read-only self-check failed." >&2; exit 1; }

echo "[$PROG] READ-ONLY PLEDGE: this tool enumerates and inspects disks only."
echo "[$PROG] It never writes to a target disk (self-check above is the proof)."

# --- 1. enumerate ---------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INV="$TMP/inventory.json"
PARTS="$TMP/parts.json"
INDS="$TMP/indicators.json"

analyze_enumerate_disks "$INV" >/dev/null
N_DISKS="$(python3 -c 'import json; print(len(json.load(open("'"$INV"'"))["disks"]))')"
echo "[$PROG] enumerated $N_DISKS disk(s)."

# --- 2. per-disk partition inventory + heuristic scans ---------------------------
# parts.json / indicators.json are keyed by disk id: {"1": [...], ...}
python3 - "$PARTS" "$INDS" <<'EOF'
import json, sys
json.dump({}, open(sys.argv[1], "w"))
json.dump({}, open(sys.argv[2], "w"))
EOF

merge_json() { # <key> <src-json-file> <map-file> : append src array into map[key]
    local key="$1" src="$2" map="$3"
    PHOENIX_M_KEY="$key" PHOENIX_M_SRC="$src" PHOENIX_M_MAP="$map" python3 <<'EOF'
import json, os
key, src, mapp = os.environ["PHOENIX_M_KEY"], os.environ["PHOENIX_M_SRC"], os.environ["PHOENIX_M_MAP"]
arr = json.load(open(src))
try:
    m = json.load(open(mapp))
except (FileNotFoundError, json.JSONDecodeError):
    m = {}
m.setdefault(key, []).extend(arr)
json.dump(m, open(mapp, "w"), indent=2)
EOF
}

RO_MOUNTS=()
scan_partition() { # <disk-id> <label> <part-dev> <fstype> <mountpoint-or-empty>
    local did="$1" label="$2" pdev="$3" fstype="$4" mnt="$5"
    local scan_root
    if [[ -n "${PHOENIX_MOCK_SCAN_ROOT:-}" ]]; then
        scan_root="${PHOENIX_MOCK_SCAN_ROOT}/$(basename "$pdev")"
        [[ -d "$scan_root" ]] || return 0
        mnt="$scan_root"
    elif [[ -z "$mnt" ]]; then
        if [[ "$MOUNT_RO" -eq 1 ]]; then
            case "$fstype" in
                ntfs|vfat|exfat|ext2|ext3|ext4)
                    mnt="$TMP/ro-$(basename "$pdev")"
                    analyze_ro_mount "$pdev" "$fstype" "$mnt" || return 0
                    RO_MOUNTS+=("$mnt")
                    ;;
                *) echo "[$PROG] skip ro-mount of $pdev (fstype ${fstype:-unknown} not scannable)" >&2; return 0;;
            esac
        else
            return 0  # unmounted and --mount-ro not given: skip
        fi
    fi
    [[ -d "$mnt" ]] || { echo "[$PROG] skip scan of $pdev (no accessible mount)" >&2; return 0; }
    local ind="$TMP/ind-$did-$(basename "$pdev").json"
    analyze_scan_mount "$mnt" "$label" "$ind" || return 0
    merge_json "$did" "$ind" "$INDS"
}

# drive the per-disk loop from the inventory
python3 - "$INV" <<'EOF' > "$TMP/disklist.tsv"
import json, sys
for d in json.load(open(sys.argv[1]))["disks"]:
    print(f'{d["id"]}\t{d["dev"]}')
EOF

while IFS=$'\t' read -r did dev; do
    [[ -n "$did" ]] || continue
    echo "[$PROG] disk [$did] $dev: partition inventory..."
    pjson="$TMP/parts-$did.json"
    analyze_partition_inventory "$dev" "$pjson" >/dev/null
    merge_json "$did" "$pjson" "$PARTS"
    # scan each partition that has a mountpoint (or --mount-ro handles the rest)
    while IFS=$'\t' read -r pname pdev pfstype pmnt; do
        [[ -n "$pname" ]] || continue
        scan_partition "$did" "disk-$did" "$pdev" "$pfstype" "$pmnt"
    done < <(PHOENIX_DID="$did" python3 - "$pjson" <<'EOF'
import json, sys
for p in json.load(open(sys.argv[1])):
    print(f'{p["name"]}\t{p["dev"]}\t{p.get("fstype") or ""}\t{p.get("mountpoint") or ""}')
EOF
)
done < "$TMP/disklist.tsv"

# unmount anything WE mounted (we never touch pre-existing mounts)
for m in "${RO_MOUNTS[@]}"; do
    umount "$m" 2>/dev/null && rmdir "$m" 2>/dev/null || true
done

# --- 3. report ------------------------------------------------------------------
analyze_require_report_dir "$SAVE_STATE_DIR" "$INV" \
    || { echo "[$PROG] ABORTED: unsafe report directory." >&2; exit 1; }

REPORT="$(analyze_write_report "$SAVE_STATE_DIR" "$INV" "$PARTS" "$INDS")"

echo "[$PROG] ----------------------------------------"
echo "[$PROG] triage complete. Report: $REPORT"
python3 - "$REPORT" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"[triage] {len(r['disks'])} disk(s), {len(r['indicators'])} indicator(s), verdict={r['verdict']}")
for i in r["indicators"]:
    print(f"[triage] [{i['severity']}] disk {i.get('disk_id')} {i['code']}: {i['title']}")
EOF
echo "[$PROG] Next: image each target disk (Backup phase) BEFORE any wipe."
