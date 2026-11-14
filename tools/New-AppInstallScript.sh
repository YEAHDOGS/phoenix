#!/usr/bin/env bash
#===============================================================================
# New-AppInstallScript.sh -- Linux-side twin of tools/New-AppInstallScript.ps1
#
# Emits a self-contained, setup-time PowerShell installer for the Phoenix app
# picker. The emitted installer (app-install.ps1) runs on the REBUILT Windows
# machine during OOBE FirstLogonCommands:
#   - installs Chocolatey itself when missing (online bootstrap),
#   - refreshes PATH so `choco` is usable in the same process,
#   - installs the selected packages with `choco install -y --no-progress`,
#   - skips packages already installed (idempotent; safe to re-run),
#   - logs everything to C:\Phoenix\Logs\app-install.log,
#   - never fails OOBE: it always exits 0 even when packages fail.
#
# EMISSION PARITY: the emitted script text is byte-identical to what the
# PowerShell generator emits for the same inputs. The template is EXTRACTED
# from tools/New-AppInstallScript.ps1 (its single-quoted here-string between
# `$script = @'` and the closing `'@` line) -- there is one source of truth,
# so a template edit in the .ps1 can never silently drift from this twin.
# The PS emission rules are then applied exactly:
#   - package lines `    'name',` joined with CRLF, trailing comma stripped
#     (PS: `$packageLines -join "`r`n"`, `.TrimEnd(',')`)
#   - `@@PACKAGE_BLOCK@@` / `@@CHOCO_SOURCE@@` substitution (source with
#     `'` escaped to `''`, mirroring the PS `.Replace` calls)
#   - `$script.TrimStart() + "`r`n"` (template already starts at `<#`,
#     so the emitted file ends `exit 0` + CRLF, LF elsewhere)
#
# Usage:
#   ./tools/New-AppInstallScript.sh --use-defaults [--output win-install/staging/app-install.ps1]
#   ./tools/New-AppInstallScript.sh --packages GoogleChrome,Steam,VLC
#   ./tools/New-AppInstallScript.sh --use-defaults --choco-source 'C:\Phoenix\Feed' --output app-install.ps1
#
# Selection rules (parity with the PS version):
#   - exactly one of --packages / --use-defaults is required
#   - --use-defaults: defaultSelected entries from data/choco-install/apps.json;
#     entries with "source": "manual" are skipped with a stderr warning
#   - package names must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ or the run aborts
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

PACKAGES=""
USE_DEFAULTS=0
APPS_JSON="$REPO/data/choco-install/apps.json"
CHOCO_SOURCE="https://community.chocolatey.org/api/v2/"
OUTPUT=""

usage() {
    sed -n '2,/^#===/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --packages)     PACKAGES="$2"; shift 2 ;;
        --use-defaults) USE_DEFAULTS=1; shift ;;
        --apps-json)    APPS_JSON="$2"; shift 2 ;;
        --choco-source) CHOCO_SOURCE="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage 1 ;;
    esac
done

die() { echo "ERROR: $1" >&2; exit 1; }

# --- selection (parity with the PS param block) --------------------------------
if [[ -n "$PACKAGES" && "$USE_DEFAULTS" -eq 1 ]]; then
    die "Use either --packages or --use-defaults, not both."
fi
if [[ -z "$PACKAGES" && "$USE_DEFAULTS" -eq 0 ]]; then
    die "Use either --packages <a,b,c> or --use-defaults."
fi

if [[ "$USE_DEFAULTS" -eq 1 ]]; then
    [[ -f "$APPS_JSON" ]] || die "Catalog not found: $APPS_JSON"
    # One package name per line; manual-source entries go to stderr as warnings.
    MAPFILE="$(mktemp /tmp/phx-appsel.XXXXXX)"
    trap 'rm -f "$MAPFILE"' EXIT
    python3 - "$APPS_JSON" > "$MAPFILE" <<'PYEOF'
import json, sys
catalog = json.load(open(sys.argv[1]))
if not isinstance(catalog, list):
    sys.exit("catalog is not a JSON array")
for e in catalog:
    if not e.get("defaultSelected"):
        continue
    pkg = e.get("package", "")
    if e.get("source") == "manual":
        sys.stderr.write("WARNING: Skipping '%s': %s\n" % (pkg, e.get("note", "")))
        continue
    print(pkg)
PYEOF
    mapfile -t SELECTED < "$MAPFILE"
else
    IFS=',' read -r -a SELECTED <<< "$PACKAGES"
    # Trim incidental whitespace around names.
    for i in "${!SELECTED[@]}"; do
        SELECTED[$i]="$(printf '%s' "${SELECTED[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    done
    # Drop empties (e.g. --packages "").
    tmp=()
    for p in "${SELECTED[@]}"; do [[ -n "$p" ]] && tmp+=("$p"); done
    SELECTED=("${tmp[@]}")
fi

[[ ${#SELECTED[@]} -gt 0 ]] || die "No packages selected; nothing to emit."

for name in "${SELECTED[@]}"; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "Suspicious package name rejected: '$name'"
done

# --- emit (parity with the PS template/substitution rules) ----------------------
EMITTED="$(python3 - "$REPO/tools/New-AppInstallScript.ps1" "$CHOCO_SOURCE" "${SELECTED[@]}" <<'PYEOF'
import sys

ps1_path, choco_source = sys.argv[1], sys.argv[2]
packages = sys.argv[3:]

# Single source of truth: the here-string template in the .ps1 generator.
lines = open(ps1_path, encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if l == "$script = @'")
end = next(i for i, l in enumerate(lines) if i > start and l == "'@")
template = "\n".join(lines[start + 1:end])   # PS here-string: no trailing newline
if "@@PACKAGE_BLOCK@@" not in template or "@@CHOCO_SOURCE@@" not in template:
    sys.exit("template markers missing in %s -- refusing to guess" % ps1_path)

def psq(s):  # PowerShell single-quote literal escape (parity with .Replace)
    return s.replace("'", "''")

block = "\r\n".join("    '%s'," % psq(p) for p in packages).rstrip(",")
emitted = (template
    .replace("@@PACKAGE_BLOCK@@", block)
    .replace("@@CHOCO_SOURCE@@", psq(choco_source)))
emitted = emitted.lstrip() + "\r\n"          # $script.TrimStart() + "`r`n"
sys.stdout.write(emitted)
PYEOF
)"

if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    # NOTE: $( ) strips the python's trailing newline, leaving the emitted
    # "\r" orphaned; printf '%s\n' restores the exact "exit 0\r\n" ending the
    # PS generator produces ($script.TrimStart() + "`r`n").
    printf '%s\n' "$EMITTED" > "$OUTPUT"
    echo "Wrote ${#SELECTED[@]} packages to $OUTPUT"
else
    printf '%s\n' "$EMITTED"
fi
