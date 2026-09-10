#!/bin/bash
# Phoenix selective backup (Linux rescue side): bash twin of backup-selective.ps1.
# Copies only data + validated config per app profiles. Cache and executables
# are NEVER touched.
#
# Usage:
#   backup-selective.sh [--app chrome|all] [--plan] [--execute --dest DIR] [--profile-dir DIR]
#
#   PHOENIX_HOME overrides ~ expansion in linux profile paths (default: $HOME).
#   Defaults to read-only plan mode. Nothing is copied without --execute --dest.

set -euo pipefail

APP="all"
DEST=""
EXECUTE=0
PROFILE_DIR="$(cd "$(dirname "$0")/../../profiles" && pwd)"
HOME_ROOT="${PHOENIX_HOME:-$HOME}"

while [ $# -gt 0 ]; do
    case "$1" in
        --app)          APP="$2"; shift 2 ;;
        --dest)         DEST="$2"; shift 2 ;;
        --execute)      EXECUTE=1; shift ;;
        --plan)         EXECUTE=0; shift ;;
        --profile-dir)  PROFILE_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

expand_path() {
    local p="$1"
    p="${p/#\~/$HOME_ROOT}"          # leading ~ -> PHOENIX_HOME
    p="${p//\$HOME/$HOME_ROOT}"       # literal $HOME too
    printf '%s' "$p"
}

config_valid() { # $1 = file; returns 0 if valid
    local f="$1"
    case "$f" in
        *.json) jq empty "$f" >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

echo "=== Phoenix selective backup plan (App=$APP) ==="
echo

manifest_entries=()
quarantined=()
copied=0

for pf in "$PROFILE_DIR"/*.json; do
    id="$(jq -r '.app' "$pf")"
    [ "$APP" = "all" ] || [ "$APP" = "$id" ] || continue

    nloc="$(jq '.locations | length' "$pf")"
    for ((i=0; i<nloc; i++)); do
        class="$(jq -r ".locations[$i].class" "$pf")"
        npath="$(jq -r ".locations[$i].linux | length" "$pf")"
        for ((j=0; j<npath; j++)); do
            raw="$(jq -r ".locations[$i].linux[$j]" "$pf")"
            path="$(expand_path "$raw")"
            if [ -e "$path" ]; then found="yes"; else found="no"; fi
            case "$class" in
                data)       action="BACKUP" ;;
                config)     action="VALIDATE-THEN-BACKUP" ;;
                cache)      action="SKIP (cache)" ;;
                executable) action="SKIP (executable -- reinstall clean)" ;;
                *)          action="SKIP (unknown class)" ;;
            esac
            printf '%-10s %-10s %-28s %s [%s]\n' "$id" "$class" "$action" "$path" "$found"

            if [ "$EXECUTE" = 1 ] && [ -e "$path" ] && { [ "$class" = data ] || [ "$class" = config ]; }; then
                [ -n "$DEST" ] || { echo "error: --execute requires --dest" >&2; exit 1; }
                ok=1
                if [ "$class" = config ]; then
                    while IFS= read -r jf; do
                        if ! config_valid "$jf"; then
                            ok=0
                            quarantined+=("$jf")
                        fi
                    done < <(find "$path" \( -type f -o -type l \) -name '*.json' 2>/dev/null)
                fi
                if [ "$ok" = 1 ]; then
                    if [[ "$path" == "$HOME_ROOT"* ]]; then
                        rel="${path#$HOME_ROOT/}"     # paths under home stay home-relative
                    else
                        rel="${path#/}"
                    fi
                    target="$DEST/$id/$rel"
                    mkdir -p "$(dirname "$target")"
                    cp -a "$path" "$target"
                    while IFS= read -r f; do
                        [ -f "$f" ] || continue
                        h="$(sha256sum "$f" | cut -d' ' -f1)"
                        relf="${f#$DEST/}"
                        manifest_entries+=("{\"app\":\"$id\",\"file\":\"$relf\",\"sha256\":\"$h\"}")
                        copied=$((copied+1))
                    done < <(find "$target" -type f 2>/dev/null)
                fi
            fi
        done
    done
done

echo
if [ "$EXECUTE" = 1 ]; then
    [ -n "$DEST" ] || { echo "error: --execute requires --dest" >&2; exit 1; }
    {
        printf '[\n'
        for ((k=0; k<${#manifest_entries[@]}; k++)); do
            [ "$k" -gt 0 ] && printf ',\n'
            printf '  %s' "${manifest_entries[$k]}"
        done
        printf '\n]\n'
    } > "$DEST/manifest.json"
    echo "[+] copied $copied files -> $DEST"
    echo "[+] manifest.json written ($DEST/manifest.json)"
    if [ "${#quarantined[@]}" -gt 0 ]; then
        echo "[!] QUARANTINED (invalid config, not copied):"
        printf '    %s\n' "${quarantined[@]}"
    fi
else
    echo "(plan mode -- nothing copied. pass --execute --dest <path> to back up)"
fi
