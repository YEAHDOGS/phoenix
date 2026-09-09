#!/usr/bin/env bash
#===============================================================================
# tests/verify-runbook.sh -- machine-check docs/EMERGENCY-RUNBOOK.md against the repo.
#
# Docs drift from code; a stale runbook is a hazard. This verifier asserts:
#   (A) every script/config path the runbook references actually exists, and
#   (B) every pre-wipe guard the runbook promises is present in the real tool code
#       (image-proof gate, source_serial binding, typed confirmations, boot-USB
#        and mounted-disk refusals, TTY-only, duplicate-serial refusal,
#        method-per-media, explicit enumeration, audit logging), and
#   (C) the runbook names the arming chain, the verifier itself, and all phases.
#
# It checks promises against CODE -- it never runs anything destructive.
# Run it from a clean machine before building the Phoenix USB or touching the
# infected laptop (runbook Phase 0, Step 0.8).
#===============================================================================
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOK="$REPO/docs/EMERGENCY-RUNBOOK.md"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

[ -f "$RUNBOOK" ] || { echo "FAIL: runbook missing: $RUNBOOK"; exit 1; }

echo "== (A) referenced paths exist =="
# Normalize Windows-style backslashes the runbook sometimes uses (tools\X.ps1)
# to forward slashes, then pull repo-relative paths with known extensions.
paths="$(tr '\\' '/' < "$RUNBOOK" \
  | grep -oE '\b(tools|scripts|data|oem|docs)/[A-Za-z0-9._$/-]+\.(ps1|sh|json|xml|md)' \
  | sort -u)"
[ -n "$paths" ] || { bad "no script paths found in runbook (regex broken?)"; }
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ -e "$REPO/$p" ]; then ok "referenced path exists: $p"; else bad "runbook references missing path: $p"; fi
done <<< "$paths"

echo "== (B) pre-wipe guards present in code =="
need() { # need <file> <extended-grep-pattern> <label>
  if grep -qE "$2" "$REPO/$1"; then ok "$3"; else bad "$3"; fi
}

NUKE=tools/phoenix-nuke.sh
GUARD=tools/phoenix-nuke-guard.sh

need "$NUKE" '\-\-image-proof'            "image-proof gate flag exists in $NUKE"
need "$NUKE" 'REFUSED: --nuke requires --image-proof' \
  "nuke refuses to arm without a valid image proof"
need "$NUKE" 'source_serial'             "proof binds source_serial to the target disk"
need "$NUKE" 'NUKE WITHOUT BACKUP'       "skip-gate demands the typed 'NUKE WITHOUT BACKUP' phrase"
need "$NUKE" 'stdin is not a TTY'        "confirmation requires a real console (TTY-only, no pipes)"
need "$NUKE" 'duplicat'                  "duplicate serials are an ambiguity refusal"
need "$NUKE" 'classify_media'            "method-per-media classification (nuke picks sanitize by media)"
need "$NUKE" 'nvme'                      "NVMe firmware-sanitize path present in the nuke core"
need tools/Invoke-Nuke.sh 'REFUSED: --nuke requires --image-proof' \
  "legacy entry point keeps the same image-proof gate"
need "$GUARD" '\-\-dry-run'              "guard defaults to dry-run enumeration (nothing armed)"
need "$GUARD" 'exact'                    "guard demands the exact typed /dev path"
need "$GUARD" 'boot.*refus'              "guard refuses the boot USB structurally"
need "$GUARD" 'mounted disk'             "guard refuses any mounted disk"
need "$GUARD" 'lsblk'                    "guard enumerates disks explicitly (numbered table)"
need "$GUARD" 'audit'                    "guard writes an audit log"
need tools/phoenix-backup.sh 'proof-out' "imager mints the nuke-gate proof itself"
need tools/New-ImageProof.sh 'verified'  "proof manifest carries a verified flag"
need tools/phoenix-quarantine-copy.sh 'QUARANTINE' \
  "quarantine copy writes the QUARANTINE-INFECTED layout"
need tools/phoenix-quarantine-copy.sh 'verify=PASS' \
  "quarantine copy re-verifies every chunk on the target"

echo "== (C) runbook completeness =="
for phase in "Phase 0" "Phase 1" "Phase 2" "Phase 3" "Phase 4"; do
  if grep -q "## $phase" "$RUNBOOK"; then ok "runbook documents $phase"; else bad "runbook missing ## $phase"; fi
done
if grep -q 'tools/phoenix-nuke-guard.sh' "$RUNBOOK"; then ok "runbook names the arming guard"; else bad "runbook never names tools/phoenix-nuke-guard.sh"; fi
if grep -q 'tools/phoenix-nuke.sh' "$RUNBOOK"; then ok "runbook names the nuke core"; else bad "runbook never names tools/phoenix-nuke.sh"; fi
if grep -q 'tests/verify-runbook.sh' "$RUNBOOK"; then ok "runbook points at this verifier (Step 0.8)"; else bad "runbook never references tests/verify-runbook.sh"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
