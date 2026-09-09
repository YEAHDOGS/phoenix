#!/usr/bin/env bash
# =============================================================================
# get-iso.sh — Bash twin of qemu/get-iso.ps1 (Phoenix / Castle infra)
#
# Downloads an ISO over HTTP(S) with curl, mirroring the PowerShell original:
#   * Duplicate check: skip entirely if the output file already exists
#   * Streams to disk with a live progress display (curl's progress bar plays
#     the role of the .ps1's ~50MB inline terminal ticks)
#   * On any failure the partial file is deleted (no corrupt leftovers)
#
# Optional SHA-512 verification (the inventory mapping for this script):
#   get-iso.sh [url] [outfile] [expected_sha512]
# or via env: ISO_URL, OUT_FILE, SHA512SUM_EXPECTED.
# If an expected SHA-512 is supplied and the digest mismatches, the file is
# deleted and the script exits non-zero.
# =============================================================================
set -uo pipefail

ISO_URL="${1:-${ISO_URL:-https://mirror.cachyos.org/ISO/desktop/240609/cachyos-desktop-linux-all-240609.iso}}"
OUT_FILE="${2:-${OUT_FILE:-cachyos-server-latest.iso}}"
EXPECTED_SHA512="${3:-${SHA512SUM_EXPECTED:-}}"

echo "[Castle] Destination target: $OUT_FILE"

# Duplicate check: don't burn bandwidth if it's already on the block
if [ -f "$OUT_FILE" ]; then
    echo "[Castle] ISO asset already exists locally: $OUT_FILE (skipping download)"
    exit 0
fi

echo "[Castle] Establishing stream pipeline to: $ISO_URL"

TMP_FILE="${OUT_FILE}.part"
rm -f "$TMP_FILE"

if ! curl -fSL --retry 2 -# -o "$TMP_FILE" "$ISO_URL"; then
    echo "[Castle] FATAL: download pipeline failed" >&2
    rm -f "$TMP_FILE"
    exit 1
fi

mv "$TMP_FILE" "$OUT_FILE"
echo "[Castle] ISO asset deployment successful."

if [ -n "$EXPECTED_SHA512" ]; then
    echo "[Castle] Verifying SHA-512 digest..."
    ACTUAL="$(sha512sum < "$OUT_FILE" | cut -d' ' -f1 | tr 'A-F' 'a-f')"
    WANT="$(printf '%s' "$EXPECTED_SHA512" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
    if [ "$ACTUAL" != "$WANT" ]; then
        echo "[Castle] FATAL: SHA-512 mismatch — deleting corrupt file." >&2
        echo "  expected: $WANT" >&2
        echo "  actual:   $ACTUAL" >&2
        rm -f "$OUT_FILE"
        exit 1
    fi
    echo "[Castle] SHA-512 digest verified."
fi
