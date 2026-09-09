#!/usr/bin/env bash
#===============================================================================
# New-UnattendXml.sh -- Linux-side twin of tools/New-UnattendXml.ps1
#
# Generates a Windows unattended answer file (autounattend.xml) from the
# Phoenix tokenized template, with EXACT parity to the PowerShell version:
#   - same Schneegans obscure-password encoding: base64(UTF-16LE(password+"Password"))
#   - same URL-encoding rules for the regen comment (EscapeDataString, ' ' -> '+')
#   - same XML-escaping rules for body tokens
#   - same validation gates, same no-leftover-token gate, same well-formed XML gate
#   - output: UTF-8 no-BOM, LF line endings, into win-install/staging/ (gitignored)
#
# This generator is a source of credentials: the filled file carries real
# local-account passwords (the unattend format requires them -- even the
# "obscured" form is reversible). Never commit the output.
#
# Usage:
#   ./tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando [--force]
#   ./tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando \
#       --password 'hunter2' --standard-username guest --standard-password 'x' --force
#
# Passwords: omit --password to be prompted securely (read -s). Avoid passing
# real passwords on the command line (visible in process lists).
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPUTER_NAME=""
USERNAME=""
PASSWORD=""
STANDARD_USERNAME=""
STANDARD_PASSWORD=""
TIMEZONE="Central Standard Time"
EDITION="Windows 11 Pro"
PRODUCT_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T"
TEMPLATE="$REPO/win-install/autounattend.template.xml"
OUTPUT="$REPO/win-install/staging/autounattend.xml"
FORCE=0

usage() {
    sed -n '2,/^#===/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --computer-name)     COMPUTER_NAME="$2"; shift 2 ;;
        --username)          USERNAME="$2"; shift 2 ;;
        --password)          PASSWORD="$2"; shift 2 ;;
        --standard-username) STANDARD_USERNAME="$2"; shift 2 ;;
        --standard-password) STANDARD_PASSWORD="$2"; shift 2 ;;
        --timezone)          TIMEZONE="$2"; shift 2 ;;
        --edition)           EDITION="$2"; shift 2 ;;
        --product-key)       PRODUCT_KEY="$2"; shift 2 ;;
        --template)          TEMPLATE="$2"; shift 2 ;;
        --output)            OUTPUT="$2"; shift 2 ;;
        --force)             FORCE=1; shift ;;
        -h|--help)           usage 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage 1 ;;
    esac
done

die() { echo "ERROR: $1" >&2; exit 1; }

# --- validate inputs (parity with the PS Validate* attributes) -----------------
[[ -n "$COMPUTER_NAME" ]] || die "--computer-name is required"
[[ "$COMPUTER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ ]] \
    || die "ComputerName '$COMPUTER_NAME' invalid: 1-15 chars, letters/digits/hyphens, must start with a letter or digit."
[[ -n "$USERNAME" ]] || die "--username is required"
[[ -n "$TIMEZONE" ]] || die "--timezone cannot be empty"
if [[ "$EDITION" == *$'\n'* || "$EDITION" == *$'\r'* || "$EDITION" == *\"* ]]; then
    die "--edition must not contain quotes or newlines"
fi
[[ "$PRODUCT_KEY" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]] \
    || die "ProductKey '$PRODUCT_KEY' invalid: must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"
[[ ! -e "$OUTPUT" || $FORCE -eq 1 ]] \
    || die "Output file already exists: $OUTPUT (use --force to overwrite)"

# --- credentials (prompt, never echo) -----------------------------------------
prompt_pw() {
    local label="$1" pw=""
    if [[ -t 0 ]]; then
        read -r -s -p "Password for $label: " pw || true
        echo >&2
    fi
    [[ -n "$pw" ]] || die "Password for '$label' cannot be empty."
    printf '%s' "$pw"
}
[[ -n "$PASSWORD" ]] || PASSWORD="$(prompt_pw "local admin '$USERNAME'")"
if [[ -n "$STANDARD_USERNAME" ]]; then
    [[ "$STANDARD_USERNAME" != "$USERNAME" ]] \
        || die "StandardUsername '$STANDARD_USERNAME' must differ from Username '$USERNAME'."
    [[ -n "$STANDARD_PASSWORD" ]] || STANDARD_PASSWORD="$(prompt_pw "standard account '$STANDARD_USERNAME'")"
fi

# --- encodings (exact parity with the PS helpers) ------------------------------
obscure() { # Schneegans: base64( UTF-16LE( password + "Password" ) )
    printf '%s' "$1Password" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}
urlenc() {  # [Uri]::EscapeDataString, spaces as '+'
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="-._~").replace("%20","+"))' "$1"
}
xmlesc() {  # [Security.SecurityElement]::Escape
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

ADMIN_B64="$(obscure "$PASSWORD")"
ADMIN_URLENC_PW="$(urlenc "$PASSWORD")"
if [[ -n "$STANDARD_USERNAME" ]]; then
    STD_B64="$(obscure "$STANDARD_PASSWORD")"
    STD_URLENC_PW="$(urlenc "$STANDARD_PASSWORD")"
fi

# The content transformation needs true regexes; delegate that half to
# python3 with the EXACT rule order of the PS version (comment tokens first,
# scoped to the comment; then body tokens on the whole document).
STAMP="<!-- Generated by Phoenix tools/New-UnattendXml.sh on $(date -u '+%Y-%m-%d %H:%M:%SZ'). CONTAINS REAL CREDENTIALS, DO NOT COMMIT. -->"

export PHX_COMMENT_NAME PHX_COMMENT_TZ PHX_COMMENT_EDITION PHX_COMMENT_KEY \
       PHX_COMMENT_USER PHX_COMMENT_PW PHX_COMMENT_STDUSER PHX_COMMENT_STDPW \
       PHX_BODY_NAME PHX_BODY_TZ PHX_BODY_EDITION PHX_BODY_KEY PHX_BODY_USER \
       PHX_ADMIN_B64 PHX_STD_B64 PHX_STD_USER_XML PHX_STAMP PHX_TEMPLATE PHX_HAS_STD
PHX_COMMENT_NAME="$(urlenc "$COMPUTER_NAME")"
PHX_COMMENT_TZ="$(urlenc "$TIMEZONE")"
PHX_COMMENT_EDITION="$(urlenc "$EDITION")"
PHX_COMMENT_KEY="$(urlenc "$PRODUCT_KEY")"
PHX_COMMENT_USER="$(urlenc "$USERNAME")"
PHX_COMMENT_PW="$ADMIN_URLENC_PW"
PHX_COMMENT_STDUSER="$([ -n "$STANDARD_USERNAME" ] && urlenc "$STANDARD_USERNAME" || printf '')"
PHX_COMMENT_STDPW="${STD_URLENC_PW:-}"
PHX_BODY_NAME="$(xmlesc "$COMPUTER_NAME")"
PHX_BODY_TZ="$(xmlesc "$TIMEZONE")"
PHX_BODY_EDITION="$EDITION"
PHX_BODY_KEY="$PRODUCT_KEY"
PHX_BODY_USER="$(xmlesc "$USERNAME")"
PHX_ADMIN_B64="$ADMIN_B64"
PHX_STD_B64="${STD_B64:-}"
PHX_STD_USER_XML="$([ -n "$STANDARD_USERNAME" ] && xmlesc "$STANDARD_USERNAME" || printf '')"
PHX_STAMP="$STAMP"
PHX_TEMPLATE="$TEMPLATE"
PHX_HAS_STD="$([ -n "$STANDARD_USERNAME" ] && echo 1 || echo 0)"

# --- single bash/two-account block (exact whitespace of the PS version) --------
if [[ "$PHX_HAS_STD" == "1" ]]; then
    STD_BLOCK="$(printf '<LocalAccount wcm:action="add">\n\t\t\t\t\t\t<Name>%s</Name>\n\t\t\t\t\t\t<DisplayName></DisplayName>\n\t\t\t\t\t\t<Group>Users</Group>\n\t\t\t\t\t\t<Password>\n\t\t\t\t\t\t\t<Value>%s</Value>\n\t\t\t\t\t\t\t<PlainText>false</PlainText>\n\t\t\t\t\t\t</Password>\n\t\t\t\t\t</LocalAccount>' "$PHX_STD_USER_XML" "$PHX_STD_B64")"
else
    STD_BLOCK=""
fi
export PHX_STD_BLOCK="$STD_BLOCK"

WORK="$(mktemp /tmp/phx-xml.XXXXXX)"
trap 'rm -f "$WORK"' EXIT

python3 - "$WORK" <<'PYEOF'
import os, re, sys, xml.dom.minidom
from pathlib import Path

out = sys.argv[1]
content = Path(os.environ["PHX_TEMPLATE"]).read_text(encoding="utf-8")

# --- rewrite the Schneegans generator comment to match chosen options ---
comment_re = re.compile(r'<!--https://schneegans\.de/windows/unattend-generator/\?.*?-->',
                        re.DOTALL)
m = comment_re.search(content)
if not m:
    sys.exit("Template is missing the Schneegans generator comment; refusing to guess.")
comment = m.group(0)
comment = (comment
    .replace("{{COMPUTER_NAME}}", os.environ["PHX_COMMENT_NAME"])
    .replace("{{TIME_ZONE}}", os.environ["PHX_COMMENT_TZ"])
    .replace("{{EDITION_NAME}}", os.environ["PHX_COMMENT_EDITION"])
    .replace("{{PRODUCT_KEY}}", os.environ["PHX_COMMENT_KEY"])
    .replace("{{ACCOUNT_NAME}}", os.environ["PHX_COMMENT_USER"])
    .replace("{{ACCOUNT_PASSWORD}}", os.environ["PHX_COMMENT_PW"]))
if os.environ["PHX_HAS_STD"] == "1":
    comment = (comment
        .replace("{{STANDARD_ACCOUNT_NAME}}", os.environ["PHX_COMMENT_STDUSER"])
        .replace("{{STANDARD_ACCOUNT_PASSWORD}}", os.environ["PHX_COMMENT_STDPW"]))
else:
    # Single-account file: drop the second-account params from the regen URL.
    comment = re.sub(r'&Account(Name|DisplayName|Password|Group)1=[^&]*', '', comment)
content = content[:m.start()] + comment + content[m.end():]

# Stamp the file so its origin is obvious on the USB.
# (XML comment must not contain '--' mid-comment; use periods.)
content = content.replace(comment, comment + "\n\t" + os.environ["PHX_STAMP"])

# --- fill body tokens ---
if os.environ["PHX_HAS_STD"] == "1":
    content = content.replace("{{STANDARD_ACCOUNT_XML}}", os.environ["PHX_STD_BLOCK"])
else:
    # Remove the token's whole line so no blank indented line is left behind.
    content = re.sub(r'(?m)^\t*{{STANDARD_ACCOUNT_XML}}\r?\n', '', content)

content = (content
    .replace("{{COMPUTER_NAME}}", os.environ["PHX_BODY_NAME"])
    .replace("{{PRODUCT_KEY}}", os.environ["PHX_BODY_KEY"])
    .replace("{{TIME_ZONE}}", os.environ["PHX_BODY_TZ"])
    .replace("{{EDITION_NAME}}", os.environ["PHX_BODY_EDITION"])
    .replace("{{ACCOUNT_NAME}}", os.environ["PHX_BODY_USER"])
    .replace("{{ACCOUNT_PASSWORD_B64}}", os.environ["PHX_ADMIN_B64"]))

# --- safety: no token may survive ---
leftover = re.search(r'\{\{[A-Z_]+\}\}', content)
if leftover:
    sys.exit(f"Unfilled token left in output: {leftover.group(0)}. Aborting.")

# --- the filled file must still be well-formed XML ---
try:
    xml.dom.minidom.parseString(content.encode("utf-8"))
except Exception as e:
    sys.exit(f"Generated file is not well-formed XML: {e}")

# Match the template: UTF-8, no BOM, LF endings.
Path(out).write_text(content.replace("\r\n", "\n"), encoding="utf-8", newline="")
PYEOF

mkdir -p "$(dirname "$OUTPUT")"
cp "$WORK" "$OUTPUT"

# --- report (credentials stay out of the output) -------------------------------
echo "Wrote $OUTPUT"
echo "  Computer : $COMPUTER_NAME"
echo "  Admin    : $USERNAME (Administrators, AutoLogon x1)"
if [[ -n "$STANDARD_USERNAME" ]]; then
    echo "  Standard : $STANDARD_USERNAME (Users)"
fi
echo "  Timezone : $TIMEZONE"
echo "  Edition  : $EDITION"
echo ""
echo "Staging dir is gitignored - copy this file to the USB as autounattend.xml."
