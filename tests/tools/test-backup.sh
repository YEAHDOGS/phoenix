#!/usr/bin/env bash
# test-backup.sh -- regression suite for the Phoenix BACKUP phase.
# Covers: backup_require_source (target selection), backup_require_destination
# (exists / free space / not-on-source-disk), the typed-confirmation wiring,
# the mocked imaging flow (manifest + sha256 + proof), and the image-proof
# gate the nuke phase consumes.
# Run from the repo root:  bash tests/tools/test-backup.sh
# Exit 0 = all pass; exit 1 = any failure. No network, no real disks touched:
# enumeration is driven by PHOENIX_MOCK_LSBLK, imaging by PHOENIX_MOCK_DD=1,
# df answers by PHOENIX_MOCK_DF_AVAIL / PHOENIX_MOCK_DF_DEVICE.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENUM="$REPO_ROOT/tools/Get-DiskInventory.sh"
LIB="$REPO_ROOT/tools/lib/backup-gates.sh"
FLOW="$REPO_ROOT/tools/Backup-DiskImage.sh"
FIX="$REPO_ROOT/tests/tools/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fixture inventory (committed): id1=nvme WDCA9876543210 2TB,
# id2=sda Samsung S5YBNJ0R123456A 931.5GiB, id3=sdb serial-less USB (mocked mounted)
INV="$TMP/inv.json"
PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="sdb1" \
    PHOENIX_MOCK_HASH=aaabbb "$ENUM" > "$INV"

gate() { # <fn> [args...] -> rc ; sources the lib in a subshell
    bash -c "source \"$LIB\"; $*" >/dev/null 2>&1
}

# --- 1. source-disk gate (target selection) ------------------------------------
echo "== source-disk gate =="

gate "backup_require_source \"$INV\" 2"; [[ $? -eq 0 ]] \
  && ok "valid id selects the source disk" || bad "valid id refused"

gate "backup_require_source \"$INV\" 3"; [[ $? -ne 0 ]] \
  && ok "serial-less disk refused as image source" || bad "serial-less disk ACCEPTED"

gate "backup_require_source \"$INV\" 99"; [[ $? -ne 0 ]] \
  && ok "unknown id refused" || bad "unknown id ACCEPTED"

# mounted source (mock sda1 mounted -> id2 has mounted partitions)
INV_MNT="$TMP/inv-mnt.json"
PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" PHOENIX_MOCK_MOUNTS="sda1" \
    PHOENIX_MOCK_HASH=aaabbb "$ENUM" > "$INV_MNT"
gate "backup_require_source \"$INV_MNT\" 2"; [[ $? -ne 0 ]] \
  && ok "mounted disk refused as image source" || bad "mounted disk ACCEPTED"

# --- 2. destination gate -------------------------------------------------------
echo "== destination gate =="

mkdir -p "$TMP/dest"
# id2 = /dev/sda, size 1000204886016
d_ok()   { PHOENIX_MOCK_DF_AVAIL=2000398934016 PHOENIX_MOCK_DF_DEVICE=/dev/sdb1 \
             gate "backup_require_destination \"$TMP/dest\" 1000204886016 /dev/sda"; }
d_small(){ PHOENIX_MOCK_DF_AVAIL=100 PHOENIX_MOCK_DF_DEVICE=/dev/sdb1 \
             gate "backup_require_destination \"$TMP/dest\" 1000204886016 /dev/sda"; }
d_self() { PHOENIX_MOCK_DF_AVAIL=2000398934016 PHOENIX_MOCK_DF_DEVICE=/dev/sda1 \
             gate "backup_require_destination \"$TMP/dest\" 1000204886016 /dev/sda"; }
d_selfbare(){ PHOENIX_MOCK_DF_AVAIL=2000398934016 PHOENIX_MOCK_DF_DEVICE=/dev/sda \
             gate "backup_require_destination \"$TMP/dest\" 1000204886016 /dev/sda"; }
d_nvme() { PHOENIX_MOCK_DF_AVAIL=9999999999999 PHOENIX_MOCK_DF_DEVICE=/dev/nvme0n1p2 \
             gate "backup_require_destination \"$TMP/dest\" 2000398934016 /dev/nvme0n1"; }
d_diff() { PHOENIX_MOCK_DF_AVAIL=9999999999999 PHOENIX_MOCK_DF_DEVICE=/dev/nvme0n1p1 \
             gate "backup_require_destination \"$TMP/dest\" 1000204886016 /dev/sda"; }

d_ok;    [[ $? -eq 0 ]] && ok "roomy other-disk destination accepted" || bad "valid destination refused"
d_small; [[ $? -ne 0 ]] && ok "insufficient free space refused" || bad "tiny destination ACCEPTED"
d_self;  [[ $? -ne 0 ]] && ok "destination on the source disk refused" || bad "self-destination ACCEPTED (danger)"
d_selfbare; [[ $? -ne 0 ]] && ok "destination on source disk (whole-disk form) refused" || bad "bare self-destination ACCEPTED"
d_nvme;  [[ $? -ne 0 ]] && ok "nvme partition-on-source refused" || bad "nvme self-destination ACCEPTED"
d_diff;  [[ $? -eq 0 ]] && ok "destination on a different disk accepted" || bad "other-disk destination refused"

gate "backup_require_destination \"$TMP/does-not-exist\" 100 /dev/sda"; [[ $? -ne 0 ]] \
  && ok "missing destination dir refused" || bad "missing destination ACCEPTED"
touch "$TMP/afile"
gate "backup_require_destination \"$TMP/afile\" 100 /dev/sda"; [[ $? -ne 0 ]] \
  && ok "non-directory destination refused" || bad "file destination ACCEPTED"

# --- 3. imaging flow (mocked dd) ----------------------------------------------
echo "== imaging + manifest + proof (mocked dd) =="

export PHOENIX_MOCK_DD=1
IMGSTATE="$TMP/imgstate"; mkdir -p "$IMGSTATE"
bash -c "
  source \"$LIB\"
  backup_require_source \"$INV\" 2
  backup_image_disk \"\$BACKUP_DEV\" \"$TMP/dest\" testlabel \"$IMGSTATE\"
" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "mocked imaging completes" || bad "mocked imaging failed"

IMG="$TMP/dest/testlabel.img"
[[ -f "$IMG" ]] && ok "image file written" || bad "image file missing"
[[ -f "$IMG.sha256" ]] && ok "sha256 sidecar written" || bad "sha256 sidecar missing"
[[ -f "$IMGSTATE/testlabel-manifest.json" ]] && ok "manifest written" || bad "manifest missing"
[[ -f "$IMGSTATE/backup-image-proof.json" ]] && ok "image proof written" || bad "proof missing"

recorded="$(cut -d' ' -f1 "$IMG.sha256")"
actual="$(sha256sum "$IMG" | cut -d' ' -f1)"
[[ "$recorded" == "$actual" ]] && ok "sha256 sidecar matches image bytes" || bad "sha256 sidecar WRONG"

mserial="$(python3 -c 'import json; print(json.load(open("'"$IMGSTATE/testlabel-manifest.json"'"))["source"]["serial"])')"
[[ "$mserial" == "S5YBNJ0R123456A" ]] && ok "manifest binds the source serial" || bad "manifest serial: $mserial"
vflag="$(python3 -c 'import json; print(json.load(open("'"$IMGSTATE/testlabel-manifest.json"'"))["verified"])')"
[[ "$vflag" == "True" ]] && ok "manifest marked verified" || bad "manifest not marked verified"

# refuse to overwrite an existing image
bash -c "source \"$LIB\"; backup_image_disk /dev/sda \"$TMP/dest\" testlabel \"$IMGSTATE\"" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "existing image never overwritten" || bad "overwrite of existing image ACCEPTED"
unset PHOENIX_MOCK_DD

# --- 4. image-proof gate --------------------------------------------------------
echo "== image-proof gate (nuke side consumes this) =="

gate "backup_require_image_proof \"$IMGSTATE\" S5YBNJ0R123456A"; [[ $? -eq 0 ]] \
  && ok "valid proof passes the image-proof gate" || bad "valid proof refused"

gate "backup_require_image_proof \"$IMGSTATE\" WDCA9876543210"; [[ $? -ne 0 ]] \
  && ok "proof for a different serial refused" || bad "wrong-serial proof ACCEPTED"

mkdir -p "$TMP/noproof"
gate "backup_require_image_proof \"$TMP/noproof\" S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "missing proof refused (image first, wipe later)" || bad "missing proof ACCEPTED"

# tampered: image deleted
mv "$IMG" "$IMG.bak"
gate "backup_require_image_proof \"$IMGSTATE\" S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "proof with deleted image refused" || bad "deleted-image proof ACCEPTED"
mv "$IMG.bak" "$IMG"

# tampered: sha256 sidecar no longer matches proof
echo "deadbeef  testlabel.img" > "$IMG.sha256"
gate "backup_require_image_proof \"$IMGSTATE\" S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "proof with mismatched sidecar refused" || bad "mismatched-sidecar proof ACCEPTED"
printf '%s  testlabel.img\n' "$actual" > "$IMG.sha256"

# tampered: verified flag cleared
python3 - "$IMGSTATE/backup-image-proof.json" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1])); p["verified"] = False
json.dump(p, open(sys.argv[1], "w"), indent=2)
EOF
gate "backup_require_image_proof \"$IMGSTATE\" S5YBNJ0R123456A"; [[ $? -ne 0 ]] \
  && ok "unverified proof refused" || bad "unverified proof ACCEPTED"

# --- 5. end-to-end flow wiring (mocked, pty confirmation) ------------------------
echo "== end-to-end Backup-DiskImage.sh (mocked, pty) =="

run_flow() { # <typed-answer> <dest> <state> -> rc
    local answer="$1" dest="$2" state="$3"
    mkdir -p "$dest" "$state"
    printf '%s\n' "$answer" | PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" \
      PHOENIX_MOCK_MOUNTS="sdb1" PHOENIX_MOCK_HASH=aaabbb PHOENIX_MOCK_DD=1 \
      PHOENIX_MOCK_DF_AVAIL=2000398934016 PHOENIX_MOCK_DF_DEVICE=/dev/sdb1 \
      script -qec "$FLOW --dest \"$dest\" --state \"$state\" 2" /dev/null >/dev/null 2>&1
}

E2E_DEST="$TMP/e2e-dest"; E2E_STATE="$TMP/e2e-state"
run_flow "S5YBNJ0R123456A Samsung SSD 870 EVO 1TB" "$E2E_DEST" "$E2E_STATE"
[[ $? -eq 0 && -f "$E2E_STATE/backup-image-proof.json" ]] \
  && ok "full flow with correct typed pair produces a verified proof" \
  || bad "full flow with correct pair failed"

E2E_DEST2="$TMP/e2e-dest2"; E2E_STATE2="$TMP/e2e-state2"
run_flow "WRONGSERIAL Samsung SSD 870 EVO 1TB" "$E2E_DEST2" "$E2E_STATE2"
[[ $? -ne 0 && ! -f "$E2E_STATE2/backup-image-proof.json" ]] \
  && ok "full flow with wrong serial aborts before imaging" \
  || bad "full flow with wrong serial PROCEEDED (danger)"

# piped stdin (no pty) must be refused even with the correct answer
printf 'S5YBNJ0R123456A Samsung SSD 870 EVO 1TB\n' | PHOENIX_MOCK_LSBLK="$FIX/mock-lsblk.txt" \
  PHOENIX_MOCK_MOUNTS="sdb1" PHOENIX_MOCK_HASH=aaabbb PHOENIX_MOCK_DD=1 \
  PHOENIX_MOCK_DF_AVAIL=2000398934016 PHOENIX_MOCK_DF_DEVICE=/dev/sdb1 \
  "$FLOW" --dest "$TMP/e2e-dest3" --state "$TMP/e2e-state3" 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "piped confirmation refused by the flow" \
  || bad "piped confirmation ACCEPTED by the flow (scripting interlock broken)"

echo "----------------------------------------"
echo "RESULT: $pass PASS / $fail FAIL"
[[ $fail -eq 0 ]]
