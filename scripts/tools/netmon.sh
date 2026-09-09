#!/usr/bin/env bash
#===============================================================================
# netmon.sh -- Phoenix Linux-side network monitor (bash twin of netmon.ps1)
#
# Lists established TCP connections, split into two sections the way the
# PowerShell original does:
#   [!] EXTERNAL (WORLD) -- connections to non-private addresses. In the
#       Analyze boot environment this is the "is the infection phoning home?"
#       view: anything unexpected here is worth investigating before backup.
#   [+] LOCAL (LAN)      -- private/loopback peers, with first-seen tracking.
#
# Usage:
#   netmon.sh --snapshot    single pass, plain output (scriptable, testable)
#   netmon.sh --watch       live refreshing view until Ctrl-C (default-ish)
#
# Requires: ss (iproute2). Process names need root; without it the PROCESS
# column shows "-".
#===============================================================================
set -euo pipefail

VERSION="0.1.0"
MODE="watch"

while (( $# > 0 )); do
    case "$1" in
        --snapshot) MODE="snapshot"; shift ;;
        --watch)    MODE="watch"; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "netmon.sh: unknown option '$1' (see --help)" >&2; exit 1 ;;
    esac
done

command -v ss >/dev/null 2>&1 || { echo "netmon.sh: 'ss' not found -- boot image is incomplete." >&2; exit 1; }

# classify_ip <ip> -> prints "local" or "external"
classify_ip() {
    local ip="$1"
    # strip IPv6 zone suffix (fe80::1%eth0)
    ip="${ip%%\%*}"
    case "$ip" in
        127.*|::1|0.0.0.0|::)                       echo local; return ;;
        10.*)                                        echo local; return ;;
        192.168.*)                                   echo local; return ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)      echo local; return ;;
        169.254.*)                                   echo local; return ;;
        fc00::*|fd00::*|fe80::*)                     echo local; return ;;
    esac
    echo external
}

# ss_line_fields: prints "REMOTE_IP REMOTE_PORT PROCESS" per established TCP conn.
# Parses `ss -tupn state established` (users:(("name",pid=123,fd=4)) format).
# awk is written for the lowest common denominator (mawk/busybox): no
# gawk-only 3-argument match().
parse_connections() {
    ss -tupn state established 2>/dev/null | awk '
        NR > 1 {
            # peer column is $6 (Local $5, Peer $6)
            peer = $6
            n = split(peer, a, ":")
            port = a[n]
            sub(/:[^:]*$/, "", peer)
            gsub(/^\[|\]$/, "", peer)
            proc = "-"
            u = $0
            if (sub(/.*users:\(\("/, "", u)) { sub(/".*/, "", u); proc = u }
            print peer, port, proc
        }'
}

declare -A FIRST_SEEN=()

snapshot() {
    local ext=0 loc=0 line rip rport proc cls
    echo "--- PHOENIX NETMON (snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
    echo ""
    echo "[!] EXTERNAL CONNECTIONS (WORLD)"
    while read -r rip rport proc; do
        [[ -z "$rip" ]] && continue
        cls="$(classify_ip "$rip")"
        if [[ "$cls" == "external" ]]; then
            printf '  %-40s :%-8s %s\n' "$rip" "$rport" "$proc"
            ext=$((ext+1))
        fi
    done < <(parse_connections)
    (( ext == 0 )) && echo "  No active external connections."
    echo ""
    echo "[+] LOCAL NETWORK PEERS (LAN)"
    while read -r rip rport proc; do
        [[ -z "$rip" ]] && continue
        cls="$(classify_ip "$rip")"
        if [[ "$cls" == "local" ]]; then
            if [[ -z "${FIRST_SEEN[$rip]:-}" ]]; then
                FIRST_SEEN["$rip"]="$(date +%H:%M:%S)"
            fi
            printf '  [v] %-38s first-seen %s  (%s)\n' "$rip" "${FIRST_SEEN[$rip]}" "$proc"
            loc=$((loc+1))
        fi
    done < <(parse_connections)
    (( loc == 0 )) && echo "  No local peers detected."
    echo ""
    echo "external=$ext local=$loc"
}

if [[ "$MODE" == "snapshot" ]]; then
    snapshot
    exit 0
fi

# --- watch mode: live refresh until Ctrl-C ---
esc="$(printf '\033')"
trap 'printf "%s[?25h\n" "$esc"; exit 0' INT TERM
printf '%s[?25l' "$esc"
while true; do
    printf '%s[H%s[J' "$esc" "$esc"
    snapshot
    sleep 2
done
