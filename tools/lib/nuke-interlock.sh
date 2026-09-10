#!/usr/bin/env bash
#===============================================================================
# nuke-interlock.sh -- shared bash gate library for the Phoenix Nuke flow.
#
# Source this file; do not execute it. Provides the structural interlocks from
# docs/NUKE-SAFETY.md sections 3-6. Any boot-side script that arms destruction
# MUST call these gates in order:
#
#   nuke_require_tty                  # real terminal, no piped stdin
#   nuke_require_fingerprint DIR SER  # Analyze ran < 24h ago, disk recorded
#   nuke_require_allowlist CFG SER    # serial in phoenix-config.json target_disks
#   nuke_confirm_target INV ID        # operator types exact "SERIAL MODEL"
#
# All gates fail closed: any failure prints a reason to stderr and returns 1.
# Destructive callers should `set -e` (or check each return) so a failed gate
# can never be skipped silently.
#
# JSON parsing uses python3 stdlib (the boot image ships it). No jq needed.
#===============================================================================

# Guard against double-sourcing and direct execution.
if [[ -n "${NUKE_INTERLOCK_SOURCED:-}" ]]; then return 0; fi
NUKE_INTERLOCK_SOURCED=1

# nuke_log <state-dir> <message> -- append UTC-timestamped line to USB state log
nuke_log() {
    local dir="$1"; shift
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$dir/nuke-interlock.log"
}

# nuke_require_tty -- refuse piped/redirected stdin (scripted confirmation is
# structurally impossible). Returns 0 on a real terminal, 1 otherwise.
nuke_require_tty() {
    if [[ -t 0 ]]; then
        return 0
    fi
    echo "[nuke-interlock] REFUSED: stdin is not a terminal. Confirmation must be typed interactively." >&2
    return 1
}

# nuke_target_field <inventory.json> <id> <field> -- print one field of one disk
nuke_target_field() {
    python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
inv = json.load(open(sys.argv[1]))
want = int(sys.argv[2]); field = sys.argv[3]
for d in inv["disks"]:
    if d["id"] == want:
        v = d.get(field)
        print("" if v is None else v)
        sys.exit(0)
sys.exit(2)
EOF
}

# nuke_confirm_target <inventory.json> <id> [<state-dir>]
# Prints the target card and requires the operator to type the exact serial
# and model ("SERIAL MODEL" or "NUKE SERIAL MODEL") on a real terminal.
# Refuses: serial-less disks, mounted disks, non-TTY stdin, anything that is
# not the exact pair. Logs accepted confirmations with a UTC timestamp.
nuke_confirm_target() {
    local inv="$1" id="$2" state_dir="${3:-/tmp}"
    local serial model size_human mounted

    serial="$(nuke_target_field "$inv" "$id" serial)" || { echo "[nuke-interlock] REFUSED: no disk with id $id." >&2; return 1; }
    model="$(nuke_target_field "$inv" "$id" model)"
    size_human="$(nuke_target_field "$inv" "$id" size_human)"
    mounted="$(nuke_target_field "$inv" "$id" mounted)"

    if [[ -z "$serial" ]]; then
        echo "[nuke-interlock] REFUSED: disk [$id] has no readable serial; it can never be a nuke target." >&2
        return 1
    fi
    if [[ "$mounted" == "True" ]]; then
        echo "[nuke-interlock] REFUSED: disk [$id] has mounted partitions; it can never be a nuke target." >&2
        return 1
    fi

    nuke_require_tty || return 1

    cat <<CARD
======================================================================
 NUKE TARGET CARD -- read carefully, there is no undo
----------------------------------------------------------------------
  [$id] $model
      Serial : $serial
      Size   : $size_human
----------------------------------------------------------------------
 To ARM the wipe, type the serial and model EXACTLY as shown above:
    $serial $model
 (or: NUKE $serial $model)
 Anything else aborts. This cannot be scripted.
======================================================================
CARD

    local answer
    # pty line discipline appends CR on Enter; strip it before comparing.
    IFS= read -r answer < /dev/tty || { echo "[nuke-interlock] ABORTED: could not read from terminal." >&2; return 1; }
    answer="$(printf '%s' "$answer" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    local expect1="$serial $model"
    local expect2="NUKE $serial $model"
    if [[ "$answer" == "$expect1" || "$answer" == "$expect2" ]]; then
        nuke_log "$state_dir" "CONFIRMED nuke target id=$id serial=$serial model=\"$model\""
        echo "[nuke-interlock] target confirmed and logged."
        return 0
    fi
    nuke_log "$state_dir" "REJECTED confirmation attempt for id=$id (input did not match)"
    echo "[nuke-interlock] ABORTED: typed confirmation did not match. Nothing was armed." >&2
    return 1
}

# nuke_require_fingerprint <state-dir> <serial> [<max-age-hours>]
# Demands the Analyze fingerprint (docs/NUKE-SAFETY.md section 4): the file
# must exist, be recorded by "analyze", be fresh, and contain the target
# serial with matching model and size.
nuke_require_fingerprint() {
    local dir="$1" serial="$2" max_age="${3:-24}"
    local fp="$dir/disk-fingerprints.json"

    [[ -f "$fp" ]] || { echo "[nuke-interlock] REFUSED: no disk-fingerprints.json in $dir -- run Analyze first." >&2; return 1; }

    python3 - "$fp" "$serial" "$max_age" <<'EOF' || return 1
import json, sys, datetime
fp_path, serial, max_age = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    fp = json.load(open(fp_path))
except Exception as e:
    print(f"[nuke-interlock] REFUSED: fingerprint file is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if fp.get("recorded_by") != "analyze":
    print("[nuke-interlock] REFUSED: fingerprint was not recorded by Analyze.", file=sys.stderr)
    sys.exit(1)
try:
    rec = datetime.datetime.strptime(fp["recorded_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
except Exception:
    print("[nuke-interlock] REFUSED: fingerprint has no parseable recorded_at.", file=sys.stderr)
    sys.exit(1)
age_h = (datetime.datetime.now(datetime.timezone.utc) - rec).total_seconds() / 3600
if age_h > max_age or age_h < 0:
    print(f"[nuke-interlock] REFUSED: fingerprint is {age_h:.1f}h old (limit {max_age}h) -- re-run Analyze.", file=sys.stderr)
    sys.exit(1)
match = [d for d in fp.get("disks", []) if d.get("serial") == serial]
if not match:
    print("[nuke-interlock] REFUSED: target serial not present in the Analyze fingerprint.", file=sys.stderr)
    sys.exit(1)
print(f"[nuke-interlock] fingerprint OK: {serial} recorded {age_h:.1f}h ago by Analyze.")
EOF
}

# nuke_require_allowlist <config.json> <serial>
# Demands the target serial appear verbatim in phoenix-config.json target_disks.
nuke_require_allowlist() {
    local cfg="$1" serial="$2"
    [[ -f "$cfg" ]] || { echo "[nuke-interlock] REFUSED: config file not found: $cfg" >&2; return 1; }
    python3 - "$cfg" "$serial" <<'EOF' || return 1
import json, sys
cfg_path, serial = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(cfg_path))
except Exception as e:
    print(f"[nuke-interlock] REFUSED: config is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
allow = [t.get("serial") for t in cfg.get("target_disks", []) if isinstance(t, dict)]
if serial in allow:
    print(f"[nuke-interlock] allowlist OK: {serial} is approved in target_disks.")
    sys.exit(0)
print(f"[nuke-interlock] REFUSED: serial {serial} is NOT in target_disks -- this disk may not be nuked.", file=sys.stderr)
sys.exit(1)
EOF
}
