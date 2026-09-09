#!/usr/bin/env bash
#===============================================================================
# New-PhoenixConfig.sh -- write phoenix-config.json (the Phoenix USB key file)
#
# Bash twin of tools/New-PhoenixConfig.ps1. The config GUI (Tauri) is the
# flagship writer; this tool is the zero-dependency CLI fallback -- and the
# version that runs on Linux build machines. It writes exactly the schema the
# boot side reads headless (docs/BOOT-ARCHITECTURE.md §5, schemaVersion 1):
#
#   schemaVersion, machine.{computerName,timezone}, credentials.{username,password},
#   os.{family,edition,productKey,answerFile.{disableWPBT,partitionLayout}},
#   apps[].{id,source}, nuke.{protectedDisks[]}
#
# A disk named in nuke.protectedDisks (by serial or /dev path) is EXCLUDED
# from NUKE candidacy entirely (tools/lib/phoenix-disk-inventory.sh) -- it
# cannot be armed even with --override flags. Mark the disks you must never
# lose: the backup vault, the Castle drive, anything irreplaceable.
#
# The boot menu parses this WITHOUT jq (tools/phoenix-menu.sh: jget), so the
# emitted JSON is deliberately flat-simple: string and number scalars only,
# one "key": value per line, no exotic formatting. Keep it that way.
#
# SECURITY (read before you run this):
#   unattend requires the install-time password in a REVERSIBLE form
#   (base64-obfuscated = effectively plaintext). The USB is a KEY -- anyone
#   holding it can read the password. This tool:
#     - NEVER prints the password to the terminal or logs (dry-run redacts it)
#     - refuses password-on-piped-stdin (echo P | ...) -- use --password or a TTY
#     - REFUSES to write inside a git work tree without --force (so a real
#       config never gets committed by accident -- .gitignore covers it too)
#   Rotate the install-time password at first logon (EMERGENCY-RUNBOOK), keep
#   the stick on your person, never leave it in the machine.
#
# USAGE:
#   New-PhoenixConfig.sh --computer-name BRANDON-PC --username brandon \
#       --password <secret> --out /mnt/usb/phoenix-config.json
#   New-PhoenixConfig.sh --dry-run --computer-name BRANDON-PC --username brandon --password <secret>
#
# All other fields have sane defaults; --app choco:<id> may repeat.
#===============================================================================
set -u
PROG="$(basename "$0")"

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }
warn() { echo "[$PROG] WARNING: $*" >&2; }

#--- JSON string escaping (no jq) ------------------------------------------------
jesc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # strip other control chars (jget-compatible scalars are plain text)
    s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
    printf '%s' "$s"
}

#--- args -----------------------------------------------------------------------
COMPUTER_NAME=""; USERNAME=""; PASSWORD=""
TIMEZONE="Central Standard Time"
FAMILY="windows"; EDITION="Professional"; PRODUCT_KEY=""
DISABLE_WPBT="true"; PARTITION_LAYOUT="gpt-uefi"
APPS=(); OUT="./phoenix-config.json"
PROTECT=()   # repeatable --protect-disk <serial-or-/dev-path>
DRY_RUN=0; FORCE=0

usage() {
    cat <<EOF
New-PhoenixConfig.sh -- write phoenix-config.json for a Phoenix USB (schema v1)

  --computer-name NAME     REQUIRED. 1-15 chars, A-Z 0-9 - (NetBIOS rule)
  --username USER          REQUIRED. local account the answer file creates
  --password SECRET        install-time password (or prompt on a TTY)
  --timezone TZ            default: "Central Standard Time"
  --family F               windows|linux|macos  (default: windows)
  --edition E              default: Professional
  --product-key KEY        XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, or omit for digital license
  --answer-keep-wpbt       leave WPBT enabled (default: disabled)
  --partition-layout L     gpt-uefi|mbr-bios (default: gpt-uefi)
  --app source:id          repeatable, e.g. --app choco:googlechrome
  --protect-disk ID        repeatable: disk serial (or /dev path) that the
                         NUKE path must never offer as a candidate
                         (nuke.protectedDisks). Use for the backup vault,
                         the Castle drive, anything irreplaceable.
  --out PATH               default: ./phoenix-config.json
  --dry-run                print the config (password REDACTED), write nothing
  --force                  allow writing inside a git work tree
  -h|--help                this text
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --computer-name)    COMPUTER_NAME="${2:?--computer-name needs a value}"; shift 2 ;;
        --username)         USERNAME="${2:?--username needs a value}"; shift 2 ;;
        --password)         PASSWORD="${2:?--password needs a value}"; shift 2 ;;
        --timezone)         TIMEZONE="${2:?--timezone needs a value}"; shift 2 ;;
        --family)           FAMILY="${2:?--family needs a value}"; shift 2 ;;
        --edition)          EDITION="${2:?--edition needs a value}"; shift 2 ;;
        --product-key)      PRODUCT_KEY="${2:?--product-key needs a value}"; shift 2 ;;
        --answer-keep-wpbt) DISABLE_WPBT="false"; shift ;;
        --partition-layout) PARTITION_LAYOUT="${2:?--partition-layout needs a value}"; shift 2 ;;
        --app)              APPS+=("${2:?--app needs a value}"); shift 2 ;;
        --protect-disk)     PROTECT+=("${2:?--protect-disk needs a value}"); shift 2 ;;
        --out)              OUT="${2:?--out needs a value}"; shift 2 ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --force)            FORCE=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "unknown argument: $1 (see --help)" ;;
    esac
done

#--- required fields -------------------------------------------------------------
[[ -n "$COMPUTER_NAME" ]] || die "--computer-name is required"
[[ -n "$USERNAME" ]]      || die "--username is required"

#--- password: --password or interactive TTY; NEVER from a pipe ------------------
if [[ -z "$PASSWORD" ]]; then
    if [[ -t 0 ]]; then
        printf 'Install-time password for %s: ' "$USERNAME" >&2
        IFS= read -r -s PASSWORD || die "failed to read password"
        echo >&2
        [[ -n "$PASSWORD" ]] || die "password may not be empty"
    else
        die "no --password given and stdin is not a TTY. Refusing password-on-piped-stdin: \`echo \$pass | ...\` leaks into shell history. Pass --password explicitly."
    fi
fi

#--- validation ------------------------------------------------------------------
[[ "$COMPUTER_NAME" =~ ^[A-Za-z0-9-]{1,15}$ ]] \
    || die "--computer-name '$COMPUTER_NAME' invalid: 1-15 chars, A-Z 0-9 and - only (NetBIOS rule)"
case "$FAMILY" in
    windows|linux|macos) ;;
    *) die "--family '$FAMILY' invalid: windows|linux|macos" ;;
esac
if [[ -n "$PRODUCT_KEY" ]] && ! [[ "$PRODUCT_KEY" =~ ^([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}$ ]]; then
    die "--product-key invalid: expected XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (omit for digital license)"
fi
case "$PARTITION_LAYOUT" in
    gpt-uefi|mbr-bios) ;;
    *) die "--partition-layout '$PARTITION_LAYOUT' invalid: gpt-uefi|mbr-bios" ;;
esac
[[ -n "$TIMEZONE" ]] || die "--timezone may not be empty"

APP_ENTRIES=()
for a in ${APPS[@]+"${APPS[@]}"}; do
    [[ "$a" == *:* ]] || die "--app '$a' invalid: expected source:id (e.g. choco:googlechrome)"
    src="${a%%:*}"; id="${a#*:}"
    [[ -n "$src" && -n "$id" ]] || die "--app '$a' invalid: source and id may not be empty"
    APP_ENTRIES+=("    { \"id\": \"$(jesc "$id")\", \"source\": \"$(jesc "$src")\" }")
done

#--- protected disks: identifiers must be non-empty, whitespace-free ----------
for p in ${PROTECT[@]+"${PROTECT[@]}"}; do
    [[ -n "$p" ]] || die "--protect-disk may not be empty"
    [[ "$p" != *[[:space:]]* ]] \
        || die "--protect-disk '$p' invalid: no whitespace (use the exact serial or /dev path)"
done
PROTECT_ENTRIES=()
for p in ${PROTECT[@]+"${PROTECT[@]}"}; do
    PROTECT_ENTRIES+=("\"$(jesc "$p")\"")
done

#--- build JSON -------------------------------------------------------------------
json_for() { # $1 = password value to embed (real or REDACTED)
    local pw="$1" pkey apps_json protect_json
    if [[ -n "$PRODUCT_KEY" ]]; then pkey="\"$(jesc "$PRODUCT_KEY")\""; else pkey="null"; fi
    if (( ${#APP_ENTRIES[@]} == 0 )); then
        apps_json="[]"
    else
        apps_json=$'[\n'"$(printf '%s,\n' "${APP_ENTRIES[@]}" | sed '$ s/,$//')"$'\n  ]'
    fi
    if (( ${#PROTECT_ENTRIES[@]} == 0 )); then
        protect_json="[]"
    else
        protect_json="[ $(printf '%s, ' "${PROTECT_ENTRIES[@]}" | sed 's/, $//') ]"
    fi
    cat <<EOF
{
  "schemaVersion": 1,
  "machine": {
    "computerName": "$(jesc "$COMPUTER_NAME")",
    "timezone": "$(jesc "$TIMEZONE")"
  },
  "credentials": {
    "username": "$(jesc "$USERNAME")",
    "password": "$(jesc "$pw")"
  },
  "os": {
    "family": "$(jesc "$FAMILY")",
    "edition": "$(jesc "$EDITION")",
    "productKey": $pkey,
    "answerFile": {
      "disableWPBT": $DISABLE_WPBT,
      "partitionLayout": "$(jesc "$PARTITION_LAYOUT")"
    }
  },
  "apps": $apps_json,
  "nuke": {
    "protectedDisks": $protect_json
  }
}
EOF
}

if (( DRY_RUN == 1 )); then
    json_for "***REDACTED***"
    exit 0
fi

#--- git-tree guard: a real config must never be committed -------------------------
OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || echo "$(dirname "$OUT")")"
if (( FORCE == 0 )) && git -C "$OUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "refusing to write '$OUT': it is inside a git work tree (a real phoenix-config.json must never be committed -- BOOT-ARCHITECTURE.md §5). Use --force only for test fixtures, never for a real password."
fi

json_for "$PASSWORD" > "$OUT" || die "failed to write '$OUT'"
chmod 600 "$OUT" 2>/dev/null || true
cat >&2 <<EOF
[$PROG] wrote $OUT (mode 600)
[$PROG] SECURITY: this file holds the install-time password in reversible form.
[$PROG] The USB is a KEY -- keep it on your person, never leave it in the
[$PROG] machine, and ROTATE the password at first logon (EMERGENCY-RUNBOOK).
EOF
