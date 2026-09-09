#!/usr/bin/env bash
#===============================================================================
# reinstall-gates.sh -- shared bash gate library for the Phoenix Reinstall flow.
#
# Source this file; do not execute it. Implements docs/REINSTALL.md sections 2-3.
# The destructive-side interlocks (TTY, typed confirmation) come from
# tools/lib/nuke-interlock.sh -- source that file too and call its gates last:
#
#   source tools/lib/nuke-interlock.sh
#   source tools/lib/reinstall-gates.sh
#   reinstall_require_target_blank    INV ID FP        # disk is provably blank
#                                             (FP = disk-fingerprints.json)
#   reinstall_require_artifacts       UNATTEND ISO  # answer file + ISO staged
#   reinstall_require_config_match    CFG UNATTEND ISO  # staged files match config
#   reinstall_require_chain_of_custody STATE SERIAL     # backup+nuke on record
#   nuke_require_tty                                   # real terminal
#   nuke_confirm_target               INV ID STATE     # operator types SERIAL MODEL
#
# Chain-of-custody contract (consumed, not produced, by this phase):
#   <state>/backup-image-proof.json  -- schema phoenix-image-proof/1,
#       verified == true, serial == target serial  (written by Backup flow)
#   <state>/nuke-completed.json       -- schema phoenix-nuke-completion/1,
#       serial == target serial, completed_at present (written by Nuke flow)
#
# All gates fail closed: any failure prints a reason to stderr and returns 1.
# Callers must `set -e` (or check each return) so a failed gate can never be
# skipped silently. JSON parsing uses python3 stdlib (the boot image ships it).
#===============================================================================

# Guard against double-sourcing and direct execution.
if [[ -n "${REINSTALL_GATES_SOURCED:-}" ]]; then return 0; fi
REINSTALL_GATES_SOURCED=1

# SHA-256 of 1 MiB of zero bytes. Get-DiskInventory.sh records partition_hash
# as "sha256:<hex> of the disk's first 1 MiB" -- the Nuke flow zeroes the
# leading sectors, so a genuinely nuked disk hashes to exactly this value.
# A disk with ANY partition table or filesystem metadata can never match.
REINSTALL_BLANK_HASH="sha256:30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"

# reinstall_log <state-dir> <message> -- append UTC-timestamped line to USB state log
reinstall_log() {
    local dir="$1"; shift
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$dir/reinstall-gates.log"
}

# reinstall_target_field <inventory.json> <id> <field> -- print one field of one disk
reinstall_target_field() {
    python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
inv = json.load(open(sys.argv[1]))
want = int(sys.argv[2]); field = sys.argv[3]
for d in inv["disks"]:
    if d["id"] == want:
        v = d.get(field)
        print("" if v is None else v)
        sys.exit(0)
sys.exit(1)
EOF
}

# reinstall_target_fingerprint <fingerprints.json> <serial> -- print the
# partition_hash recorded for a serial (the first-1MiB probe).
reinstall_target_fingerprint() {
    python3 - "$1" "$2" <<'EOF'
import json, sys
fp = json.load(open(sys.argv[1]))
serial = sys.argv[2]
for d in fp["disks"]:
    if str(d.get("serial")) == serial:
        v = d.get("partition_hash")
        print("" if v is None else v)
        sys.exit(0)
sys.exit(1)
EOF
}

# reinstall_require_target_blank <inventory.json> <id> <fingerprints.json>
# The target must be provably blank: readable serial, nothing mounted, and the
# first-1MiB hash recorded in the fingerprint file equals the all-zeros
# constant (i.e. the Nuke flow blanked it). The inventory carries identity;
# the fingerprints carry the zero-probe -- both come from one enumeration run
# (Get-DiskInventory.sh --save-state), so they cannot disagree about the disk.
reinstall_require_target_blank() {
    local inv="$1" id="$2" fp="$3"
    local serial mounted phash

    serial="$(reinstall_target_field "$inv" "$id" serial)" \
        || { echo "[reinstall] REFUSED: no disk with id $id in inventory." >&2; return 1; }
    if [[ -z "$serial" ]]; then
        echo "[reinstall] REFUSED: disk [$id] has no readable serial; it cannot be a reinstall target." >&2
        return 1
    fi
    mounted="$(reinstall_target_field "$inv" "$id" mounted)"
    if [[ "$mounted" == "True" ]]; then
        echo "[reinstall] REFUSED: disk [$id] has mounted partitions; a blank disk has none." >&2
        return 1
    fi
    if [[ ! -f "$fp" ]]; then
        echo "[reinstall] REFUSED: no fingerprint file $fp -- rerun the enumeration with --save-state." >&2
        return 1
    fi
    phash="$(reinstall_target_fingerprint "$fp" "$serial")" \
        || { echo "[reinstall] REFUSED: serial $serial has no fingerprint record." >&2; return 1; }
    if [[ "$phash" != "$REINSTALL_BLANK_HASH" ]]; then
        echo "[reinstall] REFUSED: disk [$id] first-1MiB hash is not all-zeros." >&2
        echo "[reinstall]   The disk still carries partition/filesystem metadata -- it was not nuked." >&2
        echo "[reinstall]   Installing here would pave over a live disk. Aborting." >&2
        return 1
    fi
    echo "[reinstall] target [$id] is provably blank (serial $serial, zeroed leading sectors)."
    return 0
}

# reinstall_require_artifacts <unattend-file> <iso-file>
# The answer file and the Windows ISO must both exist, be readable, and be
# non-empty. A missing answer file means Setup would prompt mid-install --
# exactly the headless flow this phase must never produce.
reinstall_require_artifacts() {
    local unattend="$1" iso="$2"
    for f in "$unattend" "$iso"; do
        if [[ ! -f "$f" ]]; then
            echo "[reinstall] REFUSED: required artifact missing: $f" >&2
            return 1
        fi
        if [[ ! -r "$f" ]]; then
            echo "[reinstall] REFUSED: required artifact not readable: $f" >&2
            return 1
        fi
        if [[ ! -s "$f" ]]; then
            echo "[reinstall] REFUSED: required artifact is empty: $f" >&2
            return 1
        fi
    done
    echo "[reinstall] artifacts present: $(basename "$unattend"), $(basename "$iso")."
    return 0
}

# reinstall_require_config_match <config.json> <unattend-file> <iso-file>
# The staged files must agree with phoenix-config.json: the reinstall boot
# entry enabled, platform windows, and the answer-file basename matching the
# config's unattend.answer_file. A stale config (ISO renamed without
# rebuilding the USB) is a mismatched install waiting to happen.
reinstall_require_config_match() {
    local cfg="$1" unattend="$2" iso="$3"
    python3 - "$cfg" "$unattend" "$iso" <<'EOF'
import json, os, sys
cfg_path, unattend, iso = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(cfg_path))
except Exception as e:
    print(f"[reinstall] REFUSED: config is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
be = cfg.get("boot_entries", {})
if not be.get("reinstall", False):
    print("[reinstall] REFUSED: config boot_entries.reinstall is not enabled.", file=sys.stderr)
    sys.exit(1)
if cfg.get("reinstall", {}).get("platform", "windows") != "windows":
    print("[reinstall] REFUSED: config reinstall.platform is not 'windows' (linux blade is future work).", file=sys.stderr)
    sys.exit(1)
want_unattend = os.path.basename(cfg.get("unattend", {}).get("answer_file", "/autounattend.xml"))
got_unattend = os.path.basename(unattend)
if want_unattend.lower() != got_unattend.lower():
    print(f"[reinstall] REFUSED: staged answer file '{got_unattend}' does not match config unattend.answer_file '{want_unattend}'.", file=sys.stderr)
    sys.exit(1)
print(f"[reinstall] config consistent: reinstall enabled, platform windows, answer file {got_unattend}, ISO {os.path.basename(iso)}.")
EOF
}

# reinstall_require_chain_of_custody <state-dir> <serial>
# Reinstall is Phase 4 of a four-phase runbook. The state dir must contain a
# verified Backup proof AND a completed Nuke record for this exact serial.
# Running Reinstall without Phases 2-3 on record means the operator skipped
# the image-and-wipe -- refuse.
reinstall_require_chain_of_custody() {
    local state="$1" serial="$2"
    local proof="$state/backup-image-proof.json" nuke="$state/nuke-completed.json"

    if [[ ! -f "$proof" ]]; then
        echo "[reinstall] REFUSED: no backup-image-proof.json in $state -- the disk was never imaged." >&2
        return 1
    fi
    python3 - "$proof" "$serial" <<'EOF'
import json, sys
proof, serial = sys.argv[1], sys.argv[2]
try:
    p = json.load(open(proof))
except Exception as e:
    print(f"[reinstall] REFUSED: backup-image-proof.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if p.get("schema") != "phoenix-image-proof/1":
    print(f"[reinstall] REFUSED: backup proof schema is '{p.get('schema')}', want phoenix-image-proof/1.", file=sys.stderr)
    sys.exit(1)
if p.get("verified") is not True:
    print("[reinstall] REFUSED: backup proof is not verified -- image or no wipe was never satisfied.", file=sys.stderr)
    sys.exit(1)
if str(p.get("serial")) != serial:
    print(f"[reinstall] REFUSED: backup proof is for serial '{p.get('serial')}', target is '{serial}'.", file=sys.stderr)
    sys.exit(1)
print(f"[reinstall] backup chain: verified image proof for serial {serial}.")
EOF
    [[ $? -eq 0 ]] || return 1

    if [[ ! -f "$nuke" ]]; then
        echo "[reinstall] REFUSED: no nuke-completed.json in $state -- the disk was never wiped." >&2
        return 1
    fi
    python3 - "$nuke" "$serial" <<'EOF'
import json, sys
nuke, serial = sys.argv[1], sys.argv[2]
try:
    n = json.load(open(nuke))
except Exception as e:
    print(f"[reinstall] REFUSED: nuke-completed.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if n.get("schema") != "phoenix-nuke-completion/1":
    print(f"[reinstall] REFUSED: nuke record schema is '{n.get('schema')}', want phoenix-nuke-completion/1.", file=sys.stderr)
    sys.exit(1)
if str(n.get("serial")) != serial:
    print(f"[reinstall] REFUSED: nuke record is for serial '{n.get('serial')}', target is '{serial}'.", file=sys.stderr)
    sys.exit(1)
if not n.get("completed_at"):
    print("[reinstall] REFUSED: nuke record has no completed_at timestamp.", file=sys.stderr)
    sys.exit(1)
print(f"[reinstall] nuke chain: wipe completed {n['completed_at']} for serial {serial}.")
EOF
}
