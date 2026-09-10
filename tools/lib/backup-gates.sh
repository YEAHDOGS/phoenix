#!/usr/bin/env bash
#===============================================================================
# backup-gates.sh -- shared bash gate library for the Phoenix BACKUP phase.
#
# Source this file; do not execute it. It sources tools/lib/nuke-interlock.sh
# and reuses its typed-confirmation + TTY + fingerprint gates, adding the
# backup-specific structural checks:
#
#   backup_require_source INV ID         # enumerated disk, serial, not mounted
#   backup_require_destination DIR SIZE DEV   # exists, free space, not on source
#   backup_image_disk DEV DIR LABEL [STATE]   # dd + sha256 + manifest + proof
#   backup_require_image_proof DIR SERIAL    # gate the nuke side can require
#
# Backup safety model (mirrors the nuke interlock philosophy):
#  1. SOURCE: the disk to image must come from the enumeration table, have a
#     readable manufacturer serial, and have no mounted partitions (imaging a
#     live-mounted disk produces a torn image AND risks the boot environment).
#     A serial-less disk is refused -- without a serial there is no target
#     card to confirm against and no proof to bind the image to.
#  2. DESTINATION: the image target dir must exist, have >= the full source
#     size free (raw image, no compression assumed), and must NOT live on the
#     source disk itself -- writing the image onto the disk being imaged is
#     the backup-phase equivalent of nuking the wrong disk.
#  3. CONFIRMATION: the operator types the exact "SERIAL MODEL" pair on a real
#     terminal (nuke_confirm_target). Imaging the wrong disk is irreversible
#     in practice (hours lost on an infected machine you cannot re-boot).
#  4. PROOF: every image is hashed during the write; the manifest and a
#     backup-image-proof.json bind serial+model+size+sha256. The nuke phase's
#     image-proof gate consumes this proof ("verified image or no wipe").
#
# TESTING: all disk/filesystem touching is mockable:
#   PHOENIX_MOCK_DD=1            -- write a small fake image instead of dd
#   PHOENIX_MOCK_DF_AVAIL=<bytes>-- fake free space for the destination
#   PHOENIX_MOCK_DF_DEVICE=<dev> -- fake device backing the destination dir
#===============================================================================

# Guard against double-sourcing and direct execution.
if [[ -n "${BACKUP_GATES_SOURCED:-}" ]]; then return 0; fi
BACKUP_GATES_SOURCED=1

# shellcheck disable=SC1090
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nuke-interlock.sh"

BACKUP_GATES_VERSION="0.1.0"

# backup_log <state-dir> <message> -- UTC-timestamped line to the backup log
backup_log() {
    local dir="$1"; shift
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$dir/backup-gates.log"
}

# --- source-disk gate ----------------------------------------------------------
# backup_require_source <inventory.json> <id>
# Validates the chosen source disk. On success sets globals:
#   BACKUP_SERIAL BACKUP_MODEL BACKUP_DEV BACKUP_SIZE_BYTES BACKUP_SIZE_HUMAN
backup_require_source() {
    local inv="$1" id="$2"
    local serial model dev size mounted

    serial="$(nuke_target_field "$inv" "$id" serial)" \
        || { echo "[backup-gates] REFUSED: no disk with id $id." >&2; return 1; }
    if [[ -z "$serial" ]]; then
        echo "[backup-gates] REFUSED: disk [$id] has no readable serial -- it can never be an image source." >&2
        return 1
    fi
    mounted="$(nuke_target_field "$inv" "$id" mounted)"
    if [[ "$mounted" == "True" ]]; then
        echo "[backup-gates] REFUSED: disk [$id] has mounted partitions -- unmount everything before imaging." >&2
        return 1
    fi

    BACKUP_SERIAL="$serial"
    BACKUP_MODEL="$(nuke_target_field "$inv" "$id" model)"
    BACKUP_DEV="$(nuke_target_field "$inv" "$id" dev)"
    BACKUP_SIZE_BYTES="$(nuke_target_field "$inv" "$id" size_bytes)"
    BACKUP_SIZE_HUMAN="$(nuke_target_field "$inv" "$id" size_human)"
    export BACKUP_SERIAL BACKUP_MODEL BACKUP_DEV BACKUP_SIZE_BYTES BACKUP_SIZE_HUMAN
    [[ -n "$BACKUP_DEV" && -n "$BACKUP_SIZE_BYTES" ]] \
        || { echo "[backup-gates] REFUSED: disk [$id] is missing dev/size fields." >&2; return 1; }
    echo "[backup-gates] source OK: [$id] $BACKUP_MODEL SN $BACKUP_SERIAL ($BACKUP_SIZE_HUMAN)"
    return 0
}

# --- destination gates ---------------------------------------------------------
# backup_dest_free_bytes <dir> -- free bytes on the filesystem holding <dir>
backup_dest_free_bytes() {
    if [[ -n "${PHOENIX_MOCK_DF_AVAIL:-}" ]]; then
        printf '%s' "$PHOENIX_MOCK_DF_AVAIL"; return 0
    fi
    df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '
}

# backup_dest_device <dir> -- device node backing the filesystem holding <dir>
backup_dest_device() {
    if [[ -n "${PHOENIX_MOCK_DF_DEVICE:-}" ]]; then
        printf '%s' "$PHOENIX_MOCK_DF_DEVICE"; return 0
    fi
    df --output=source "$1" 2>/dev/null | tail -1 | tr -d ' '
}

# backup_require_destination <dir> <size_bytes> <source-dev>
# The destination must exist, be a directory, have the full source size free,
# and not live on the source disk itself.
backup_require_destination() {
    local dir="$1" size_bytes="$2" source_dev="$3"
    [[ -d "$dir" ]] \
        || { echo "[backup-gates] REFUSED: destination is not a directory: $dir" >&2; return 1; }

    local backing
    backing="$(backup_dest_device "$dir")"
    # The destination must not live on the source disk: strip the partition
    # suffix off the backing device and compare disk names.
    #   sdb1 -> sdb | nvme0n1p2 -> nvme0n1 | mmcblk0p1 -> mmcblk0 | sdb -> sdb
    local backing_disk src_base
    backing_disk="$(basename "$backing")"
    src_base="$(basename "$source_dev")"
    if [[ "$backing_disk" =~ ^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p[0-9]+$ ]]; then
        backing_disk="${BASH_REMATCH[1]}"
    elif [[ "$backing_disk" =~ ^(sd[a-z]+)[0-9]+$ ]]; then
        backing_disk="${BASH_REMATCH[1]}"
    fi
    if [[ "$backing_disk" == "$src_base" ]]; then
        echo "[backup-gates] REFUSED: destination lives on the source disk ($backing) -- the image would overwrite what it is imaging." >&2
        return 1
    fi

    local free
    free="$(backup_dest_free_bytes "$dir")"
    [[ "$free" =~ ^[0-9]+$ ]] \
        || { echo "[backup-gates] REFUSED: could not determine free space for $dir." >&2; return 1; }
    if (( free < size_bytes )); then
        echo "[backup-gates] REFUSED: destination has ${free}B free but the source needs ${size_bytes}B (full-size headroom required)." >&2
        return 1
    fi
    echo "[backup-gates] destination OK: $dir (${free}B free, need ${size_bytes}B)"
    return 0
}

# --- imaging -------------------------------------------------------------------
# backup_image_disk <source-dev> <dest-dir> <label> [state-dir]
# Writes <label>.img via dd, hashes it, and records <label>.img.sha256,
# <label>-manifest.json, and backup-image-proof.json.
# Sets BACKUP_IMG_PATH and BACKUP_IMG_SHA256 on success.
backup_image_disk() {
    local dev="$1" dest="$2" label="$3" state_dir="${4:-/tmp}"
    mkdir -p "$state_dir"
    local img="$dest/$label.img"

    [[ -e "$img" ]] && {
        echo "[backup-gates] REFUSED: $img already exists -- will not overwrite an existing image." >&2
        return 1
    }

    local started finished sha
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    backup_log "$state_dir" "START image dev=$dev -> $img serial=$BACKUP_SERIAL"

    if [[ -n "${PHOENIX_MOCK_DD:-}" ]]; then
        # TEST MODE: fake a small image so the flow is exercisable without disks.
        printf 'PHOENIX-FAKE-IMAGE serial=%s dev=%s\n' "$BACKUP_SERIAL" "$dev" > "$img"
    else
        dd "if=$dev" "of=$img" bs=4M conv=noerror,sync status=progress \
            || { echo "[backup-gates] FAILED: dd exited nonzero -- image incomplete." >&2; return 1; }
    fi
    sha="$(sha256sum "$img" | awk '{print $1}')"
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s  %s\n' "$sha" "$(basename "$img")" > "$img.sha256"

    # Re-read the hash file (independent verify pass) -- the proof binds it.
    # The sidecar names the basename, so verify from the destination dir.
    local verify
    verify="$(cd "$dest" && sha256sum -c "$(basename "$img").sha256" 2>/dev/null)" \
        || { echo "[backup-gates] FAILED: post-write hash verification failed." >&2; return 1; }

    local img_size
    img_size="$(stat -c%s "$img")"

    python3 - "$state_dir" "$label" "$img" "$sha" "$img_size" "$started" "$finished" <<'EOF'
import json, sys, os
state_dir, label, img, sha, img_size, started, finished = sys.argv[1:8]
manifest = {
    "schema": "phoenix-backup-manifest/1",
    "label": label,
    "image": os.path.basename(img),
    "sha256": sha,
    "image_bytes": int(img_size),
    "source": {
        "serial": os.environ.get("BACKUP_SERIAL", ""),
        "model": os.environ.get("BACKUP_MODEL", ""),
        "dev": os.environ.get("BACKUP_DEV", ""),
        "size_bytes": int(os.environ.get("BACKUP_SIZE_BYTES", "0")),
        "size_human": os.environ.get("BACKUP_SIZE_HUMAN", ""),
    },
    "tool": "backup-gates.sh/" + os.environ.get("BACKUP_GATES_VERSION", "?"),
    "started_at": started,
    "finished_at": finished,
    "verified": True,
}
manifest_path = os.path.join(state_dir, f"{label}-manifest.json")
json.dump(manifest, open(manifest_path, "w"), indent=2)
proof = {
    "schema": "phoenix-image-proof/1",
    "serial": manifest["source"]["serial"],
    "model": manifest["source"]["model"],
    "image": img,
    "sha256": sha,
    "verified": True,
    "verified_at": finished,
    "manifest": manifest_path,
}
json.dump(proof, open(os.path.join(state_dir, "backup-image-proof.json"), "w"), indent=2)
print(f"[backup-gates] image verified: {img} sha256:{sha[:16]}...")
EOF
    export BACKUP_IMG_PATH="$img" BACKUP_IMG_SHA256="$sha"
    backup_log "$state_dir" "DONE image $img sha256=$sha"
}

# --- image-proof gate (consumed by the nuke phase) ------------------------------
# backup_require_image_proof <state-dir> <serial>
# Demands a valid proof that this exact serial was imaged and verified:
# proof file exists, verified=true, serial matches, the image + sha256 files
# exist, and the sha256 file matches the proof hash.
backup_require_image_proof() {
    local dir="$1" serial="$2"
    local proof="$dir/backup-image-proof.json"
    [[ -f "$proof" ]] \
        || { echo "[backup-gates] REFUSED: no backup-image-proof.json in $dir -- image the disk before any wipe." >&2; return 1; }
    PHOENIX_PROOF_SERIAL="$serial" python3 - "$proof" <<'EOF' || return 1
import json, sys, os
proof = json.load(open(sys.argv[1]))
serial = os.environ["PHOENIX_PROOF_SERIAL"]
def fail(msg):
    print(f"[backup-gates] REFUSED: {msg}", file=sys.stderr); sys.exit(1)
if proof.get("schema") != "phoenix-image-proof/1": fail("unknown proof schema")
if proof.get("verified") is not True: fail("proof is not marked verified")
if proof.get("serial") != serial: fail(f"proof is for serial {proof.get('serial')}, not {serial}")
img, sha = proof.get("image"), proof.get("sha256")
if not img or not os.path.isfile(img): fail(f"proof image missing: {img}")
sha_file = img + ".sha256"
if not os.path.isfile(sha_file): fail(f"sha256 sidecar missing: {sha_file}")
recorded = open(sha_file).read().split()[0]
if recorded != sha: fail("sha256 sidecar does not match proof")
print(f"[backup-gates] image proof OK: {serial} verified image {os.path.basename(img)}")
EOF
}
