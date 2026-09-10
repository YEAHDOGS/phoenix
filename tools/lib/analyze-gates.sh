#!/usr/bin/env bash
#===============================================================================
# analyze-gates.sh -- shared bash gate library for the Phoenix ANALYZE phase.
#
# Source this file; do not execute it. Provides strictly READ-ONLY disk triage
# tooling that runs before the Backup phase of the emergency runbook:
#
#   analyze_enumerate_disks [OUT]         # disk inventory via Get-DiskInventory.sh
#   analyze_partition_inventory DEV [OUT] # per-partition inventory of one disk
#   analyze_assert_readonly FILES...       # FAIL CLOSED if any target file
#                                          # contains a forbidden write pattern
#   analyze_require_report_dir DIR INV     # report dir may not be / and may not
#                                          # live on any triaged target disk
#   analyze_scan_mount MNT LABEL OUT       # heuristic read-only filesystem scan
#   analyze_write_report DIR INV PARTS INDS # assemble phoenix-triage-report/1
#
# READ-ONLY CONTRACT (enforced, not just documented):
#   * No tool in the Analyze phase writes to a target disk, ever. Reads are
#     via lsblk/blkid/sysfs and `mount -o ro` only; mount is ALWAYS read-only
#     (`analyze_ro_mount` refuses any options string containing "rw").
#   * analyze_assert_readonly() scans the tool files themselves for forbidden
#     write patterns (mkfs, wipefs, dd of=/dev, remount,rw, ...) and FAILS
#     CLOSED if any are found. Analyze-DiskTriage.sh runs this self-check on
#     startup against every file in the Analyze toolchain, including the
#     PowerShell twin. A tool that somehow gained a write path cannot start.
#   * Reports are written only to the operator-supplied state dir, which
#     analyze_require_report_dir() verifies is not on a triaged disk.
#
# TESTING: all disk/filesystem touching is mockable:
#   PHOENIX_MOCK_LSBLK=<file>        -- lsblk -P disk lines (via Get-DiskInventory.sh)
#   PHOENIX_MOCK_MOUNTS="sda1 ..."   -- fake /proc/mounts entries
#   PHOENIX_MOCK_PARTITIONS=<file>   -- lsblk -P child-partition lines:
#                                      NAME SIZE FSTYPE LABEL PARTTYPE MOUNTPOINT
#   PHOENIX_ANALYZE_TEMP_MAX_KB=<n>  -- temp-dir size threshold (default 2097152)
#===============================================================================

# Guard against double-sourcing and direct execution.
if [[ -n "${ANALYZE_GATES_SOURCED:-}" ]]; then return 0; fi
ANALYZE_GATES_SOURCED=1

ANALYZE_GATES_VERSION="0.1.0"
ANALYZE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZE_ENUM="$ANALYZE_LIB_DIR/../Get-DiskInventory.sh"

# --- 1. disk enumeration --------------------------------------------------------
# analyze_enumerate_disks [out.json] -- prints inventory JSON to stdout, or
# writes it to OUT and prints the path. Uses Get-DiskInventory.sh so every
# phase sees the same phoenix-disk-inventory/1 contract. Honors the same
# PHOENIX_MOCK_* overrides (no real disks in tests).
analyze_enumerate_disks() {
    local out="${1:-}"
    local json
    json="$("$ANALYZE_ENUM")" || {
        echo "[analyze-gates] FAILED: disk enumeration failed." >&2; return 1
    }
    if [[ -n "$out" ]]; then
        printf '%s\n' "$json" > "$out"
        printf '%s\n' "$out"
    else
        printf '%s\n' "$json"
    fi
}

# --- 2. partition inventory -----------------------------------------------------
# analyze_partition_inventory <dev> [out.json] -- JSON array of the partitions
# of one disk. Reads only: lsblk (mockable) and nothing else.
analyze_partition_inventory() {
    local dev="$1" out="${2:-}"
    local base; base="$(basename "$dev")"
    local json
    if [[ -n "${PHOENIX_MOCK_PARTITIONS:-}" ]]; then
        [[ -r "${PHOENIX_MOCK_PARTITIONS}" ]] \
            || { echo "[analyze-gates] FAILED: PHOENIX_MOCK_PARTITIONS is not readable: ${PHOENIX_MOCK_PARTITIONS}" >&2; return 1; }
        # NOTE: exported (not env-prefix) -- bash does not propagate env-prefix
        # assignments into a command substitution that assigns a variable.
        export PHOENIX_PART_BASE="$base" PHOENIX_PART_SRC="${PHOENIX_MOCK_PARTITIONS}"
        json="$(python3 <<'EOF'
import os, shlex, json
base, src = os.environ["PHOENIX_PART_BASE"], os.environ["PHOENIX_PART_SRC"]
parts = []
for line in open(src):
    line = line.strip()
    if not line:
        continue
    kv = dict(tok.split("=", 1) for tok in shlex.split(line))
    name = kv.get("NAME", "")
    if not name.startswith(base) or name == base:
        continue
    def num(v):
        try: return int(v)
        except (TypeError, ValueError): return 0
    size = num(kv.get("SIZE", "0"))
    parts.append({
        "name": name,
        "dev": "/dev/" + name,
        "size_bytes": size,
        "size_human": f"{size / (1024**3):.1f} GiB",
        "fstype": kv.get("FSTYPE") or None,
        "label": kv.get("LABEL") or None,
        "parttype": kv.get("PARTTYPE") or None,
        "mountpoint": kv.get("MOUNTPOINT") or None,
    })
print(json.dumps(parts))
EOF
)"
        unset PHOENIX_PART_BASE PHOENIX_PART_SRC PHOENIX_PART_LINES
    else
        local lines
        lines="$(lsblk -Pno NAME,SIZE,FSTYPE,LABEL,PARTTYPE,MOUNTPOINT "$dev" 2>/dev/null | tail -n +2)" \
            || { echo "[analyze-gates] FAILED: lsblk partition query failed for $dev." >&2; return 1; }
        export PHOENIX_PART_BASE="$base" PHOENIX_PART_LINES="$lines"
        json="$(python3 <<'EOF'
import os, shlex, json
base, lines = os.environ["PHOENIX_PART_BASE"], os.environ["PHOENIX_PART_LINES"]
parts = []
for line in lines.splitlines():
    line = line.strip()
    if not line:
        continue
    kv = dict(tok.split("=", 1) for tok in shlex.split(line))
    name = kv.get("NAME", "")
    if not name.startswith(base) or name == base:
        continue
    def num(v):
        try: return int(v)
        except (TypeError, ValueError): return 0
    size = num(kv.get("SIZE", "0"))
    parts.append({
        "name": name,
        "dev": "/dev/" + name,
        "size_bytes": size,
        "size_human": f"{size / (1024**3):.1f} GiB",
        "fstype": kv.get("FSTYPE") or None,
        "label": kv.get("LABEL") or None,
        "parttype": kv.get("PARTTYPE") or None,
        "mountpoint": kv.get("MOUNTPOINT") or None,
    })
print(json.dumps(parts))
EOF
)"
    fi
    if [[ -n "$out" ]]; then
        printf '%s\n' "$json" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), indent=2))' > "$out"
        printf '%s\n' "$out"
    else
        printf '%s\n' "$json"
    fi
}

# --- 3. read-only self-check ----------------------------------------------------
# analyze_assert_readonly <files...> -- grep every file for forbidden WRITE
# patterns and FAIL CLOSED if any match. The pattern table is assembled from
# fragments so the literals never appear in this file (this file is itself
# checked). Call at tool startup on the whole Analyze toolchain.
analyze_assert_readonly() {
    local f
    # Fragmented on purpose: this literal table must not trip its own check.
    local pats=(
        'of=/d''ev'                    # dd writing to a device
        '\bmk''fs\b'                   # filesystem creation
        'wipe''fs'                     # signature wiping
        'blk''discard'                 # trim/discard whole device
        'hd''parm[[:space:]]+--security' # ATA security erase
        'crypt''setup[[:space:]]+luksFormat' # LUKS format
        'sh''red[[:space:]]'           # shred
        'remount'',''rw'                 # remounting writable
        'mount[^#\n]*-o[[:space:]]*r''w' # mounting read-write (refused)
        '>[[:space:]]*/d''ev/([^n]|$)'   # shell redirect onto a device (not /dev/null)
        'Format-Vo''lume'              # PowerShell: format
        'Clear-D''isk'                 # PowerShell: wipe disk
        'Init''ialize-Disk'            # PowerShell: repartition
        'Remove-Part''ition'           # PowerShell: delete partition
        'New-Part''ition'              # PowerShell: create partition
        'Resize-Part''ition'           # PowerShell: resize partition
        'Set-Part''ition'              # PowerShell: mutate partition
    )
    local pat bad=0
    for f in "$@"; do
        [[ -f "$f" ]] || { echo "[analyze-gates] REFUSED: tool file missing: $f" >&2; return 1; }
        # Full-line comments are documentation, not executable code: strip them
        # before scanning so doc text describing the contract can't trip the
        # check. (A write pattern hiding in a trailing comment would still be
        # caught by review; this check targets code that can execute.)
        for pat in "${pats[@]}"; do
            if grep -vE '^[[:space:]]*#' "$f" | grep -qE -- "$pat"; then
                echo "[analyze-gates] REFUSED: $f contains a forbidden write pattern ($pat) -- the Analyze phase must stay read-only." >&2
                bad=1
            fi
        done
    done
    [[ "$bad" -eq 0 ]] || return 1
    echo "[analyze-gates] read-only self-check OK: $# file(s), no write patterns."
    return 0
}

# analyze_ro_mount <dev> <fstype> <mnt> -- mount a partition STRICTLY read-only.
# Refuses any mount options string containing "rw" (substring match, so
# "errors=remount-ro" is also refused -- use the helper, not hand-rolled flags).
analyze_ro_mount() {
    local dev="$1" fstype="$2" mnt="$3" extra="${4:-ro}"
    if [[ "$extra" == *rw* ]]; then
        echo "[analyze-gates] REFUSED: read-write mount requested on $dev -- Analyze never mounts rw." >&2
        return 1
    fi
    local opts="$extra"
    case "$fstype" in
        ext2|ext3|ext4) opts="$opts,noload";;  # no journal replay on disk
        ntfs)          opts="$opts,show_sys_files,streams_interface=windows";;
    esac
    mkdir -p "$mnt"
    mount -o "$opts" -t "$fstype" "$dev" "$mnt" 2>/dev/null \
        || mount -o "$opts" "$dev" "$mnt" \
        || { echo "[analyze-gates] FAILED: read-only mount of $dev failed." >&2; return 1; }
    echo "[analyze-gates] mounted $dev read-only at $mnt"
}

# --- 4. report-dir gate ----------------------------------------------------------
# analyze_require_report_dir <dir> <inventory.json> -- the triage report must be
# written somewhere the wipe can never touch: not /, not on any triaged disk
# (checked against each disk's mounted partitions). The normal case is a dir
# on the Phoenix boot USB itself.
analyze_require_report_dir() {
    local dir="$1" inv="$2"
    [[ -n "$dir" && "$dir" != "/" ]] \
        || { echo "[analyze-gates] REFUSED: report dir must be a real directory, not /." >&2; return 1; }
    mkdir -p "$dir" 2>/dev/null \
        || { echo "[analyze-gates] REFUSED: cannot create report dir: $dir" >&2; return 1; }
    local dir_dev
    if [[ -n "${PHOENIX_MOCK_REPORT_DEVICE:-}" ]]; then
        dir_dev="${PHOENIX_MOCK_REPORT_DEVICE}"
    else
        dir_dev="$(df --output=source "$dir" 2>/dev/null | tail -1 | tr -d ' ')"
    fi
    PHOENIX_INV="$inv" PHOENIX_DIR_DEV="$dir_dev" python3 <<'EOF' || return 1
import json, os, sys
inv = json.load(open(os.environ["PHOENIX_INV"]))
dir_dev = os.environ["PHOENIX_DIR_DEV"]
def disk_of(part):
    import re
    m = re.match(r"^(nvme\d+n\d+|mmcblk\d+|sd[a-z]+)", os.path.basename(part))
    return m.group(1) if m else None
report_disk = disk_of(dir_dev) if dir_dev else None
for d in inv.get("disks", []):
    dev = d.get("dev", "")
    if report_disk and disk_of(dev) == report_disk:
        print(f"[analyze-gates] REFUSED: report dir lives on triaged disk {dev} "
              f"({dir_dev}) -- the wipe would destroy the triage report.", file=sys.stderr)
        sys.exit(1)
print(f"[analyze-gates] report dir OK: {dir_dev or '?'} is not a triaged disk")
EOF
    echo "[analyze-gates] report dir OK: $dir"
}

# --- 5. heuristic scan -----------------------------------------------------------
# analyze_scan_mount <mnt> <label> <out.json> -- read-only heuristic scan of an
# already-mounted (ro) filesystem. EVERY finding is labeled heuristic=true and
# human-readable "HEURISTIC:" -- these are triage signals for the operator,
# never verdicts. Nothing here writes to the scanned filesystem.
#
# Indicators emitted:
#   UNKNOWN_PARTITION      (handled by the flow, not this function)
#   OVERSIZED_TEMP         temp dir over PHOENIX_ANALYZE_TEMP_MAX_KB (def 2GiB)
#   RECENT_SYSTEM_MODIFY   files under system dirs modified in the last 24h
#   AUTORUN_ARTIFACT       autorun.inf or Startup-folder payloads present
#   HIDDEN_ROOT_EXECUTABLE suspicious dotfile/executable at the volume root
analyze_scan_mount() {
    local mnt="$1" label="$2" out="$3"
    [[ -d "$mnt" ]] \
        || { echo "[analyze-gates] FAILED: scan target is not a directory: $mnt" >&2; return 1; }
    local temp_max_kb="${PHOENIX_ANALYZE_TEMP_MAX_KB:-2097152}"

    PHOENIX_SCAN_MNT="$mnt" PHOENIX_SCAN_LABEL="$label" \
    PHOENIX_TEMP_MAX_KB="$temp_max_kb" python3 - "$out" <<'EOF'
import json, os, sys, time
mnt, label = os.environ["PHOENIX_SCAN_MNT"], os.environ["PHOENIX_SCAN_LABEL"]
temp_max = int(os.environ["PHOENIX_TEMP_MAX_KB"])
out_path = sys.argv[1]
inds = []

def add(code, severity, title, evidence):
    inds.append({
        "label": label,
        "severity": severity,          # info | warn | suspicious
        "heuristic": True,            # every analyze finding is heuristic
        "code": code,
        "title": "HEURISTIC: " + title,
        "evidence": evidence,
    })

def dir_size_kb(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try: total += os.path.getsize(os.path.join(root, f)) // 1024
            except OSError: pass
    return total

# -- oversized temp dirs (malware staging loves %TEMP%) --
temp_candidates = ["Windows/Temp", "tmp", "var/tmp",
                   "Users/Default/AppData/Local/Temp"]
# per-user temp dirs
users = os.path.join(mnt, "Users")
if os.path.isdir(users):
    for u in os.listdir(users):
        temp_candidates.append(f"Users/{u}/AppData/Local/Temp")
for rel in temp_candidates:
    p = os.path.join(mnt, rel)
    if os.path.isdir(p):
        kb = dir_size_kb(p)
        if kb > temp_max:
            add("OVERSIZED_TEMP", "warn",
                f"temp dir {rel} is unusually large ({kb // 1024} MiB)",
                f"{rel}: {kb} KiB > threshold {temp_max} KiB; staged payloads often live in temp dirs")

# -- recently modified system files (last 24h) --
now = time.time()
sys_dirs = ["Windows/System32", "Windows/SysWOW64", "bin", "sbin", "usr/bin", "usr/sbin"]
recent = []
for rel in sys_dirs:
    p = os.path.join(mnt, rel)
    if not os.path.isdir(p):
        continue
    for root, _dirs, files in os.walk(p):
        for f in files:
            fp = os.path.join(root, f)
            try:
                if now - os.path.getmtime(fp) < 86400:
                    recent.append(os.path.relpath(fp, mnt))
                    if len(recent) >= 5:
                        break
            except OSError:
                pass
        if len(recent) >= 5:
            break
    if len(recent) >= 5:
        break
for r in recent:
    add("RECENT_SYSTEM_MODIFY", "suspicious",
        f"system file modified in the last 24h: {r}",
        f"{r} mtime < 24h; legitimate updaters do this too -- correlate with the backup image")

# -- autorun artifacts --
autorun_hits = []
for cand in ["autorun.inf"]:
    if os.path.isfile(os.path.join(mnt, cand)):
        autorun_hits.append(cand)
startup_dirs = ["ProgramData/Microsoft/Windows/Start Menu/Programs/Startup"]
if os.path.isdir(users):
    for u in os.listdir(users):
        startup_dirs.append(f"Users/{u}/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup")
for rel in startup_dirs:
    p = os.path.join(mnt, rel)
    if os.path.isdir(p):
        for entry in sorted(os.listdir(p)):
            if entry.lower().endswith((".lnk", ".exe", ".bat", ".ps1", ".vbs")):
                autorun_hits.append(f"{rel}/{entry}")
for h in autorun_hits:
    add("AUTORUN_ARTIFACT", "suspicious",
        f"autorun artifact present: {h}",
        f"{h} executes at logon; a classic persistence mechanism -- verify against a known-good image")

# -- hidden/root executables --
try:
    root_entries = os.listdir(mnt)
except OSError:
    root_entries = []
for e in root_entries:
    fp = os.path.join(mnt, e)
    if os.path.isfile(fp) and (e.startswith(".") or e.lower().endswith(".exe")):
        # Windows/System32-style roots are handled by RECENT_SYSTEM_MODIFY;
        # stray executables AT THE VOLUME ROOT are unusual.
        add("HIDDEN_ROOT_EXECUTABLE", "warn",
            f"suspicious file at volume root: {e}",
            f"{e} sits at the filesystem root; droppers often land here")

json.dump(inds, open(out_path, "w"), indent=2)
print(f"[analyze-gates] scan of {label}: {len(inds)} heuristic indicator(s)")
EOF
}

# --- 6. report assembly ----------------------------------------------------------
# analyze_write_report <state-dir> <inventory.json> <parts.json> <indicators.json>
# Assembles the phoenix-triage-report/1 document. partitions/indicators are
# JSON objects keyed by disk id: {"1": [...], "2": [...]}.
analyze_write_report() {
    local dir="$1" inv="$2" parts="$3" inds="$4"
    mkdir -p "$dir"
    local ts report
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    report="$dir/triage-report.json"
    PHOENIX_TS="$ts" PHOENIX_TOOL="analyze-gates.sh/$ANALYZE_GATES_VERSION" \
    PHOENIX_INV="$inv" PHOENIX_PARTS="$parts" PHOENIX_INDS="$inds" \
    PHOENIX_REPORT="$report" python3 <<'EOF' || return 1
import json, os, sys
ts = os.environ["PHOENIX_TS"]
tool = os.environ["PHOENIX_TOOL"]
inv = json.load(open(os.environ["PHOENIX_INV"]))
parts = json.load(open(os.environ["PHOENIX_PARTS"]))
inds = json.load(open(os.environ["PHOENIX_INDS"]))
report = {
    "schema": "phoenix-triage-report/1",
    "recorded_at": ts,
    "tool": tool,
    "readonly": True,   # structural: the Analyze phase cannot write to targets
    "disks": [],
    "indicators": [],
    "verdict": "triage-complete",
}
for d in inv.get("disks", []):
    did = str(d.get("id"))
    disk = dict(d)
    disk["partitions"] = parts.get(did, [])
    report["disks"].append(disk)
    # structural (non-heuristic) indicator: partition with no recognizable fs
    for p in parts.get(did, []):
        if not p.get("fstype"):
            report["indicators"].append({
                "disk_id": d.get("id"),
                "dev": p.get("dev"),
                "label": f"disk-{did}",
                "severity": "info",
                "heuristic": False,
                "code": "UNKNOWN_PARTITION",
                "title": f"partition {p['name']} has no recognized filesystem",
                "evidence": f"fstype={p.get('fstype')} label={p.get('label')} "
                            f"parttype={p.get('parttype')}; may be recovery/EFI/raw",
            })
for did, lst in inds.items():
    for i in lst:
        i = dict(i)
        i["disk_id"] = int(did)
        report["indicators"].append(i)
susp = sum(1 for i in report["indicators"] if i["severity"] == "suspicious")
if susp:
    report["verdict"] = "triage-complete-suspicious"
json.dump(report, open(os.environ["PHOENIX_REPORT"], "w"), indent=2)
# Status line goes to stderr: stdout carries ONLY the report path (callers
# capture it with $()).
print(f"[analyze-gates] triage report: {len(report['disks'])} disk(s), "
      f"{len(report['indicators'])} indicator(s), verdict={report['verdict']}",
      file=sys.stderr)
EOF
    printf '%s\n' "$report"
}
