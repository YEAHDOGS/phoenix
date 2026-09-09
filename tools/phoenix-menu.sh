#!/usr/bin/env bash
#===============================================================================
# phoenix-menu.sh -- the Phoenix in-environment menu (Linux rescue side)
#
# Once booted into a Phoenix Linux rescue environment (SystemRescue /
# Rescuezilla / the Phoenix toolkit entry), the Ventoy boot menu is behind
# you. THIS menu is the founder's Analyze / Backup / Nuke / Reinstall flow
# inside the running environment: it reads phoenix-config.json headlessly
# from the USB root (no jq -- the boot image may not have it), shows the
# machine context, and dispatches to the right tool. The Windows-side twin
# is tools/Invoke-PhoenixMenu.ps1; both implement the SAME contract.
#
# SAFETY MODEL:
#   - This menu is NEVER destructive by itself. It prints guidance and
#     dispatches to the phase tools; destruction lives ONLY in the nuke
#     tools (phoenix-nuke.sh / Invoke-PhoenixNuke.ps1 / Invoke-Nuke.sh),
#     which carry their own interlocks (typed confirmation on a real
#     console, boot/USB self-protection, audit logging).
#   - Choice 3 (Nuke) execs tools/phoenix-nuke.sh with the arguments given
#     after `--`. piped stdin to the menu is fine -- the nuke tool refuses
#     redirected stdin structurally when it asks for confirmation.
#   - The install-time password in phoenix-config.json is NEVER printed,
#     never echoed, never logged. Redaction is by design: the parser
#     extracts only schemaVersion, machine.computerName, and os.family.
#     (The USB is a key -- anyone holding it can read the password.)
#
# USAGE:
#   phoenix-menu.sh                       interactive loop until Q
#   phoenix-menu.sh --config <path>       explicit phoenix-config.json
#   phoenix-menu.sh --choice <1|2|3|4|q>  run one choice non-interactively
#   phoenix-menu.sh --choice 3 -- <args>  dispatch Nuke with <args> to
#                                         tools/phoenix-nuke.sh
#   PHOENIX_MENU_TEST=1 ...               test hook: choice 3 prints the
#                                         dispatch line instead of exec'ing
#
# Exit codes: 0 = ok | 1 = error (bad flag, missing tool, unknown choice)
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"

CONFIG_PATH=""
CHOICE=""
NUKE_TOOL="$HERE/phoenix-nuke.sh"
TESTMODE="${PHOENIX_MENU_TEST:-0}"

# --- parsed config (non-sensitive fields only) --------------------------------
CFG_SCHEMA="?"
CFG_NAME="?"
CFG_OS="?"
CONFIG_FOUND=0
CONFIG_USED=""

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Phoenix menu v0.1.0 -- Analyze / Backup / Nuke / Reinstall dispatcher (Linux rescue side)

Usage:
  $PROG                        Interactive menu loop (Q to quit)
  $PROG --config <path>        Explicit phoenix-config.json location
  $PROG --choice <1|2|3|4|q>   Run one choice non-interactively, then exit
  $PROG --choice 3 -- <args>   Dispatch Nuke: exec tools/phoenix-nuke.sh <args>
  $PROG --help                 This help

The menu itself destroys nothing. Nuke is handed to tools/phoenix-nuke.sh,
which enforces its own interlocks (double-typed confirmation on a real
console, boot/USB self-protection, audit log).
EOF
}

# jget <file> <json-key> -- extract a simple scalar value from flat-ish
# JSON without jq. Only used for non-sensitive keys (schemaVersion,
# machine.computerName, os.family). Handles both "key": "str" and
# "key": 123. Returns empty string when absent.
jget() {
    local file="$1" key="$2" v
    v="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[0-9][0-9]*\)" "$file" 2>/dev/null | head -n1 || true)"
    v="${v#*:}"
    v="$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
    printf '%s' "$v"
}

# find_config: locate phoenix-config.json at the root of a mounted volume.
# Searches /proc/mounts for candidate filesystems first (fast, no walk),
# then falls back to common mount points and the current directory.
find_config() {
    if [[ -n "$CONFIG_PATH" ]]; then
        [[ -f "$CONFIG_PATH" ]] || die "--config '$CONFIG_PATH' not found."
        echo "$CONFIG_PATH"
        return
    fi
    local mp
    while IFS= read -r mp; do
        if [[ -f "$mp/phoenix-config.json" ]]; then echo "$mp/phoenix-config.json"; return; fi
    done < <(awk '$3 ~ /^(vfat|exfat|ntfs|ntfs3|fuseblk)$/ {print $2}' /proc/mounts 2>/dev/null || true)
    for mp in /mnt /media /run/media /media/usb /mnt/usb; do
        if [[ -f "$mp/phoenix-config.json" ]]; then echo "$mp/phoenix-config.json"; return; fi
    done
    if [[ -f "./phoenix-config.json" ]]; then echo "./phoenix-config.json"; return; fi
    return 1
}

load_config() {
    local cfg
    if cfg="$(find_config)"; then
        CONFIG_FOUND=1
        CONFIG_USED="$cfg"
        CFG_SCHEMA="$(jget "$cfg" schemaVersion)"
        CFG_NAME="$(jget "$cfg" computerName)"
        CFG_OS="$(jget "$cfg" family)"
        if [[ -z "$CFG_SCHEMA" ]]; then CFG_SCHEMA="?"; fi
        if [[ -z "$CFG_NAME" ]];   then CFG_NAME="?";   fi
        if [[ -z "$CFG_OS" ]];     then CFG_OS="?";     fi
        if [[ "$CFG_SCHEMA$CFG_NAME$CFG_OS" == "???" && -s "$cfg" ]]; then
            # None of the known keys parsed out of a non-empty file: it is
            # not a phoenix-config.json (or it is corrupt). Warn, continue
            # unconfigured -- never fail the menu over a bad config.
            echo "[$PROG] WARNING: '$cfg' does not look like a phoenix-config.json (no known keys found) -- unconfigured mode." >&2
        fi
    fi
}

show_banner() {
    echo "======================================================================"
    echo " PHOENIX -- Analyze / Backup / Nuke / Reinstall"
    echo "======================================================================"
    if (( CONFIG_FOUND == 1 )); then
        echo " config: $CONFIG_USED (schema $CFG_SCHEMA)"
        echo " machine: $CFG_NAME   os.family: $CFG_OS"
    else
        echo " config: NOT FOUND on any mounted volume -- unconfigured mode."
        echo " Reinstall answers unavailable until a Phoenix USB with"
        echo " phoenix-config.json is mounted."
    fi
    echo "----------------------------------------------------------------------"
}

show_menu() {
    cat <<'EOF'
  [1] ANALYZE    inspect the machine without booting its OS
  [2] BACKUP     full-disk image + data backup (before anything destructive)
  [3] NUKE       irreversible disk sanitization (typed-confirmation interlocks)
  [4] REINSTALL  unattended OS reinstall from phoenix-config.json
  [Q] QUIT
EOF
}

choice_analyze() {
    cat <<EOF

--- [1] ANALYZE ---------------------------------------------------------------
You are in a Linux rescue environment: the suspect machine's OS is NOT
running, so its disk is inert and safe to inspect.

  - File manager / terminal: browse the target disk read-only first.
  - Forensics toolkit: see docs/ANALYSIS-TOOLKIT.md and
    tools/analysis-toolkit.manifest.json (testdisk, ddrescue, partition
    tools; stage with tools/Stage-AnalysisTools.ps1).
  - Hash anything you care about before you touch it:
      sha256sum <file>  > /tmp/pre-change.sha256
  - Rule: nothing on this menu writes to the target disk except the
    BACKUP and NUKE paths -- and NUKE asks for the disk serial twice.
EOF
}

choice_backup() {
    cat <<EOF

--- [2] BACKUP ----------------------------------------------------------------
Verified backup or no wipe -- that is the runbook invariant, and the Nuke
gate enforces it in code.

  1. Full-disk image: run Rescuezilla (the [2] BACKUP Ventoy entry) against
     the target disk; WATCH its post-backup integrity check pass.
  2. Mint the image proof: tools/New-ImageProof.sh --image-name <n> \\
       --image-path <dir> --source-serial <serial> --sha256 <64-hex> --verified
     The proof manifest is what tools/Invoke-Nuke.sh --image-proof demands
     before it will arm a wipe (verified=YES, matching source_serial).
  3. Data-only backup (optional, in addition to the image):
     tools/phoenix-data-backup.sh  (Linux)  |  tools/New-PhoenixDataBackup.ps1 (WinPE)
     emits a phoenix-data-backup/1 manifest; executables are skipped unless
     explicitly opted in (dirty-data contract).

Image target: a SECOND USB / Castle storage -- never the Phoenix boot stick,
never the disk you are about to wipe.
EOF
}

choice_nuke() {
    # All remaining args go straight to the nuke tool (e.g. -- --nuke 2).
    if [[ ! -x "$NUKE_TOOL" ]]; then
        echo "[$PROG] FATAL: nuke tool not found or not executable: $NUKE_TOOL" >&2
        return 1
    fi
    cat <<'EOF'

--- [3] NUKE ------------------------------------------------------------------
IRREVERSIBLE. The nuke tool will now take over: it enumerates disks, and
arming requires typing the target disk's exact serial TWICE on a real
console (piped input is refused), plus a 5-second abort window. Read the
operator checklist in docs/NUKE-SAFETY.md BEFORE you arm anything.

Handing off to tools/phoenix-nuke.sh ...
EOF
    if [[ "$TESTMODE" == "1" ]]; then
        echo "[$PROG] TESTMODE: would exec: $NUKE_TOOL $*"
        return 0
    fi
    exec "$NUKE_TOOL" "$@"
}

choice_reinstall() {
    cat <<EOF

--- [4] REINSTALL -------------------------------------------------------------
Unattended reinstall is driven by the generated answer file, which Ventoy's
auto_install plugin feeds to the Windows ISO at boot (see
docs/BOOT-ARCHITECTURE.md §3).

  - phoenix-config.json -> autounattend.xml is produced by the config GUI
    (Svelte + Tauri) or tools/Build-PhoenixUsb.ps1 on a WORKING machine.
EOF
    if (( CONFIG_FOUND == 1 )); then
        echo "  This stick's config targets: $CFG_NAME ($CFG_OS family)."
        echo "  First logon: rotate the install-time password (runbook Step: the"
        echo "  USB is a key -- anyone holding it could read it)."
    else
        echo "  No config on this machine -- reinstall answers unavailable."
        echo "  Mount the Phoenix USB (the exFAT partition) and re-run this menu."
    fi
}

dispatch() {
    local c="$1"; shift
    case "$c" in
        1) choice_analyze ;;
        2) choice_backup ;;
        3) choice_nuke "$@" ;;
        4) choice_reinstall ;;
        q|Q) return 2 ;;
        *) echo "[$PROG] unknown choice '$c' -- use 1, 2, 3, 4, or Q." >&2; return 1 ;;
    esac
}

main() {
    local nuke_args=()
    local past_dashdash=0
    while (( $# > 0 )); do
        if (( past_dashdash == 1 )); then nuke_args+=("$1"); shift; continue; fi
        case "$1" in
            --config) CONFIG_PATH="${2:?--config needs a path}"; shift 2 ;;
            --choice) CHOICE="${2:?--choice needs 1|2|3|4|q}"; shift 2 ;;
            --) past_dashdash=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
    done

    load_config
    show_banner

    if [[ -n "$CHOICE" ]]; then
        show_menu
        local rc=0
        dispatch "$CHOICE" "${nuke_args[@]}" || rc=$?
        if (( rc == 2 )); then return 0; fi
        return "$rc"
    fi

    local line rc
    while true; do
        show_menu
        printf 'phoenix> '
        if ! IFS= read -r line; then echo ""; return 0; fi
        line="$(echo "$line" | tr -d '[:space:]')"
        if [[ -z "$line" ]]; then continue; fi
        rc=0
        dispatch "$line" "${nuke_args[@]}" || rc=$?
        if (( rc == 2 )); then return 0; fi
        echo ""
    done
}

main "$@"
