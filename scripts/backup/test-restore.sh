#!/bin/bash
# Phoenix selective restore regression check.
#  Builds a fixture "old home", runs backup-selective.sh --execute, then
#  exercises restore-selective.sh plan/apply: integrity verification, the
#  safety interlocks, per-app profile filtering, kill-list defense, and
#  config revalidation on restore.
#
# Usage: scripts/backup/test-restore.sh
# The PowerShell twin is verified by symmetry review (no pwsh on this box).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP="$REPO/scripts/backup/backup-selective.sh"
RESTORE="$REPO/scripts/backup/restore-selective.sh"
PROFILES="$REPO/profiles"
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# run restore and capture output; exit code is intentionally swallowed so
# pipefail can't mask grep matches on expected refusal messages
rout() { "$@" 2>&1 || true; }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
OLD="$FIX/oldhome"; NEW="$FIX/newhome"
mkdir -p "$OLD/.config/google-chrome/Default" "$OLD/Documents/Ableton/Projects" \
         "$OLD/.config/Code/User" "$NEW"

echo '{"roots":{}}' > "$OLD/.config/google-chrome/Default/Bookmarks"   # chrome data
echo '{"ok":true}' > "$OLD/.config/google-chrome/Default/Preferences"  # chrome config
echo "my song" > "$OLD/Documents/Ableton/Projects/track.txt"           # ableton data
echo '{"theme":"dark"}' > "$OLD/.config/Code/User/settings.json"       # vscode config (*.json -> validated)

echo "== 1. backup the fixture =="
PHOENIX_HOME="$OLD" "$BACKUP" --execute --dest "$FIX/dest" >/dev/null
[ -f "$FIX/dest/manifest.json" ] && [ -f "$FIX/dest/manifest-meta.json" ] \
    && pass "backup produced manifest + meta" || fail "backup produced manifest + meta"

echo "== 2. plan mode is read-only and green =="
PLAN="$(PHOENIX_HOME="$NEW" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW" --plan --allow-same-disk)"
echo "$PLAN" | grep -q "RESTORE" && pass "plan lists restorable files" || fail "plan lists restorable files"
echo "$PLAN" | grep -q "match manifest hashes" && pass "plan verifies backup hashes" || fail "plan verifies backup hashes"
[ -z "$(ls -A "$NEW")" ] && pass "plan wrote nothing to target" || fail "plan wrote nothing to target"

echo "== 3. apply restores files with verified hashes =="
PHOENIX_HOME="$NEW" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW" --apply --confirm-word RESTORE --allow-same-disk >/dev/null
[ -f "$NEW/.config/google-chrome/Default/Bookmarks" ] && pass "chrome data restored" || fail "chrome data restored"
[ -f "$NEW/.config/google-chrome/Default/Preferences" ] && pass "chrome config restored" || fail "chrome config restored"
[ -f "$NEW/Documents/Ableton/Projects/track.txt" ] && pass "ableton data restored" || fail "ableton data restored"
[ "$(cat "$NEW/Documents/Ableton/Projects/track.txt")" = "my song" ] && pass "restored content intact" || fail "restored content intact"

echo "== 4. hash mismatch in backup refuses =="
cp -r "$FIX/dest" "$FIX/dest-bad"
echo "tampered" >> "$FIX/dest-bad/chrome/.config/google-chrome/Default/Bookmarks"
if rout env PHOENIX_HOME="$NEW" "$RESTORE" --manifest-dir "$FIX/dest-bad" --target-root "$NEW" --plan --allow-same-disk | grep -q "INTEGRITY FAILURE"; then
    pass "tampered backup refused in plan mode"
else
    fail "tampered backup refused in plan mode"
fi

echo "== 5. interlock: target == source disk refused =="
if rout env PHOENIX_HOME="$OLD" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$OLD" --plan | grep -q "INTERLOCK"; then
    pass "target==source refused"
else
    fail "target==source refused"
fi

echo "== 5b. interlock: same-disk target refused without override =="
if rout env PHOENIX_HOME="$NEW" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW" --plan | grep -q "INTERLOCK.*SOURCE"; then
    pass "same-disk target refused by default"
else
    fail "same-disk target refused by default"
fi

echo "== 6. interlock: target inside backup dir refused =="
mkdir -p "$FIX/dest/sub"
if rout "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$FIX/dest/sub" --plan | grep -q "INTERLOCK"; then
    pass "target-inside-backup refused"
else
    fail "target-inside-backup refused"
fi

echo "== 7. interlock: missing --target-root =="
if rout "$RESTORE" --manifest-dir "$FIX/dest" --plan | grep -q "required"; then
    pass "target-root required"
else
    fail "target-root required"
fi

echo "== 8. profile filter: --app chrome restores only chrome =="
NEW2="$FIX/newhome2"; mkdir -p "$NEW2"
PHOENIX_HOME="$NEW2" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW2" --app chrome --apply --confirm-word RESTORE --allow-same-disk >/dev/null
[ -f "$NEW2/.config/google-chrome/Default/Bookmarks" ] && pass "chrome restored with filter" || fail "chrome restored with filter"
[ ! -e "$NEW2/Documents/Ableton" ] && pass "ableton NOT restored with --app chrome" || fail "ableton NOT restored with --app chrome"

echo "== 9. kill-list defense: cache entry smuggled into manifest is never restored =="
cp -r "$FIX/dest" "$FIX/dest-evil"
mkdir -p "$FIX/dest-evil/chrome/.config/google-chrome/Default"
echo "stolen-cookies" > "$FIX/dest-evil/chrome/.config/google-chrome/Default/Cookies"
h="$(sha256sum "$FIX/dest-evil/chrome/.config/google-chrome/Default/Cookies" | cut -d' ' -f1)"
jq --arg h "$h" '. + [{app:"chrome", file:"chrome/.config/google-chrome/Default/Cookies", sha256:$h}]' \
    "$FIX/dest-evil/manifest.json" > "$FIX/dest-evil/manifest.json.new" \
    && mv "$FIX/dest-evil/manifest.json.new" "$FIX/dest-evil/manifest.json"
EVIL_PLAN="$(PHOENIX_HOME="$NEW2" "$RESTORE" --manifest-dir "$FIX/dest-evil" --target-root "$NEW2" --plan --allow-same-disk)"
echo "$EVIL_PLAN" | grep "Cookies" | grep -q "SKIP (kill-list" \
    && pass "smuggled cache entry marked kill-list SKIP" || fail "smuggled cache entry marked kill-list SKIP"
PHOENIX_HOME="$NEW2" "$RESTORE" --manifest-dir "$FIX/dest-evil" --target-root "$NEW2" --apply --confirm-word RESTORE --allow-same-disk >/dev/null
[ ! -e "$NEW2/.config/google-chrome/Default/Cookies" ] \
    && pass "smuggled cache entry NOT written on apply" || fail "smuggled cache entry NOT written on apply"

echo "== 10. config revalidation: corrupt config is quarantined, not reapplied =="
cp -r "$FIX/dest" "$FIX/dest-rot"
echo 'NOT JSON{{{' > "$FIX/dest-rot/vscode/.config/Code/User/settings.json"
h2="$(sha256sum "$FIX/dest-rot/vscode/.config/Code/User/settings.json" | cut -d' ' -f1)"
jq --arg h "$h2" 'map(if (.file | contains("settings.json")) then .sha256=$h else . end)' \
    "$FIX/dest-rot/manifest.json" > "$FIX/dest-rot/manifest.json.new" \
    && mv "$FIX/dest-rot/manifest.json.new" "$FIX/dest-rot/manifest.json"
NEW3="$FIX/newhome3"; mkdir -p "$NEW3"
OUT="$(rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest-rot" --target-root "$NEW3" --apply --confirm-word RESTORE --allow-same-disk)"
echo "$OUT" | grep -q "QUARANTINED" && pass "corrupt config quarantined on restore" || fail "corrupt config quarantined on restore"
[ ! -e "$NEW3/.config/Code/User/settings.json" ] \
    && pass "corrupt config NOT written to target" || fail "corrupt config NOT written to target"
[ -f "$NEW3/.config/google-chrome/Default/Bookmarks" ] \
    && pass "good files still restored alongside quarantine" || fail "good files still restored alongside quarantine"

echo "== 11. missing meta degrades gracefully =="
cp -r "$FIX/dest" "$FIX/dest-nometa"; rm "$FIX/dest-nometa/manifest-meta.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest-nometa" --target-root "$NEW3" --plan --allow-same-disk | grep -q "DEGRADED"; then
    pass "missing meta warns but plans"
else
    fail "missing meta warns but plans"
fi

echo "== 12. typed confirmation gate =="
if printf 'nope\n' | rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --apply --allow-same-disk | grep -q "aborted"; then
    pass "wrong confirmation word aborts"
else
    fail "wrong confirmation word aborts"
fi

echo "== 13. --config: stick policy gate =="
cat > "$FIX/cfg-restore.json" <<'JSONEOF'
{"schema_version": 1,
 "boot_entries": {"analyze": true, "backup": true, "nuke": false, "reinstall": false},
 "backup_target": {"kind": "direct-usb"},
 "unattend": {"answer_file": "/autounattend.xml"},
 "safety": {"require_image_proof": true, "allow_skip_image_gate": false, "abort_countdown_seconds": 5},
 "target_disks": []}
JSONEOF
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --config "$FIX/cfg-restore.json" | grep -q "stick policy"; then
    pass "backup-enabled stick policy accepted"
else
    fail "backup-enabled stick policy accepted"
fi
jq '.boot_entries.backup = false' "$FIX/cfg-restore.json" > "$FIX/cfg-restore-off.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --config "$FIX/cfg-restore-off.json" | grep -q "disables the BACKUP lane"; then
    pass "backup-disabled stick refused"
else
    fail "backup-disabled stick refused"
fi
echo 'not json' > "$FIX/cfg-restore-bad.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --config "$FIX/cfg-restore-bad.json" | grep -q "invalid phoenix-config.json"; then
    pass "invalid config refused"
else
    fail "invalid config refused"
fi

echo "== 14. --chain: chain-of-custody ordering gate =="
CHAIN="$FIX/chain"; mkdir -p "$CHAIN"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --chain "$CHAIN" | grep -q "no backup-image-proof.json"; then
    pass "chain without backup proof refused"
else
    fail "chain without backup proof refused"
fi
echo '{"schema": "phoenix-image-proof/1", "serial": "X", "verified": true}' > "$CHAIN/backup-image-proof.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --chain "$CHAIN" | grep -q "no nuke-completed.json"; then
    pass "chain without nuke record refused"
else
    fail "chain without nuke record refused"
fi
echo '{"schema": "phoenix-nuke-completion/1", "serial": "X", "completed_at": "2026-09-10T00:00:00Z"}' > "$CHAIN/nuke-completed.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --chain "$CHAIN" | grep -q "chain of custody"; then
    pass "full chain records accepted"
else
    fail "full chain records accepted"
fi
echo '{"schema": "phoenix-image-proof/1", "serial": "X", "verified": false}' > "$CHAIN/backup-image-proof.json"
if rout env PHOENIX_HOME="$NEW3" "$RESTORE" --manifest-dir "$FIX/dest" --target-root "$NEW3" --plan --allow-same-disk --chain "$CHAIN" | grep -q "not verified"; then
    pass "unverified backup proof refused by chain gate"
else
    fail "unverified backup proof refused by chain gate"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
