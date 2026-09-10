#!/usr/bin/env bash
#===============================================================================
# install_apps.sh -- Linux twin of scripts/Install-Apps.ps1
#
# Reads config/apps.json and prints the SAME install plan the PowerShell twin
# would execute on Windows. Chocolatey is Windows-only, so on Linux this is
# always a plan printer: --offline (or no flags at all) lists the selected
# packages, their categories and sources, and flags manual-source entries
# (e.g. Ableton) as post-install steps. Exit 0 always.
#
# Usage:
#   bash scripts/install_apps.sh [--manifest PATH] [--use-defaults]
#       [--packages GoogleChrome,Steam] [--offline] [--choco-source PATH]
#===============================================================================
set -euo pipefail

MANIFEST="$(cd "$(dirname "$0")/../config" && pwd)/apps.json"
USE_DEFAULTS=0
PACKAGES=""
OFFLINE=0
CHOCO_SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)      MANIFEST="$2"; shift 2 ;;
        --use-defaults) USE_DEFAULTS=1; shift ;;
        --packages)      PACKAGES="$2"; shift 2 ;;
        --offline)       OFFLINE=1; shift ;;
        --choco-source)  CHOCO_SOURCE="$2"; shift 2 ;;
        *) echo "error: unknown flag $1" >&2; exit 1 ;;
    esac
done

[[ -f "$MANIFEST" ]] || { echo "error: app manifest not found: $MANIFEST" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 required for manifest parsing" >&2; exit 1; }

PLAN="$(python3 - "$MANIFEST" "$USE_DEFAULTS" "$PACKAGES" <<'EOF'
import json, sys
manifest, use_defaults, packages = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
catalog = json.load(open(manifest, encoding="utf-8"))
by_id = {e["package"]: e for e in catalog}
if packages:
    wanted = [p.strip() for p in packages.split(",") if p.strip()]
else:
    wanted = [e["package"] for e in catalog if e.get("defaultSelected")]
for pkg in wanted:
    if pkg not in by_id:
        sys.exit("error: package '%s' is not in the manifest" % pkg)
for pkg in wanted:
    e = by_id[pkg]
    src = e.get("source", "chocolatey") or "chocolatey"
    note = e.get("note", "")
    print("%s\t%s\t%s\t%s\t%s" % (pkg, e.get("category", ""),
          src, "yes" if e.get("defaultSelected") else "no", note))
EOF
)" || { echo "$PLAN" >&2; exit 1; }

COUNT="$(printf '%s\n' "$PLAN" | grep -c . || true)"
echo "Phoenix app-install plan ($COUNT packages)"
printf '%-28s %-18s %s\n' 'PACKAGE' 'CATEGORY' 'SOURCE'
printf '%s\n' "$PLAN" | while IFS=$'\t' read -r pkg cat src def note; do
    printf '%-28s %-18s %s\n' "$pkg" "$cat" "$src"
done
printf '%s\n' "$PLAN" | awk -F'\t' '$3=="manual"{print "  MANUAL STEP: " $1 " -- " $5}'

if [[ "$OFFLINE" == "1" ]]; then
    echo ""
    echo "Offline mode: plan only, nothing installed."
elif [[ -n "$CHOCO_SOURCE" ]]; then
    echo ""
    echo "NOTE: Chocolatey is Windows-only; on Linux this stays a plan."
    echo "On Windows, rerun Install-Apps.ps1 with -ChocoSource '$CHOCO_SOURCE' for the air-gap install."
else
    echo ""
    echo "NOTE: Chocolatey is Windows-only; on Linux this stays a plan."
    echo "On Windows, run scripts/Install-Apps.ps1 (without -Offline) to install."
fi
exit 0
