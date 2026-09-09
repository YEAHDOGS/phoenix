#!/usr/bin/env bash
#===============================================================================
# test-phoenix-config.sh -- regression harness for the Phoenix config writer pair:
#   tools/New-PhoenixConfig.sh   (bash -- executed for real)
#   tools/New-PhoenixConfig.ps1  (PowerShell twin; pwsh is not installed here,
#                                 so the .ps1 is checked structurally -- the
#                                 same convention as the other suites)
#
# PARITY CONTRACT (both writers must hold it):
#   - identical BOOT-ARCHITECTURE §5 schema v1: schemaVersion, machine
#     {computerName,timezone}, credentials {username,password}, os
#     {family,edition,productKey,answerFile{disableWPBT,partitionLayout}},
#     apps[] {id,source}, nuke {protectedDisks[]}
#   - flat-scalar JSON the menu parses headless without jq
#   - password never printed (dry-run redacts to ***REDACTED***)
#   - piped-stdin password refused structurally (echo P | ... can never work)
#   - refusal to write inside a git work tree without --force/--Force
#   - validation: computer name (NetBIOS rule), family set, product-key shape
#
# Coverage:
#   - bash -n syntax on the .sh; .ps1 structural parity (param set, same
#     validation regexes/sets, redacted-copy redaction, git-tree guard,
#     -Password prompt path, no Write-Host of the raw password)
#   - end-to-end: written config is valid JSON with the full schema, and the
#     menu's jget parses computerName/schemaVersion/family out of it
#   - validation rejections leave no file behind
#   - dry-run redacts the password and writes nothing
#   - piped stdin refused even when --password is absent
#   - git-tree guard: refuses inside a repo, writes with --force
#   - JSON escaping: quote/backslash in fields produce valid JSON
#
# Usage: bash tests/tools/test-phoenix-config.sh   (exit 0 = all green)
#===============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$REPO/tools/New-PhoenixConfig.sh"
PS1F="$REPO/tools/New-PhoenixConfig.ps1"
T="$(mktemp -d /tmp/phoenix-config-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_CASES=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL: $1${2:+ -- $2}"; }

#--- static checks ----------------------------------------------------------------
echo "== static =="
bash -n "$SH" && pass "bash -n: .sh parses" || fail "bash -n: .sh parses"

for key in ComputerName Username Password Timezone Family Edition ProductKey \
           KeepWPBT PartitionLayout App ProtectDisk Out DryRun Force; do
    grep -q "\$$key" "$PS1F" && pass ".ps1 param \$$key present" \
        || fail ".ps1 param \$$key present"
done

# validation parity: same regexes/sets in both files (fixed-string match, the
# patterns contain regex metacharacters that are literal text in the sources)
grep -qF "A-Za-z0-9-]{1,15}" "$PS1F" && pass ".ps1 computer-name rule matches .sh" \
    || fail ".ps1 computer-name rule matches .sh"
grep -q 'ValidateSet("windows","linux","macos")' "$PS1F" && pass ".ps1 family set matches .sh" \
    || fail ".ps1 family set matches .sh"
grep -qF '([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}' "$PS1F" && pass ".ps1 product-key shape matches .sh" \
    || fail ".ps1 product-key shape matches .sh"
grep -q "IsInputRedirected" "$PS1F" && pass ".ps1 refuses piped-stdin password" \
    || fail ".ps1 refuses piped-stdin password"
grep -q 'password = "\*\*\*REDACTED\*\*\*"' "$PS1F" && pass ".ps1 redacts via redacted copy" \
    || fail ".ps1 redacts via redacted copy"
grep -q 'Test-Path (Join-Path \$probe ".git")' "$PS1F" && pass ".ps1 git-tree guard present" \
    || fail ".ps1 git-tree guard present"

# .ps1 never writes the raw password to console
if grep -n 'Write-Host.*\$Password\b' "$PS1F" | grep -v REDACTED >/dev/null; then
    fail ".ps1 never Write-Hosts the raw password"
else
    pass ".ps1 never Write-Hosts the raw password"
fi

#--- happy path: write + validate schema -------------------------------------------
echo "== happy path =="
OUT="$T/phoenix-config.json"
"$SH" --computer-name BRANDON-PC --username brandon --password 's3cr"t\pass' \
    --app choco:googlechrome --app choco:steam --out "$OUT" 2>/dev/null
[[ -f "$OUT" ]] && pass "config written" || fail "config written"

if python3 - "$OUT" <<'EOF' >/dev/null 2>&1; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schemaVersion"] == 1
assert d["machine"]["computerName"] == "BRANDON-PC"
assert d["machine"]["timezone"] == "Central Standard Time"
assert d["credentials"]["username"] == "brandon"
assert d["credentials"]["password"] == 's3cr"t\\pass'
assert d["os"]["family"] == "windows"
assert d["os"]["edition"] == "Professional"
assert d["os"]["productKey"] is None
assert d["os"]["answerFile"] == {"disableWPBT": True, "partitionLayout": "gpt-uefi"}
assert d["apps"] == [{"id": "googlechrome", "source": "choco"},
                     {"id": "steam", "source": "choco"}]
EOF
    pass "written config is valid JSON with the full §5 schema"
else
    fail "written config is valid JSON with the full §5 schema"
fi

# defaults: null product key, keep-wpbt off by default, empty apps
"$SH" --computer-name TEST-1 --username u --password p --out "$T/defaults.json" \
    --family linux --product-key ABCDE-FGHIJ-KLMNO-PQRST-UVWXY \
    --answer-keep-wpbt --partition-layout mbr-bios 2>/dev/null
python3 - "$T/defaults.json" <<'EOF' || fail "flag overrides land in the JSON"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["os"]["family"] == "linux"
assert d["os"]["productKey"] == "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
assert d["os"]["answerFile"] == {"disableWPBT": False, "partitionLayout": "mbr-bios"}
assert d["apps"] == []
EOF
pass "flag overrides land in the JSON"

# menu headless-read parity: jget (from the real menu script) parses it
jget() {
    local file="$1" key="$2" v
    v="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"\"]*\"\|[0-9][0-9]*\)" "$file" 2>/dev/null | head -n1 || true)"
    v="${v#*:}"
    v="$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
    printf '%s' "$v"
}
[[ "$(jget "$OUT" schemaVersion)" == "1" ]] && pass "menu jget: schemaVersion" \
    || fail "menu jget: schemaVersion"
[[ "$(jget "$OUT" computerName)" == "BRANDON-PC" ]] && pass "menu jget: computerName" \
    || fail "menu jget: computerName"
[[ "$(jget "$OUT" family)" == "windows" ]] && pass "menu jget: family" \
    || fail "menu jget: family"

# file is not world-readable
[[ "$(stat -c %a "$OUT")" == "600" ]] && pass "written file is mode 600" \
    || fail "written file is mode 600"

#--- validation rejections (no file left behind) ------------------------------------
echo "== validation =="
expect_reject() { # $1 = description, rest = args
    local desc="$1"; shift
    if "$SH" "$@" --out "$T/should-not-exist.json" >/dev/null 2>&1; then
        fail "rejects: $desc (exited 0)"
    else
        pass "rejects: $desc"
    fi
    [[ -f "$T/should-not-exist.json" ]] && fail "no file on reject: $desc" || true
}
expect_reject "computer name too long" --computer-name THIS-NAME-IS-WAY-TOO-LONG --username u --password p
expect_reject "computer name with slash" --computer-name 'bad/name' --username u --password p
expect_reject "unknown family" --computer-name OK-PC --username u --password p --family amiga
expect_reject "malformed product key" --computer-name OK-PC --username u --password p --product-key not-a-key
expect_reject "bad app spec" --computer-name OK-PC --username u --password p --app nosuchseparator
expect_reject "missing computer name" --username u --password p
expect_reject "missing username" --computer-name OK-PC --password p
expect_reject "unknown flag" --computer-name OK-PC --username u --password p --bogus

#--- dry-run: redacted, nothing written ----------------------------------------------
echo "== dry-run =="
DRYOUT="$("$SH" --computer-name BRANDON-PC --username brandon --password 'hunter2-secret' \
    --dry-run --out "$T/dry.json" 2>/dev/null)"
echo "$DRYOUT" | grep -q '"password": "\*\*\*REDACTED\*\*\*"' \
    && pass "dry-run prints redacted password" || fail "dry-run prints redacted password"
echo "$DRYOUT" | grep -q "hunter2-secret" && fail "dry-run never leaks the real password" \
    || pass "dry-run never leaks the real password"
[[ -f "$T/dry.json" ]] && fail "dry-run writes nothing" || pass "dry-run writes nothing"

#--- piped stdin refused --------------------------------------------------------------
echo "== piped stdin =="
if echo "hunter2" | "$SH" --computer-name OK-PC --username u --out "$T/pipe.json" >/dev/null 2>&1; then
    fail "piped stdin password refused (exited 0)"
else
    pass "piped stdin password refused"
fi
[[ -f "$T/pipe.json" ]] && fail "no file on piped refusal" || pass "no file on piped refusal"

#--- git-tree guard -------------------------------------------------------------------
echo "== git-tree guard =="
GITDIR="$T/fakerepo"; mkdir -p "$GITDIR" && git -C "$GITDIR" init -q 2>/dev/null
if "$SH" --computer-name OK-PC --username u --password p --out "$GITDIR/phoenix-config.json" >/dev/null 2>&1; then
    fail "git-tree write refused (exited 0)"
else
    pass "git-tree write refused without --force"
fi
[[ -f "$GITDIR/phoenix-config.json" ]] && fail "no file on guard refusal" || pass "no file on guard refusal"
"$SH" --computer-name OK-PC --username u --password p --force \
    --out "$GITDIR/phoenix-config.json" >/dev/null 2>&1 \
    && pass "--force writes a test fixture" || fail "--force writes a test fixture"

#--- summary ---------------------------------------------------------------------------
echo "== summary =="
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    echo "FAILED:"
    printf '  - %s\n' "${FAILED_CASES[@]}"
    exit 1
fi
echo "ALL GREEN"
