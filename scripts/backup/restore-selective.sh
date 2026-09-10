#!/bin/bash
# Phoenix selective restore (Linux rescue side): bash twin of restore-selective.ps1.
# Applies a backup manifest (backup-selective.sh) onto a NEW machine.
#
# Usage:
#   restore-selective.sh --manifest-dir DIR --target-root DIR [--app chrome|all]
#                        [--profile-dir DIR] [--apply] [--confirm-word WORD]
#
#   PHOENIX_HOME overrides ~ expansion when matching profile paths (default: $HOME).
#   Defaults to read-only plan mode. Nothing is written without --apply.
#
# SAFETY INTERLOCKS:
#   1. --target-root is REQUIRED, no default.
#   2. Refuses when the canonical target equals the manifest's source_home.
#   3. Refuses when the target filesystem id / UUID matches the source
#      fingerprint (restoring onto the disk the backup came from is refused).
#   4. Refuses when the target is inside the backup directory.
#   5. --apply prints the full plan and requires the operator to type RESTORE
#      (--confirm-word RESTORE bypasses the prompt for GUI/scripted use, loudly).

set -euo pipefail

MANIFEST_DIR=""
TARGET_ROOT=""
APP="all"
APPLY=0
CONFIRM_WORD=""
PROFILE_DIR="$(cd "$(dirname "$0")/../../profiles" && pwd)"
HOME_ROOT="${PHOENIX_HOME:-$HOME}"

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest-dir) MANIFEST_DIR="$2"; shift 2 ;;
        --target-root)  TARGET_ROOT="$2"; shift 2 ;;
        --app)          APP="$2"; shift 2 ;;
        --apply)        APPLY=1; shift ;;
        --confirm-word) CONFIRM_WORD="$2"; shift 2 ;;
        --profile-dir)  PROFILE_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -n "$MANIFEST_DIR" ] || { echo "error: --manifest-dir is required" >&2; exit 1; }
[ -n "$TARGET_ROOT" ]  || { echo "error: --target-root is required (no default — restore never guesses the target)" >&2; exit 1; }
[ -f "$MANIFEST_DIR/manifest.json" ] || { echo "error: manifest.json not found in $MANIFEST_DIR" >&2; exit 1; }
[ -d "$TARGET_ROOT" ] || { echo "error: --target-root '$TARGET_ROOT' does not exist or is not a directory" >&2; exit 1; }

TARGET_CANON="$(readlink -f "$TARGET_ROOT")"
MANIFEST_CANON="$(readlink -f "$MANIFEST_DIR")"
case "$TARGET_CANON" in
    "$MANIFEST_CANON"|"$MANIFEST_CANON"/*)
        echo "INTERLOCK: target is inside the backup directory — refusing to restore a backup onto itself" >&2; exit 1 ;;
esac

META="$MANIFEST_DIR/manifest-meta.json"
SRC_HOME=""; SRC_FSID=""; SRC_UUID=""
if [ -f "$META" ]; then
    SRC_HOME="$(jq -r '.source_home // ""' "$META")"
    SRC_FSID="$(jq -r '.source_fs_id // ""' "$META")"
    SRC_UUID="$(jq -r '.source_uuid // ""' "$META")"
    [ "$SRC_UUID" = "null" ] && SRC_UUID=""
else
    echo "[!] manifest-meta.json missing — source-fingerprint interlock DEGRADED (typed confirmation still required)"
fi

# interlock 2: never target the disk the backup came from
if [ -n "$SRC_HOME" ] && [ -e "$SRC_HOME" ]; then
    if [ "$(readlink -f "$SRC_HOME")" = "$TARGET_CANON" ]; then
        echo "INTERLOCK: target '$TARGET_CANON' IS the backup source — restore refuses to target the disk it came from" >&2; exit 1
    fi
fi
# interlock 3: filesystem fingerprint match
TGT_FSID="$(stat -c %d "$TARGET_CANON" 2>/dev/null || echo unknown)"
if [ -n "$SRC_FSID" ] && [ "$SRC_FSID" != "null" ] && [ "$SRC_FSID" != "unknown" ] && [ "$TGT_FSID" = "$SRC_FSID" ]; then
    echo "INTERLOCK: target filesystem id matches the backup SOURCE — refusing" >&2; exit 1
fi
TGT_UUID="$(findmnt -no UUID -T "$TARGET_CANON" 2>/dev/null || echo "")"
if [ -n "$SRC_UUID" ] && [ -n "$TGT_UUID" ] && [ "$SRC_UUID" = "$TGT_UUID" ]; then
    echo "INTERLOCK: target filesystem UUID matches the backup SOURCE — refusing" >&2; exit 1
fi

expand_profile_path() { # $1 = raw profile path; ~ expands to TARGET home
    local p="$1"
    p="${p/#\~/$TARGET_CANON}"
    p="${p//\$HOME/$TARGET_CANON}"
    printf '%s' "$p"
}

restore_class() { # $1 = app id (lower), $2 = target path -> prints class
    local app="$1" tp="$2" pf class nloc npath raw lp
    pf="$PROFILE_DIR/$app.json"
    [ -f "$pf" ] || { echo "unknown (no profile)"; return; }
    nloc="$(jq '.locations | length' "$pf")"
    for ((i=0; i<nloc; i++)); do
        class="$(jq -r ".locations[$i].class" "$pf")"
        npath="$(jq -r ".locations[$i].linux | length" "$pf")"
        for ((j=0; j<npath; j++)); do
            raw="$(jq -r ".locations[$i].linux[$j]" "$pf")"
            lp="$(expand_profile_path "$raw")"
            if [ "$tp" = "$lp" ] || [[ "$tp" == "$lp/"* ]]; then
                echo "$class"; return
            fi
        done
    done
    echo "unknown (not in profile)"
}

config_valid() { # $1 = file; 0 = valid
    case "$1" in *.json) jq empty "$1" >/dev/null 2>&1 ;; *) return 0 ;; esac
}

# prefix of source_home without a drive letter, forward slashes (PS layout)
src_nodrive=""
if [ -n "$SRC_HOME" ]; then
    src_nodrive="$(printf '%s' "$SRC_HOME" | sed -E 's#^[A-Za-z]:##' | tr '\\' '/')"
    src_nodrive="${src_nodrive#/}"
fi

map_target() { # $1 = manifest file path (app/rel) -> prints target path or empty on unsafe
    local f="$1" rel tail
    rel="${f#*/}"                 # strip "<app>/"
    rel="$(printf '%s' "$rel" | tr '\\' '/')"
    rel="${rel#/}"
    tail="$rel"
    if [ -n "$src_nodrive" ]; then
        if [[ "$rel" == "$src_nodrive/"* ]]; then
            tail="${rel#$src_nodrive/}"
        elif [ "$rel" != "$src_nodrive" ]; then
            # not under the recorded source home: assume bash home-relative layout
            tail="$rel"
        else
            tail=""
        fi
    fi
    [ -n "$tail" ] || return 1
    printf '%s' "$TARGET_CANON/$tail"
}

echo
echo "=== Phoenix selective restore plan (App=$APP) ==="
echo "    backup : $MANIFEST_CANON"
echo "    target : $TARGET_CANON"
echo

plan_rows=()        # app|class|action|target|backup|hash
restorable=0

while IFS= read -r entry; do
    app="$(jq -r '.app' <<<"$entry")"
    file="$(jq -r '.file' <<<"$entry")"
    hash="$(jq -r '.sha256' <<<"$entry")"
    [ "$APP" = "all" ] || [ "$(printf '%s' "$APP" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$app" | tr 'A-Z' 'a-z')" ] || continue
    backup_file="$MANIFEST_CANON/$file"
    if target="$(map_target "$file")" && [ -f "$backup_file" ]; then
        class="$(restore_class "$(printf '%s' "$app" | tr 'A-Z' 'a-z')" "$target")"
        case "$class" in
            data)   action="RESTORE" ;;
            config) action="VALIDATE-THEN-RESTORE" ;;
            *)      action="SKIP (kill-list: $class -- never restored)" ;;
        esac
    elif [ ! -f "$backup_file" ]; then
        class="?"; action="SKIP (missing in backup)"; target=""
    else
        class="?"; action="SKIP (cannot map to target safely)"; target=""
    fi
    printf '%-10s %-32s %-42s %s\n' "$app" "$class" "$action" "${target:-$file}"
    plan_rows+=("$app|$class|$action|$target|$backup_file|$hash")
    case "$action" in RESTORE|VALIDATE-THEN-RESTORE) restorable=$((restorable+1)) ;; esac
done < <(jq -c '.[]' "$MANIFEST_DIR/manifest.json")

# read-only integrity check of the backup itself (runs in plan mode too)
bad=0
for row in "${plan_rows[@]}"; do
    action="$(cut -d'|' -f3 <<<"$row")"
    case "$action" in RESTORE|VALIDATE-THEN-RESTORE) ;;
        *) continue ;;
    esac
    backup_file="$(cut -d'|' -f5 <<<"$row")"; want="$(cut -d'|' -f6 <<<"$row")"
    got="$(sha256sum "$backup_file" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        echo "[!] BACKUP INTEGRITY FAILURE: $backup_file"
        bad=$((bad+1))
    fi
done
if [ "$bad" -gt 0 ]; then
    echo "refusing to proceed: backup does not match its manifest" >&2; exit 1
fi
echo
echo "[+] backup integrity: all $restorable restorable file(s) match manifest hashes"

if [ "$APPLY" -eq 0 ]; then
    echo "(plan mode -- nothing written. pass --apply --target-root <path> to restore)"
    exit 0
fi

# --- typed confirmation ---
if [ "$CONFIRM_WORD" = "RESTORE" ]; then
    echo "[!] non-interactive confirmation (--confirm-word) -- operator attests this is the NEW machine"
else
    echo
    echo "You are about to restore $restorable file(s) onto:"
    echo "    $TARGET_CANON"
    echo
    printf 'Type RESTORE to proceed (anything else aborts): '
    IFS= read -r typed || typed=""
    if [ "$typed" != "RESTORE" ]; then echo "aborted."; exit 2; fi
fi

# --- apply ---
done_n=0
failed=()
quarantined=()
for row in "${plan_rows[@]}"; do
    action="$(cut -d'|' -f3 <<<"$row")"
    case "$action" in RESTORE|VALIDATE-THEN-RESTORE) ;;
        *) continue ;;
    esac
    app="$(cut -d'|' -f1 <<<"$row")"; class="$(cut -d'|' -f2 <<<"$row")"
    target="$(cut -d'|' -f4 <<<"$row")"; backup_file="$(cut -d'|' -f5 <<<"$row")"; want="$(cut -d'|' -f6 <<<"$row")"
    got="$(sha256sum "$backup_file" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then failed+=("$backup_file (hash changed between plan and apply)"); continue; fi
    if [ "$class" = "config" ] && ! config_valid "$backup_file"; then
        quarantined+=("$backup_file")   # corrupt config is never reapplied
        continue
    fi
    mkdir -p "$(dirname "$target")"
    cp -a "$backup_file" "$target"
    got2="$(sha256sum "$target" | cut -d' ' -f1)"
    if [ "$got2" != "$want" ]; then failed+=("$target (target hash mismatch after copy)"); continue; fi
    done_n=$((done_n+1))
done

echo
echo "[+] restored $done_n / $restorable planned file(s) -> $TARGET_CANON"
if [ "${#quarantined[@]}" -gt 0 ]; then
    echo "[!] QUARANTINED on restore (invalid config, not reapplied):"
    printf '    %s\n' "${quarantined[@]}"
fi
if [ "${#failed[@]}" -gt 0 ]; then
    echo "[!] FAILED:" >&2
    printf '    %s\n' "${failed[@]}" >&2
    echo "restore incomplete: ${#failed[@]} file(s) failed verification" >&2
    exit 1
fi
