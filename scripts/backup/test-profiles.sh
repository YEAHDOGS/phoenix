#!/bin/bash
# Phoenix backup profile regression check.
#  1) Validates every profiles/*.json against the phoenix-profile/v1 schema.
#  2) Builds a fixture home and runs backup-selective.sh in plan mode:
#     data/config must be selected, cache/executable must be SKIPPED.
#  3) Runs --execute against the fixture: only data + valid config land in
#     the destination, manifest.json carries SHA-256 hashes, invalid config
#     JSON is quarantined (not copied).
#
# Usage: scripts/backup/test-profiles.sh
# No pwsh available on this box, so the PowerShell twin is verified by
# symmetry review; the bash twin is exercised here.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$REPO/scripts/backup/backup-selective.sh"
PROFILES="$REPO/profiles"
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== 1. schema validation =="
ids=""
for pf in "$PROFILES"/*.json; do
    name="$(basename "$pf")"
    jq empty "$pf" >/dev/null 2>&1 && pass "$name parses" || { fail "$name does not parse"; continue; }
    s="$(jq -r '.schema' "$pf")"
    [ "$s" = "phoenix-profile/v1" ] && pass "$name schema" || fail "$name schema != phoenix-profile/v1"
    app="$(jq -r '.app' "$pf")"
    [ -n "$app" ] && [ "$app" != "null" ] && pass "$name app='$app'" || { fail "$name missing app"; continue; }
    case " $ids " in *" $app "*) fail "$name duplicate app id '$app'";; *) ids="$ids $app";; esac
    bad="$(jq -r '.locations[] | select((.class|tostring|test("^(data|config|cache|executable)$")|not) or ((.notes//"")=="") or ((.windows|type)!="array") or ((.linux|type)!="array")) | "bad location"' "$pf" | head -1)"
    [ -z "$bad" ] && pass "$name locations (class enum, notes, path arrays)" || fail "$name has invalid location"
    # every profile must actually declare kill-list entries (cache + executable)
    for cls in cache executable; do
        n="$(jq "[.locations[] | select(.class==\"$cls\")] | length" "$pf")"
        [ "$n" -gt 0 ] && pass "$name has $cls kill-list" || fail "$name missing $cls kill-list"
    done
done

echo "== 2. plan-mode selection against fixture =="
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
FH="$FIX/home"
mkdir -p "$FH/.config/google-chrome/Default" "$FH/.config/google-chrome/Default/Cache" \
         "$FH/.config/google-chrome/Default/Extensions/abc" \
         "$FH/.config/Code/User/snippets" "$FH/.config/Code/User"

echo '{"roots":{}}' > "$FH/.config/google-chrome/Default/Bookmarks"     # data, valid
echo '{"ok":true}' > "$FH/.config/google-chrome/Default/Preferences"     # config, valid
echo "cookieblob" > "$FH/.config/google-chrome/Default/Cookies"          # cache -> skip
echo "binary" > "$FH/.config/google-chrome/Default/Extensions/abc/x.js" # executable -> skip
echo '{"snip":1}' > "$FH/.config/Code/User/snippets/a.json"              # data, valid
echo '{"theme":"dark"}' > "$FH/.config/Code/User/settings.json"          # config, valid

PLAN="$(PHOENIX_HOME="$FH" "$ENGINE" --app chrome --plan)"
echo "$PLAN" | grep -q "Bookmarks" && pass "plan: Bookmarks selected" || fail "plan: Bookmarks selected"
echo "$PLAN" | grep -q "VALIDATE-THEN-BACKUP.*Preferences" && pass "plan: Preferences validate-then-backup" || fail "plan: Preferences validate-then-backup"
echo "$PLAN" | grep -i "cache" | grep -q "SKIP (cache)" && pass "plan: Cache skipped" || fail "plan: Cache skipped"
echo "$PLAN" | grep "Extensions" | grep -q "SKIP (executable" && pass "plan: Extensions skipped" || fail "plan: Extensions skipped"

echo "== 3. execute-mode: copies + manifest =="
DEST="$FIX/dest"
out="$(PHOENIX_HOME="$FH" "$ENGINE" --app chrome --execute --dest "$DEST" 2>&1)"
[ -f "$DEST/manifest.json" ] && pass "manifest.json written" || fail "manifest.json written"
[ -f "$DEST/chrome/.config/google-chrome/Default/Bookmarks" ] && pass "Bookmarks copied" || fail "Bookmarks copied"
[ -f "$DEST/chrome/.config/google-chrome/Default/Preferences" ] && pass "Preferences copied" || fail "Preferences copied"
[ ! -e "$DEST/chrome/.config/google-chrome/Default/Cookies" ] && pass "Cookies NOT copied" || fail "Cookies NOT copied"
[ ! -e "$DEST/chrome/.config/google-chrome/Default/Extensions" ] && pass "Extensions NOT copied" || fail "Extensions NOT copied"
src_h="$(sha256sum "$FH/.config/google-chrome/Default/Bookmarks" | cut -d' ' -f1)"
man_h="$(jq -r '.[] | select(.file | contains("Bookmarks")) | .sha256' "$DEST/manifest.json")"
[ "$src_h" = "$man_h" ] && pass "manifest SHA-256 matches source" || fail "manifest SHA-256 matches source"
[ -f "$DEST/manifest-meta.json" ] && pass "manifest-meta.json written" || fail "manifest-meta.json written"
[ "$(jq -r '.schema' "$DEST/manifest-meta.json")" = "phoenix-backup-meta/v1" ] && pass "meta schema" || fail "meta schema"
[ "$(jq -r '.source_home' "$DEST/manifest-meta.json")" = "$FH" ] && pass "meta source_home matches fixture" || fail "meta source_home matches fixture"
jq -e '.apps | index("chrome")' "$DEST/manifest-meta.json" >/dev/null && pass "meta apps lists chrome" || fail "meta apps lists chrome"
[ -n "$(jq -r '.source_fs_id' "$DEST/manifest-meta.json")" ] && [ "$(jq -r '.source_fs_id' "$DEST/manifest-meta.json")" != "null" ] && pass "meta source_fs_id present" || fail "meta source_fs_id present"

echo "== 4. quarantine: invalid config JSON is not copied =="
echo 'NOT JSON{{{' > "$FH/.config/Code/User/settings.json"   # corrupt it
DEST2="$FIX/dest2"
out2="$(PHOENIX_HOME="$FH" "$ENGINE" --app vscode --execute --dest "$DEST2" 2>&1)"
echo "$out2" | grep -q "QUARANTINED" && pass "quarantine reported" || fail "quarantine reported"
[ ! -e "$DEST2/vscode/.config/Code/User/settings.json" ] && pass "invalid settings.json NOT copied" || fail "invalid settings.json NOT copied"
[ -f "$DEST2/vscode/.config/Code/User/snippets/a.json" ] && pass "snippets (data) still copied" || fail "snippets (data) still copied"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
