#!/usr/bin/env bash
#===============================================================================
# test-phoenix-data-restore.sh -- regression suite for tools/New-PhoenixDataRestore.ps1
# (Phoenix REINSTALL phase, runbook Step 4.5: selective restore on the fresh install).
#
# pwsh is not available on the test host, so this suite tests the contract in two
# ways (same pattern as tests/tools/test-app-install-twin.sh):
#   A) fixture-driven: build a REAL backup with tools/phoenix-data-backup.sh,
#      then run a python3 reference port of the restore's selection/verification
#      rules against that fixture and diff the expected restored/refused sets;
#      the extension/system-profile lists are extracted from the .ps1 source so
#      the reference stays honest about what the real tool refuses.
#   B) static contract: assert the .ps1 carries every hard guarantee --
#      manifest format + verify=PASS binding (quarantine images have no
#      data-backup manifest), hash re-verification BEFORE any copy, executable
#      refusal, UNC/network-target refusal, fixed-drive check, Defender scan
#      gate, and the restore manifest schema.
#
# All fixtures live in a temp dir -- NEVER the repo. Nothing here is destructive.
#
# Usage: bash tests/tools/test-phoenix-data-restore.sh   (exit 0 = all green)
#===============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RESTORE="$REPO/tools/New-PhoenixDataRestore.ps1"
BACKUP_SH="$REPO/tools/phoenix-data-backup.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ -- $2}"; }

T="$(mktemp -d /tmp/phoenix-restore-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

echo "== preflight =="
[[ -f "$RESTORE" ]] || { echo "FATAL: $RESTORE not found"; exit 1; }
[[ -x "$BACKUP_SH" ]] || chmod +x "$BACKUP_SH"
pass "tools/New-PhoenixDataRestore.ps1 exists"

echo "== A1: fixture -- build a REAL backup with tools/phoenix-data-backup.sh =="
SRC="$T/fake-source"; OUT="$T/laptop-data"
mkdir -p "$SRC/Users/brandon/Documents" "$SRC/Users/brandon/Downloads" "$SRC/Users/brandon/Desktop"
echo "my manuscript" > "$SRC/Users/brandon/Documents/novel.txt"
echo "photo bytes"  > "$SRC/Users/brandon/Desktop/photo.png"
echo "game save"    > "$SRC/Users/brandon/Documents/save.dat"
printf 'MZfakeexe'  > "$SRC/Users/brandon/Downloads/setup.exe"
printf 'MZfakemsi'  > "$SRC/Users/brandon/Downloads/app.msi"
echo "legit script I wrote" > "$SRC/Users/brandon/Documents/notes.ps1"
echo "music" > "$SRC/Users/brandon/Documents/song.mp3"
# --include-exe: the backup DOES contain executables, so the RESTORE tool's own
# executable refusal is what must catch them (defense in depth -- the restore
# never copies executables even when the backup kept them).
"$BACKUP_SH" --source-dir "$SRC" --out "$OUT" --profiles brandon --operator testop \
    --include-exe >/dev/null 2>&1 \
    && pass "fixture backup created with the real backup tool" \
    || { fail "fixture backup created with the real backup tool"; exit 1; }
for f in data-backup.manifest files.sha256 DIRTY-NOT-FORENSIC-SAFE.txt skipped-executables.txt; do
    [[ -f "$OUT/$f" ]] && pass "fixture backup carries $f" || fail "fixture backup carries $f"
done
grep -qx 'format=phoenix-data-backup/1' "$OUT/data-backup.manifest" && pass "fixture manifest format=phoenix-data-backup/1" || fail "fixture manifest format"
grep -qx 'verify=PASS' "$OUT/data-backup.manifest" && pass "fixture manifest verify=PASS" || fail "fixture manifest verify=PASS"

echo "== A2: reference port -- restore selection/refusal rules vs the real fixture =="
REFPY="$T/ref.py"
cat > "$REFPY" <<'PYEOF'
import sys, re, hashlib, os
ps1_path, fixture = sys.argv[1], sys.argv[2]
src = open(ps1_path, encoding="utf-8-sig").read()
m = re.search(r"\$ExeExts = @\((.*?)\)", src, re.S)
exe_exts = set(x.strip(" '\"\t\r\n").lower() for x in m.group(1).split(",") if x.strip())
m2 = re.search(r"\$SystemProfiles = @\((.*?)\)", src, re.S)
sys_profiles = set(x.strip(" '\"\t\r\n") for x in m2.group(1).split(",") if x.strip())
# manifest profile line, mirroring the ps1's selection rule
manifest = {}
for line in open(os.path.join(fixture, "data-backup.manifest"), encoding="ascii"):
    if "=" in line and not line.startswith("#"):
        k, v = line.rstrip("\n").split("=", 1); manifest[k] = v
backup_profiles = [p for p in manifest["profiles"].split(",") if p and p not in sys_profiles]
def is_exe(rel):
    root, dot, ext = rel.rpartition(".")
    return dot != "" and ("." + ext.lower()) in exe_exts
restored, refused = [], []
for line in open(os.path.join(fixture, "files.sha256"), encoding="ascii"):
    mm = re.match(r"^([0-9a-f]{64})  (.+)$", line.rstrip("\n"))
    h, rel = mm.group(1), mm.group(2)
    parts = rel.split("/")
    if parts[0] == "Users" and (len(parts) < 3 or parts[1] not in backup_profiles):
        continue
    disk = os.path.join(fixture, *rel.split("/"))
    real = hashlib.sha256(open(disk, "rb").read()).hexdigest()
    if real != h:
        print("TAMPER", rel); continue
    (refused if is_exe(rel) else restored).append(rel)
print("RESTORED")
for r in sorted(restored): print(r)
print("REFUSED")
for r in sorted(refused): print(r)
PYEOF
python3 "$REFPY" "$RESTORE" "$OUT" > "$T/ref.out"
RESTORED="$(awk '/^RESTORED$/{f=1;next}/^REFUSED$/{f=0}f' "$T/ref.out")"
REFUSED="$(awk '/^REFUSED$/{f=1;next}f' "$T/ref.out")"
echo "$RESTORED" | grep -qx 'Users/brandon/Documents/novel.txt' && pass "ref: novel.txt would be restored" || fail "ref: novel.txt"
echo "$RESTORED" | grep -qx 'Users/brandon/Desktop/photo.png'   && pass "ref: photo.png would be restored"  || fail "ref: photo.png"
echo "$RESTORED" | grep -qx 'Users/brandon/Documents/save.dat'  && pass "ref: save.dat would be restored"   || fail "ref: save.dat"
echo "$RESTORED" | grep -qx 'Users/brandon/Documents/song.mp3'  && pass "ref: song.mp3 would be restored"   || fail "ref: song.mp3"
echo "$REFUSED"  | grep -qx 'Users/brandon/Downloads/setup.exe' && pass "ref: setup.exe refused even though backup skipped it" || fail "ref: setup.exe"
echo "$REFUSED"  | grep -qx 'Users/brandon/Downloads/app.msi'   && pass "ref: app.msi refused"              || fail "ref: app.msi"
echo "$REFUSED"  | grep -qx 'Users/brandon/Documents/notes.ps1' && pass "ref: notes.ps1 refused (.ps1 is executable)" || fail "ref: notes.ps1"
echo "$RESTORED" | grep -c . | grep -qx 4 && echo "$REFUSED" | grep -c . | grep -qx 3 \
    && pass "ref: exactly 4 files restored, 3 refused" \
    || fail "ref: counts" "restored=$(echo "$RESTORED"|grep -c .), refused=$(echo "$REFUSED"|grep -c .)"
python3 - "$RESTORE" <<'PYEOF'
import sys, re
src = open(sys.argv[1], encoding="utf-8-sig").read()
exts = set(x.strip(" '\"\t\r\n").lower() for x in
           re.search(r"\$ExeExts = @\((.*?)\)", src, re.S).group(1).split(",") if x.strip())
needed = {".exe",".msi",".dll",".sys",".scr",".com",".cpl",".bat",".cmd",
          ".ps1",".vbs",".vbe",".jse",".wsf",".wsh",".hta",".pif",".lnk"}
missing = needed - exts
assert not missing, "extension gaps: %s" % sorted(missing)
print("  PASS: .ps1 refusal list covers all 18 executable extensions")
PYEOF
[[ $? -eq 0 ]] || FAIL=$((FAIL+1))

echo "== A3: tamper detection -- corrupted backup file must abort the restore =="
cp -r "$OUT" "$T/tampered"
echo "evil bytes" >> "$T/tampered/Users/brandon/Documents/novel.txt"
python3 "$REFPY" "$RESTORE" "$T/tampered" > "$T/tamper.out"
grep -qx 'TAMPER Users/brandon/Documents/novel.txt' "$T/tamper.out" \
    && pass "ref: tampered file detected by hash re-verification" \
    || fail "ref: tampered file detected"

echo "== B: static contract of tools/New-PhoenixDataRestore.ps1 =="
has() { # has <grep-E pattern> <label>
    if grep -qE "$1" "$RESTORE"; then pass "$2"; else fail "$2"; fi
}
has "phoenix-data-backup/1"      "manifest binding: accepts only phoenix-data-backup/1"
has "verify.*-ne.*'PASS'"         "manifest binding: refuses verify != PASS"
has "contamination.*-ne.*'DIRTY'" "manifest binding: refuses non-DIRTY contamination"
has "Get-FileHash.*SHA256"        "re-verifies every file with Get-FileHash SHA256"
has "hash MISMATCH"               "hash mismatch aborts the entire restore"
has "quarantined full-disk image" "documents that quarantine images are structurally un-restorable"
has "DriveType.*-ne.*'Fixed'"     "TargetRoot must be a local fixed drive"
has "\^\\\\\\\\"                  "UNC/network TargetRoot refused"
has "overlap"                     "TargetRoot/BackupDir overlap refused"
has "MpCmdRun"                    "Defender scan-before-restore gate present"
has "SkipAvCheck"                 "scan gate has an explicit opt-out switch"
has "phoenix-data-restore/1"      "restore manifest carries format=phoenix-data-restore/1"
has "executables_refused"         "restore manifest audits executables_refused"
has "refused-executables.txt"     "refused executables are written to an audit file"
has "data-restore.log"            "restore writes an audit log"
has "ShouldProcess"               "supports -WhatIf (SupportsShouldProcess)"
has "escapes TargetRoot"          "destination confined inside TargetRoot (no '..' escapes)"
has "operator="                   "restore manifest records the operator"
# ordering: the hash-verification phase must precede any Copy-Item in the file
vline="$(grep -n "hash MISMATCH" "$RESTORE" | head -1 | cut -d: -f1)"
cline="$(grep -n "Copy-Item" "$RESTORE" | head -1 | cut -d: -f1)"
if [[ "$vline" -lt "$cline" ]]; then pass "hash re-verification phase precedes all Copy-Item calls"; else fail "hash re-verification precedes copy"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
