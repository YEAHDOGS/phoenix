#!/usr/bin/env bash
#===============================================================================
# New-UnattendXml.sh -- bash twin of tools/New-UnattendXml.ps1
#
# Generates a Windows unattended answer file (autounattend.xml) from the
# Phoenix tokenized template, on a LINUX machine (the .ps1 twin does the
# same from Windows). Same contract, same fail-closed behavior:
#
#   1. Validates ComputerName / Username / ProductKey exactly like the .ps1
#      (bad values abort before anything is written).
#   2. Fills win-install/autounattend.template.xml with the machine identity,
#      local accounts, timezone, edition and product key, and writes the
#      result to win-install/staging/autounattend.xml.
#   3. Reproduces the Schneegans "ObscurePasswords" encoding
#      (base64( UTF-16LE( password + "Password" ) )) and rewrites the
#      schneegans.de generator comment so the filled file stays regenerable
#      by hand at https://schneegans.de/windows/unattend-generator/.
#
# This generator is the ONLY source of credentials in Phoenix on Linux.
# The template is credential-free and safe to commit; the filled file
# carries real local-account passwords (the unattend format requires them
# -- even the "obscured" form is reversible) and is gitignored via
# win-install/staging/.
#
# USAGE:
#   tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando
#   # prompts securely for the password (stays out of shell history),
#   # writes win-install/staging/autounattend.xml.
#
#   tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando \
#       --password 's3cr3t!' --standard-username guest --force
#
# SECURITY: the filled file CONTAINS REAL CREDENTIALS. Copy it to the USB
# as autounattend.xml, rotate the password at first logon, and NEVER commit
# the staging directory.
#
# Exit codes: 0 = wrote the file | 1 = usage/validation/generation error
#===============================================================================
set -euo pipefail

PROG="$(basename "$0")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

COMPUTER_NAME=""; USERNAME=""; PASSWORD=""
STANDARD_USERNAME=""; STANDARD_PASSWORD=""
TIMEZONE="Central Standard Time"
EDITION="Windows 11 Pro"
PRODUCT_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T"
TEMPLATE="$REPO/win-install/autounattend.template.xml"
OUTPUT="$REPO/win-install/staging/autounattend.xml"
FORCE=0

usage() {
    cat <<EOF
Phoenix answer-file generator (Linux twin of tools/New-UnattendXml.ps1).

Usage:
  $PROG --computer-name <name> --username <name> [options]

Required:
  --computer-name <n>   NetBIOS computer name, 1-15 chars (letters, digits, hyphens)
  --username <n>        primary local account (Administrators, AutoLogon x1)

Options:
  --password <p>        admin password; prompted securely (hidden input) if omitted
  --standard-username <n>  optional second account (Users group)
  --standard-password <p>  its password; prompted securely if omitted
  --timezone <tz>       default: Central Standard Time
  --edition <e>         default: Windows 11 Pro
  --product-key <k>     default: $PRODUCT_KEY (public generic key, not a license)
  --template <file>     default: win-install/autounattend.template.xml
  --output <file>       default: win-install/staging/autounattend.xml (gitignored)
  --force               overwrite the output file if it already exists
EOF
}

die() { echo "[$PROG] FATAL: $*" >&2; exit 1; }

while (( $# > 0 )); do
    case "$1" in
        --computer-name)     COMPUTER_NAME="${2:?}"; shift 2 ;;
        --username)          USERNAME="${2:?}"; shift 2 ;;
        --password)          PASSWORD="${2:?}"; shift 2 ;;
        --standard-username) STANDARD_USERNAME="${2:?}"; shift 2 ;;
        --standard-password) STANDARD_PASSWORD="${2:?}"; shift 2 ;;
        --timezone)          TIMEZONE="${2:?}"; shift 2 ;;
        --edition)           EDITION="${2:?}"; shift 2 ;;
        --product-key)       PRODUCT_KEY="${2:?}"; shift 2 ;;
        --template)          TEMPLATE="${2:?}"; shift 2 ;;
        --output)            OUTPUT="${2:?}"; shift 2 ;;
        --force)             FORCE=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- validate inputs (mirrors the .ps1's [ValidatePattern]/[ValidateScript]) --
[[ -n "$COMPUTER_NAME" ]] || die "--computer-name is required"
[[ -n "$USERNAME" ]]      || die "--username is required"
[[ "$COMPUTER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ ]] \
    || die "ComputerName must be 1-15 chars of letters/digits/hyphens, got: $COMPUTER_NAME"
[[ -n "$TIMEZONE" ]] || die "--timezone must not be empty"
case "$EDITION" in
    *\"*|*$'\r'*|*$'\n'*) die "--edition must not contain quotes or newlines" ;;
esac
shopt -s nocasematch
[[ "$PRODUCT_KEY" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]] \
    || die "ProductKey must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, got: $PRODUCT_KEY"
shopt -u nocasematch
if [[ -n "$STANDARD_USERNAME" && "$STANDARD_USERNAME" == "$USERNAME" ]]; then
    die "StandardUsername '$STANDARD_USERNAME' must differ from Username '$USERNAME'."
fi
[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"
if [[ -e "$OUTPUT" && $FORCE -eq 0 ]]; then
    die "Output file already exists: $OUTPUT (use --force to overwrite)"
fi

# --- passwords: prompt securely when omitted, keep them out of history --------
if [[ -z "$PASSWORD" ]]; then
    read -r -s -p "Password for local admin '$USERNAME': " PASSWORD
    echo ""
fi
[[ -n "$PASSWORD" ]] || die "Password for '$USERNAME' cannot be empty."
if [[ -n "$STANDARD_USERNAME" && -z "$STANDARD_PASSWORD" ]]; then
    read -r -s -p "Password for standard account '$STANDARD_USERNAME': " STANDARD_PASSWORD
    echo ""
fi
if [[ -n "$STANDARD_USERNAME" && -z "$STANDARD_PASSWORD" ]]; then
    die "Password for '$STANDARD_USERNAME' cannot be empty."
fi

# --- generate ------------------------------------------------------------------
# python3 does the exact byte-level transform the .ps1 performs: comment
# rewrite (URL-encoded, spaces as '+'), body token fill (XML-escaped), the
# Schneegans password obfuscation (base64 of UTF-16LE(password + "Password")),
# the origin stamp (no '--' inside an XML comment -- a '--' mid-comment makes
# the file not well-formed), the leftover-token gate, and the well-formedness
# gate. Input via argv; the filled file is written as UTF-8, no BOM, LF only.
python3 - "$TEMPLATE" "$OUTPUT" "$COMPUTER_NAME" "$USERNAME" "$PASSWORD" \
    "$STANDARD_USERNAME" "$STANDARD_PASSWORD" "$TIMEZONE" "$EDITION" \
    "$PRODUCT_KEY" <<'PY' || exit 1
import base64, re, sys, urllib.parse, xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

(tpl, out, computer, user, pw,
 std_user, std_pw, tz, edition, key) = sys.argv[1:11]

def obscure(p):
    # Schneegans "ObscurePasswords": base64( UTF-16LE( password + "Password" ) )
    return base64.b64encode((p + "Password").encode("utf-16-le")).decode()

def urlenc(v):
    # matches [Uri]::EscapeDataString, spaces as '+' like the proven file
    return urllib.parse.quote(v, safe="-._~").replace("%20", "+")

def xmlesc(v):
    # matches [System.Security.SecurityElement]::Escape
    return (v.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;"))

content = Path(tpl).read_text(encoding="utf-8")

# -- rewrite the Schneegans generator comment to match chosen options --
m = re.search(r"<!--https://schneegans\.de/windows/unattend-generator/\?.*?-->",
              content, re.S)
if not m:
    sys.exit("Template is missing the Schneegans generator comment; refusing to guess.")
comment = m.group(0)
# Mirror the .ps1's explicit token replaces (keep every token literal).
comment = comment.replace("{{COMPUTER_NAME}}", urlenc(computer))
comment = comment.replace("{{TIME_ZONE}}", urlenc(tz))
comment = comment.replace("{{EDITION_NAME}}", urlenc(edition))
comment = comment.replace("{{PRODUCT_KEY}}", urlenc(key))
comment = comment.replace("{{ACCOUNT_NAME}}", urlenc(user))
comment = comment.replace("{{ACCOUNT_PASSWORD}}", urlenc(pw))
if std_user:
    comment = comment.replace("{{STANDARD_ACCOUNT_NAME}}", urlenc(std_user))
    comment = comment.replace("{{STANDARD_ACCOUNT_PASSWORD}}", urlenc(std_pw))
else:
    # Single-account file: drop the second-account params from the regen URL.
    comment = re.sub(r"&Account(Name|DisplayName|Password|Group)1=[^&]*", "", comment)
content = content[:m.start()] + comment + content[m.end():]

# Stamp the file so its origin is obvious on the USB. An XML comment must not
# contain '--' anywhere but its terminator -- use periods, never double dashes.
stamp = ("<!-- Generated by Phoenix tools/New-UnattendXml.sh on "
         + datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + "Z"
         + ". CONTAINS REAL CREDENTIALS, DO NOT COMMIT. -->")
content = content.replace(comment, comment + "\n\t" + stamp)

# -- fill body tokens --
admin_b64 = obscure(pw)
if std_user:
    std_b64 = obscure(std_pw)
    std_name = xmlesc(std_user)
    # First line inherits the template's 5-tab indent; the rest is explicit.
    block = ('<LocalAccount wcm:action="add">\n'
             '\t\t\t\t\t\t<Name>' + std_name + '</Name>\n'
             '\t\t\t\t\t\t<DisplayName></DisplayName>\n'
             '\t\t\t\t\t\t<Group>Users</Group>\n'
             '\t\t\t\t\t\t<Password>\n'
             '\t\t\t\t\t\t\t<Value>' + std_b64 + '</Value>\n'
             '\t\t\t\t\t\t\t<PlainText>false</PlainText>\n'
             '\t\t\t\t\t\t</Password>\n'
             '\t\t\t\t\t</LocalAccount>')
    content = content.replace("{{STANDARD_ACCOUNT_XML}}", block)
else:
    # Remove the token's whole line so no blank indented line is left behind.
    content = re.sub(r"(?m)^\t*{{STANDARD_ACCOUNT_XML}}\r?\n", "", content)

content = content.replace("{{COMPUTER_NAME}}", xmlesc(computer))
content = content.replace("{{PRODUCT_KEY}}", key)
content = content.replace("{{TIME_ZONE}}", xmlesc(tz))
content = content.replace("{{EDITION_NAME}}", edition)
content = content.replace("{{ACCOUNT_NAME}}", xmlesc(user))
content = content.replace("{{ACCOUNT_PASSWORD_B64}}", admin_b64)

# -- safety: no token may survive --
leftover = re.search(r"\{\{[A-Z_]+\}\}", content)
if leftover:
    sys.exit(f"Unfilled token left in output: {leftover.group(0)}. Aborting.")

# -- the filled file must still be well-formed XML --
try:
    ET.fromstring(content)
except ET.ParseError as e:
    sys.exit(f"Generated file is not well-formed XML: {e}")

# -- write to staging: UTF-8, no BOM, LF endings (matches the template) --
outp = Path(out)
outp.parent.mkdir(parents=True, exist_ok=True)
outp.write_text(content.replace("\r\n", "\n"), encoding="utf-8")
PY

echo "Wrote $OUTPUT"
echo "  Computer : $COMPUTER_NAME"
echo "  Admin    : $USERNAME (Administrators, AutoLogon x1)"
if [[ -n "$STANDARD_USERNAME" ]]; then echo "  Standard : $STANDARD_USERNAME (Users)"; fi
echo "  Timezone : $TIMEZONE"
echo "  Edition  : $EDITION"
echo ""
echo "Staging dir is gitignored - copy this file to the USB as autounattend.xml."
