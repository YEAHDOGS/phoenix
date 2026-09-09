#!/usr/bin/env bash
# =============================================================================
# delete-node.sh - Bash twin of scripts/tools/delete-node.ps1 (Phoenix)
#
# Deletes ./node_modules, mirroring the PowerShell original:
#   * Explicit y/N confirmation before anything is touched
#   * rm -rf (plays the role of the .ps1's cmd.exe rmdir fast-path)
#   * If deletion is incomplete, searches for processes holding the tree open
#     (lsof/fuser instead of Get-CimInstance Win32_Process), lists them, and
#     offers a second confirmation to kill -9 them and retry
#   * No node_modules -> informational message, exit 0
# =============================================================================
set -uo pipefail

CYAN=$'\033[0;36m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'
RED=$'\033[0;31m'; NC=$'\033[0m'

TARGET="$PWD/node_modules"

if [ ! -e "$TARGET" ]; then
    echo "${YELLOW}No node_modules folder found in $PWD.${NC}"
    exit 0
fi

read -r -p "Are you sure you want to delete the node_modules folder in $PWD? (y/N) " confirmation
if ! [[ "$confirmation" =~ ^[yY]$ ]]; then
    echo "${YELLOW}Deletion cancelled.${NC}"
    exit 0
fi

echo "${CYAN}Deleting node_modules...${NC}"
rm -rf -- "$TARGET"

if [ ! -e "$TARGET" ]; then
    echo "${GREEN}node_modules deleted successfully.${NC}"
    exit 0
fi

echo "${RED}Failed to completely delete node_modules. Some files might be in use.${NC}"
echo ""
echo "${CYAN}Searching for associated processes...${NC}"

PIDS=""
if command -v lsof >/dev/null 2>&1; then
    PIDS="$(lsof +D "$TARGET" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)"
elif command -v fuser >/dev/null 2>&1; then
    PIDS="$(fuser "$TARGET" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)"
fi

if [ -n "$PIDS" ]; then
    echo "${YELLOW}Found the following processes using node_modules:${NC}"
    for pid in $PIDS; do
        pname="$(ps -o comm= -p "$pid" 2>/dev/null || echo '?')"
        echo " - $pname (PID: $pid)"
    done

    echo ""
    read -r -p "Do you want to force kill these processes and nuke the folder? (y/N) " nuke
    if [[ "$nuke" =~ ^[yY]$ ]]; then
        for pid in $PIDS; do
            pname="$(ps -o comm= -p "$pid" 2>/dev/null || echo '?')"
            echo "${CYAN}Killing process $pname (PID: $pid)${NC}"
            kill -9 "$pid" 2>/dev/null
        done
        sleep 1
        echo "${CYAN}Retrying deletion...${NC}"
        rm -rf -- "$TARGET"
        if [ ! -e "$TARGET" ]; then
            echo "${GREEN}node_modules deleted successfully after nuking processes.${NC}"
            exit 0
        fi
        echo "${RED}Still failed to delete node_modules completely.${NC}"
        exit 1
    else
        echo "${YELLOW}Nuke cancelled.${NC}"
        exit 1
    fi
else
    echo "${YELLOW}No associated processes found to kill.${NC}"
    exit 1
fi
