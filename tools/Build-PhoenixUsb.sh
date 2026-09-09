#!/usr/bin/env bash
#===============================================================================
# Build-PhoenixUsb.sh -- bash twin of tools/Build-PhoenixUsb.ps1
#
# Stages the Phoenix ISO set, config, and scripts onto a Ventoy-prepared USB
# from a LINUX clean machine (the .ps1 twin does the same from Windows).
# Same contract, same fail-closed behavior:
#   1. Verifies the target is Ventoy-prepared (refuses unprepared media).
#   2. Copies the ISO set (SystemRescue / Rescuezilla / ShredOS / Windows 11 /
#      Phoenix WinPE) with SHA-256 verification against a JSON sidecar.
#   3. Writes ventoy/ventoy.json (Analyze/Backup/Nuke/Reinstall menu aliases
#      + Windows auto_install wiring to /autounattend.xml).
#   4. Writes phoenix-config.json (schema v1) to the USB root.
#   5. Stages the Phoenix toolbox (scripts/ + tools/, *.ps1 and *.sh alike).
#   6. Writes phoenix/manifest.json with SHA-256 of everything staged.
#
# USAGE:
#   Build-PhoenixUsb.sh --usb-mount /media/phoenix --iso-dir ./iso-staging \
#       --iso-hashes ./iso-staging/phoenix-iso-hashes.json \
#       --computer-name BRANDON-PC --username brandon
#
# The hash sidecar is JSON: { "<iso filename>": "<sha256 hex>" } -- the same
# file the PowerShell twin reads, so one sidecar serves both builders.
#
# SECURITY: the install-time password is stored REVERSIBLY in
# phoenix-config.json (unattend requires it). The USB is a key -- keep it on
# your person, rotate the password at first logon, and NEVER commit a real
# phoenix-config.json to the repo.
#
# Exit codes: 0 = staged | 1 = usage/validation/asset error
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

USB_MOUNT=""; ISO_DIR=""; ISO_HASHES=""
COMPUTER_NAME="PHOENIX-PC"; USERNAME="phoenix"; PASSWORD=""
TIMEZONE="Central Standard Time"; EDITION="Professional"; PRODUCT_KEY=""
APPS=""; SKIP_HASH_CHECK=0; FORCE=0; DRY_RUN=0

usage() {
    cat <<EOF
Phoenix USB stager (Linux twin of tools/Build-PhoenixUsb.ps1).

Usage:
  $PROG --usb-mount <dir> --iso-dir <dir> [options]

Required:
  --usb-mount <dir>     mount point of the Ventoy-prepared USB
  --iso-dir <dir>       directory containing the ISO files

Options:
  --iso-hashes <file>   JSON sidecar { "<iso>": "<sha256>" }; required
                        unless --skip-hash-check
  --computer-name <n>   default: PHOENIX-PC
  --username <n>        default: phoenix
  --password <p>        install-time password (prompted securely if omitted)
  --timezone <tz>       default: Central Standard Time
  --edition <e>         default: Professional
  --product-key <k>     optional
  --apps <a,b,c>        comma-separated choco app ids (optional)
  --skip-hash-check     bypass ISO hash verification (NOT recommended)
  --force               overwrite existing staged files
  --dry-run             show what would be done, change nothing
EOF
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }
say() { echo "[$PROG] $*"; }

while (( $# > 0 )); do
    case "$1" in
        --usb-mount)     USB_MOUNT="${2:?}"; shift 2 ;;
        --iso-dir)       ISO_DIR="${2:?}"; shift 2 ;;
        --iso-hashes)    ISO_HASHES="${2:?}"; shift 2 ;;
        --computer-name) COMPUTER_NAME="${2:?}"; shift 2 ;;
        --username)      USERNAME="${2:?}"; shift 2 ;;
        --password)      PASSWORD="${2:?}"; shift 2 ;;
        --timezone)      TIMEZONE="${2:?}"; shift 2 ;;
        --edition)       EDITION="${2:?}"; shift 2 ;;
        --product-key)   PRODUCT_KEY="${2:?}"; shift 2 ;;
        --apps)          APPS="${2:?}"; shift 2 ;;
        --skip-hash-check) SKIP_HASH_CHECK=1; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ -n "$USB_MOUNT" ]] || die "--usb-mount is required"
[[ -n "$ISO_DIR" ]]   || die "--iso-dir is required"
[[ -d "$USB_MOUNT" ]] || die "USB mount not found: $USB_MOUNT"
[[ -d "$ISO_DIR" ]]   || die "ISO dir not found: $ISO_DIR"

# --- 0. Fail closed: never initialize a stick; Ventoy must already be there --
[[ -d "$USB_MOUNT/ventoy" ]] || die \
    "No 'ventoy' directory on $USB_MOUNT. This script only stages a Ventoy-PREPARED stick -- install Ventoy with Ventoy2Disk first. Refusing to write to unprepared media."

json_escape() {  # json_escape <string> -> JSON string literal (via python3)
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# --- 1. ISO set: locate + hash-verify + copy ---------------------------------
# [VERIFY] Phoenix WinPE ISO is not built yet (BOOT-ARCHITECTURE.md section 4).
# The entry stays in the table so the stager fails LOUDLY instead of silently
# shipping a 4-entry stick.
ISO_SPECS=(  # pattern|dest|role
    "systemrescue-*-amd64.iso|ISOs|ANALYZE"
    "rescuezilla-*-64bit.iso|ISOs|BACKUP"
    "ShredOS-*_x86_64.iso|ISOs|NUKE"
    "Win11_*_English_x64.iso|ISOs|REINSTALL"
    "phoenix-winpe.iso|ISOs|TOOLKIT"
)

declare -A ISO_FILES ISO_SHA   # role -> filename / sha256

hash_for() {  # hash_for <filename> -> expected sha256 from the sidecar
    python3 - "$ISO_HASHES" "$1" <<'PY'
import json, sys
sidecar, name = sys.argv[1], sys.argv[2]
print(json.load(open(sidecar)).get(name, ""))
PY
}

stage_isos() {
    local spec pattern dest role found expected actual
    for spec in "${ISO_SPECS[@]}"; do
        pattern="${spec%%|*}"; rest="${spec#*|}"; dest="${rest%%|*}"; role="${rest##*|}"
        found="$(ls -1 "$ISO_DIR"/$pattern 2>/dev/null | sort | tail -n 1 || true)"
        [[ -n "$found" ]] || die "[$role] No ISO matching '$pattern' in $ISO_DIR. Stager fails closed: missing asset, no USB."
        found="$(basename "$found")"
        if (( SKIP_HASH_CHECK == 0 )); then
            expected="$(hash_for "$found")"
            [[ -n "$expected" ]] || die "[$role] No hash entry for '$found' in $ISO_HASHES. Refusing to stage an unverified ISO."
            actual="$(sha256sum "$ISO_DIR/$found" | cut -d' ' -f1)"
            [[ "${actual,,}" == "${expected,,}" ]] || die "[$role] HASH MISMATCH for '$found'. Expected $expected, got $actual. Aborting."
            say "[$role] hash OK: $found"
        fi
        mkdir -p "$USB_MOUNT/$dest"
        if (( DRY_RUN == 0 )); then
            if [[ -e "$USB_MOUNT/$dest/$found" && $FORCE -eq 0 ]]; then
                die "[$role] $USB_MOUNT/$dest/$found already exists (use --force to overwrite)."
            fi
            cp -f "$ISO_DIR/$found" "$USB_MOUNT/$dest/$found"
        fi
        ISO_FILES[$role]="$found"
        ISO_SHA[$role]="$(sha256sum "$ISO_DIR/$found" | cut -d' ' -f1)"
        say "[$role] staged: $found"
    done
}

# --- 2. ventoy/ventoy.json ----------------------------------------------------
write_ventoy_json() {
    local win="${ISO_FILES[REINSTALL]}"
    local out="$USB_MOUNT/ventoy/ventoy.json"
    local json
    json="$(cat <<JSON
{
  "control": [
    { "key": "VTOY_DEFAULT_MENU_MODE", "value": "0" }
  ],
  "menu_alias": [
    { "image": "/ISOs/$(json_escape "${ISO_FILES[ANALYZE]}" | tr -d '"')", "alias": "[1] ANALYZE -- SystemRescue" },
    { "image": "/ISOs/$(json_escape "${ISO_FILES[BACKUP]}" | tr -d '"')", "alias": "[2] BACKUP -- Rescuezilla" },
    { "image": "/ISOs/$(json_escape "${ISO_FILES[NUKE]}" | tr -d '"')", "alias": "[3] NUKE -- ShredOS" },
    { "image": "/ISOs/$(json_escape "$win" | tr -d '"')", "alias": "[4] REINSTALL -- Windows 11 (unattended)" },
    { "image": "/ISOs/$(json_escape "${ISO_FILES[TOOLKIT]}" | tr -d '"')", "alias": "[5] TOOLKIT -- Phoenix WinPE" }
  ],
  "auto_install": [
    { "image": "/ISOs/$(json_escape "$win" | tr -d '"')", "template": "/autounattend.xml" }
  ]
}
JSON
)"
    if (( DRY_RUN == 0 )); then
        printf '%s\n' "$json" > "$out"
    fi
    say "menu config: $out"
}

# --- 3. phoenix-config.json (schema v1) ---------------------------------------
write_config() {
    local pw="$PASSWORD"
    if [[ -z "$pw" ]]; then
        read -r -s -p "Install-time password for '$USERNAME' (stored reversibly on the USB -- see security note): " pw
        echo ""
    fi
    [[ -n "$pw" ]] || die "Password is required: unattend cannot create the account without one."
    local apps_json="[]"
    if [[ -n "$APPS" ]]; then
        apps_json="$(python3 -c 'import json,sys; print(json.dumps([{"id": a.strip(), "source": "choco"} for a in sys.argv[1].split(",") if a.strip()]))' "$APPS")"
    fi
    local out="$USB_MOUNT/phoenix-config.json"
    if (( DRY_RUN == 0 )); then
        python3 - "$out" "$COMPUTER_NAME" "$TIMEZONE" "$USERNAME" "$pw" "$EDITION" "$PRODUCT_KEY" "$apps_json" <<'PY'
import json, sys
out, computer, tz, user, pw, edition, key, apps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], json.loads(sys.argv[8])
cfg = {
    "schemaVersion": 1,
    "machine": {"computerName": computer, "timezone": tz},
    "credentials": {"username": user, "password": pw},
    "os": {"family": "windows", "edition": edition, "productKey": key,
           "answerFile": {"disableWPBT": True, "partitionLayout": "gpt-uefi"}},
    "apps": apps,
}
open(out, "w").write(json.dumps(cfg, indent=2) + "\n")
PY
    fi
    say "config: $out"
}

# --- 4. stage toolbox + write manifest.json ------------------------------------
stage_toolbox() {
    local phoenix_dir="$USB_MOUNT/phoenix"
    mkdir -p "$phoenix_dir/scripts" "$phoenix_dir/tools" "$phoenix_dir/WinPE"
    if (( DRY_RUN == 0 )); then
        [[ -d "$REPO/scripts" ]] && cp -rf "$REPO/scripts/." "$phoenix_dir/scripts/"
        [[ -d "$REPO/tools" ]] && cp -rf "$REPO/tools/." "$phoenix_dir/tools/"
    fi
    say "toolbox staged under $phoenix_dir/"
    # manifest with sha256 of everything staged
    local out="$phoenix_dir/manifest.json"
    if (( DRY_RUN == 0 )); then
        {
            echo "Staged ISOs:"
            for role in ANALYZE BACKUP NUKE REINSTALL TOOLKIT; do
                printf '  %s: %s  sha256=%s\n' "$role" "${ISO_FILES[$role]}" "${ISO_SHA[$role]}"
            done
        } > /dev/null  # (human log only; JSON below is the manifest)
        python3 - "$out" <<PY
import json, hashlib, os, datetime
root = os.path.join("$USB_MOUNT", "phoenix")
files = []
for dp, _, fns in os.walk(root):
    for fn in sorted(fns):
        if os.path.join(dp, fn) == "$out":
            continue
        p = os.path.join(dp, fn)
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        files.append({"path": os.path.relpath(p, "$USB_MOUNT"), "sha256": h.hexdigest()})
manifest = {
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "builtBy": os.environ.get("USER", "unknown"),
    "schemaVersion": 1,
    "files": files,
    "notes": [
        "Phoenix WinPE ISO not built yet -- TOOLKIT entry will fail until the ADK build lands.",
        "Explorer++ not vendored yet -- stage phoenix/tools/Explorer++.zip manually.",
        "autounattend.xml at USB root is hand-placed until the config GUI generates it.",
    ],
}
# fill the iso list properly (bash assoc arrays are awkward to inline)
manifest["isos"] = [
    {"role": "ANALYZE", "fileName": "${ISO_FILES[ANALYZE]}", "sha256": "${ISO_SHA[ANALYZE]}"},
    {"role": "BACKUP", "fileName": "${ISO_FILES[BACKUP]}", "sha256": "${ISO_SHA[BACKUP]}"},
    {"role": "REINSTALL", "fileName": "${ISO_FILES[REINSTALL]}", "sha256": "${ISO_SHA[REINSTALL]}"},
    {"role": "NUKE", "fileName": "${ISO_FILES[NUKE]}", "sha256": "${ISO_SHA[NUKE]}"},
    {"role": "TOOLKIT", "fileName": "${ISO_FILES[TOOLKIT]}", "sha256": "${ISO_SHA[TOOLKIT]}"},
]
open("$out", "w").write(json.dumps(manifest, indent=2) + "\n")
PY
    fi
    say "manifest: $out"
}

stage_isos
write_ventoy_json
write_config
stage_toolbox

echo ""
say "Phoenix USB staged on $USB_MOUNT"
say "Remaining manual steps:"
say "  - Build + stage phoenix-winpe.iso (ADK, BOOT-ARCHITECTURE.md section 4)"
say "  - Stage phoenix/tools/Explorer++.zip"
say "  - Generate / place autounattend.xml at USB root"
say "  - Boot-test on the target machine; enroll the Ventoy MOK key at first boot"
