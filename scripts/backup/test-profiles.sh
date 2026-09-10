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
echo "== 5. new profiles: discord, stardew, powershell, git, terminal =="
mkdir -p "$FH/.config/discord/Local Storage/leveldb" "$FH/.config/discord/Cache" \
         "$FH/.config/StardewValley/Saves/Farm_12345" "$FH/.config/StardewValley/Mods" \
         "$FH/.config/StardewValley/ErrorLogs" \
         "$FH/.config/powershell" "$FH/.local/share/powershell/Modules/Tool" \
         "$FH/.local/share/powershell/PSReadLine" "$FH/.config/git" "$FH/.ssh"

echo '{"BACKGROUND_COLOR":"#121214"}' > "$FH/.config/discord/settings.json"          # config, valid
echo "tokenblob" > "$FH/.config/discord/Local Storage/leveldb/MANIFEST-0001"       # cache -> skip
echo "cachedata" > "$FH/.config/discord/Cache/f_000001"                            # cache -> skip
echo '<SaveGame></SaveGame>' > "$FH/.config/StardewValley/Saves/Farm_12345/Farm_12345"   # data
echo '<info/>' > "$FH/.config/StardewValley/Saves/Farm_12345/SaveGameInfo"          # data
echo '<prefs/>' > "$FH/.config/StardewValley/startup_preferences"                  # config
echo "dll" > "$FH/.config/StardewValley/Mods/Mod.dll"                              # executable -> skip
echo "error" > "$FH/.config/StardewValley/ErrorLogs/SMAPI-latest.txt"              # cache -> skip
echo 'Set-Alias g git' > "$FH/.config/powershell/profile.ps1"                     # config (non-json)
echo 'oh-my-posh' > "$FH/.config/powershell/Microsoft.PowerShell_profile.ps1"     # config (non-json)
echo "psm1" > "$FH/.local/share/powershell/Modules/Tool/x.psm1"                    # executable -> skip
echo "secret command" > "$FH/.local/share/powershell/PSReadLine/ConsoleHost_history.txt" # cache -> skip
printf '[user]\n\tname = Test\n' > "$FH/.gitconfig"                                # config
printf '[core]\n\teditor = vim\n' > "$FH/.config/git/config"                      # config
echo "PRIVATE KEY" > "$FH/.ssh/id_ed25519"                                         # cache -> skip

P="$(PHOENIX_HOME="$FH" "$ENGINE" --app discord --plan)"
echo "$P" | grep -q "VALIDATE-THEN-BACKUP.*settings.json" && pass "plan: discord settings.json validate" || fail "plan: discord settings.json validate"
echo "$P" | grep "Local Storage" | grep -q "SKIP (cache)" && pass "plan: discord Local Storage skipped" || fail "plan: discord Local Storage skipped"
echo "$P" | grep "/Cache " | grep -q "SKIP (cache)" && pass "plan: discord Cache skipped" || fail "plan: discord Cache skipped"

P="$(PHOENIX_HOME="$FH" "$ENGINE" --app stardew --plan)"
echo "$P" | grep -q "BACKUP .*Saves" && pass "plan: stardew Saves selected" || fail "plan: stardew Saves selected"
echo "$P" | grep -q "VALIDATE-THEN-BACKUP.*startup_preferences" && pass "plan: stardew prefs validate" || fail "plan: stardew prefs validate"
echo "$P" | grep "Mods" | grep -q "SKIP (executable" && pass "plan: stardew Mods skipped" || fail "plan: stardew Mods skipped"
echo "$P" | grep "ErrorLogs" | grep -q "SKIP (cache)" && pass "plan: stardew ErrorLogs skipped" || fail "plan: stardew ErrorLogs skipped"

P="$(PHOENIX_HOME="$FH" "$ENGINE" --app powershell --plan)"
echo "$P" | grep -q "VALIDATE-THEN-BACKUP.*profile.ps1" && pass "plan: ps profile.ps1 validate" || fail "plan: ps profile.ps1 validate"
echo "$P" | grep "Modules" | grep -q "SKIP (executable" && pass "plan: ps Modules skipped" || fail "plan: ps Modules skipped"
echo "$P" | grep "ConsoleHost_history" | grep -q "SKIP (cache)" && pass "plan: ps history skipped" || fail "plan: ps history skipped"

P="$(PHOENIX_HOME="$FH" "$ENGINE" --app git --plan)"
echo "$P" | grep -q "VALIDATE-THEN-BACKUP.*\.gitconfig" && pass "plan: git .gitconfig validate" || fail "plan: git .gitconfig validate"
echo "$P" | grep "git/config" | grep -q "VALIDATE-THEN-BACKUP" && pass "plan: git xdg config validate" || fail "plan: git xdg config validate"
echo "$P" | grep "\.ssh" | grep -q "SKIP (cache)" && pass "plan: git .ssh skipped" || fail "plan: git .ssh skipped"

# terminal is Windows-only (empty linux arrays): engine must handle it without error
P="$(PHOENIX_HOME="$FH" "$ENGINE" --app terminal --plan)" && pass "plan: terminal runs clean (windows-only)" || fail "plan: terminal runs clean (windows-only)"

DEST5="$FIX/dest5"
PHOENIX_HOME="$FH" "$ENGINE" --app stardew --execute --dest "$DEST5" >/dev/null 2>&1
[ -f "$DEST5/stardew/.config/StardewValley/Saves/Farm_12345/Farm_12345" ] && pass "exec: stardew save copied" || fail "exec: stardew save copied"
[ -f "$DEST5/stardew/.config/StardewValley/startup_preferences" ] && pass "exec: stardew prefs copied" || fail "exec: stardew prefs copied"
[ ! -e "$DEST5/stardew/.config/StardewValley/Mods" ] && pass "exec: stardew Mods NOT copied" || fail "exec: stardew Mods NOT copied"
[ ! -e "$DEST5/stardew/.config/StardewValley/ErrorLogs" ] && pass "exec: stardew ErrorLogs NOT copied" || fail "exec: stardew ErrorLogs NOT copied"
src_h="$(sha256sum "$FH/.config/StardewValley/Saves/Farm_12345/Farm_12345" | cut -d' ' -f1)"
man_h="$(jq -r '.[] | select(.file | contains("Farm_12345/Farm_12345")) | .sha256' "$DEST5/manifest.json")"
[ "$src_h" = "$man_h" ] && pass "exec: stardew manifest SHA-256 matches" || fail "exec: stardew manifest SHA-256 matches"

DEST6="$FIX/dest6"
PHOENIX_HOME="$FH" "$ENGINE" --app discord --execute --dest "$DEST6" >/dev/null 2>&1
[ -f "$DEST6/discord/.config/discord/settings.json" ] && pass "exec: discord settings copied" || fail "exec: discord settings copied"
[ ! -e "$DEST6/discord/.config/discord/Local Storage" ] && pass "exec: discord Local Storage NOT copied" || fail "exec: discord Local Storage NOT copied"
[ ! -e "$DEST6/discord/.config/discord/Cache" ] && pass "exec: discord Cache NOT copied" || fail "exec: discord Cache NOT copied"

DEST7="$FIX/dest7"
PHOENIX_HOME="$FH" "$ENGINE" --app git --execute --dest "$DEST7" >/dev/null 2>&1
[ -f "$DEST7/git/.gitconfig" ] && pass "exec: git .gitconfig copied" || fail "exec: git .gitconfig copied"
[ -f "$DEST7/git/.config/git/config" ] && pass "exec: git xdg config copied" || fail "exec: git xdg config copied"
[ ! -e "$DEST7/git/.ssh" ] && pass "exec: git .ssh NOT copied" || fail "exec: git .ssh NOT copied"

DEST8="$FIX/dest8"
PHOENIX_HOME="$FH" "$ENGINE" --app powershell --execute --dest "$DEST8" >/dev/null 2>&1
[ -f "$DEST8/powershell/.config/powershell/profile.ps1" ] && pass "exec: ps profile copied" || fail "exec: ps profile copied"
[ ! -e "$DEST8/powershell/.local/share/powershell/Modules" ] && pass "exec: ps Modules NOT copied" || fail "exec: ps Modules NOT copied"
[ ! -e "$DEST8/powershell/.local/share/powershell/PSReadLine" ] && pass "exec: ps history NOT copied" || fail "exec: ps history NOT copied"

DEST9="$FIX/dest9"
PHOENIX_HOME="$FH" "$ENGINE" --app terminal --execute --dest "$DEST9" >/dev/null 2>&1 && pass "exec: terminal runs clean" || fail "exec: terminal runs clean"
[ ! -e "$DEST9/terminal" ] && pass "exec: terminal copied nothing (windows-only)" || fail "exec: terminal copied nothing (windows-only)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
