#!/usr/bin/env bash
# test-forgejo-screenshots.sh -- unit tests for the PR screenshot-attach helpers
# in lib/forgejo.sh (forgejo_attach_image / forgejo_attach_pr_screenshots).
# Covers the guard + no-op paths that never touch the network: oversized skip,
# missing file, absent/empty dir. Skip-safe, like the other bin/test-*.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# lib/forgejo.sh hard-requires these at source time (no network call here).
export FORGEJO_URL="https://example.invalid"
export FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
rc() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected rc %s got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== forgejo_attach_image guards (no upload) =="
forgejo_attach_image repo/x 1 "$TMP/nope.png" >/dev/null 2>&1
rc "missing file -> rc 1" 1 "$?"

printf '01234567890123456789' > "$TMP/big.png"   # 20 bytes
FORGEJO_ATTACH_MAX_BYTES=10 forgejo_attach_image repo/x 1 "$TMP/big.png" >/dev/null 2>&1
rc "oversized file -> rc 1 (skipped)" 1 "$?"

echo "== forgejo_attach_pr_screenshots no-op =="
eq "absent dir -> echoes 0" 0 "$(forgejo_attach_pr_screenshots repo/x 1 "$TMP/missing")"
mkdir -p "$TMP/empty"
eq "empty dir -> echoes 0" 0 "$(forgejo_attach_pr_screenshots repo/x 1 "$TMP/empty")"

if [ "$FAIL" -eq 0 ]; then echo "test-forgejo-screenshots: all checks passed"; exit 0; fi
echo "test-forgejo-screenshots: $FAIL check(s) FAILED"
exit 1
