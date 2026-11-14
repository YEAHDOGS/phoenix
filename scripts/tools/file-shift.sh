#!/usr/bin/env bash
# =============================================================================
# file-shift.sh — Bash twin of scripts/tools/file-shift.ps1 (Phoenix)
#
# Batch-renames every regular file in the current directory to
# "<prefix><counter><extension>", e.g. wedding-photo-1.jpg. Mirrors the
# PowerShell original:
#   * Prefix from arg 1 (-p/--prefix) or interactive prompt
#   * Side-by-side preview with numbering, then explicit Y/N confirmation
#   * Per-file success/failure report + final count
#
# Excludes the script itself from renaming — both this twin (file-shift.sh)
# and its PowerShell original (file-shift.ps1) are skipped, since the twin
# usually runs in the same directory as the original.
# =============================================================================
set -uo pipefail

CYAN=$'\033[0;36m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'
RED=$'\033[0;31m'; WHITE=$'\033[0;37m'; GRAY=$'\033[0;90m'; NC=$'\033[0m'

PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--prefix) PREFIX="${2:-}"; shift 2 ;;
        -h|--help) echo "Usage: $(basename "$0") [-p PREFIX]"; exit 0 ;;
        *) PREFIX="$1"; shift ;;
    esac
done

# 1. Handle prefix input
if [ -z "${PREFIX//[[:space:]]/}" ]; then
    read -r -p "Enter the prefix for renaming (e.g., 'wedding-photo-'): " PREFIX
fi

# 2. Gather target files (excluding the scripts themselves)
SELF_SH="file-shift.sh"
SELF_PS1="file-shift.ps1"
mapfile -t TARGETS < <(find . -maxdepth 1 -type f ! -name "$SELF_SH" ! -name "$SELF_PS1" -printf '%f\n' | LC_ALL=C sort)

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "${YELLOW}No files found in the current directory to rename.${NC}"
    exit 0
fi

# 3. Generate previews and confirm
echo ""
echo "${CYAN}--- FILES FOUND & PREVIEW ---${NC}"
echo "${CYAN}Total files found: ${#TARGETS[@]}${NC}"
echo ""

declare -a NEW_NAMES=()
counter=1
for f in "${TARGETS[@]}"; do
    ext=""
    if [[ "$f" == *.* ]]; then ext=".${f##*.}"; fi
    new="${PREFIX}${counter}${ext}"
    NEW_NAMES+=("$new")
    printf "${WHITE}  -> %s ${GRAY}---> ${YELLOW}%s${NC}\n" "$f" "$new"
    counter=$((counter + 1))
done
echo "----------------------------"
echo ""

read -r -p "Are you sure you want to execute these renames? (Y/N) " confirm
if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "${YELLOW}Operation cancelled.${NC}"
    exit 0
fi

# 4. Perform the renaming
echo ""
success=0
for i in "${!TARGETS[@]}"; do
    old="${TARGETS[$i]}"; new="${NEW_NAMES[$i]}"
    if [ -e "$new" ] && [ "$old" != "$new" ]; then
        echo "${RED}Failed to rename $old: target '$new' already exists${NC}"
        continue
    fi
    if mv -- "$old" "$new" 2>/dev/null; then
        echo "${GREEN}Successfully Renamed: $old -> $new${NC}"
        success=$((success + 1))
    else
        echo "${RED}Failed to rename $old${NC}"
    fi
done

echo ""
echo "${CYAN}Done! Successfully renamed $success files.${NC}"
