#!/usr/bin/env bash
# test-logwatch.sh -- unit tests for lib/logwatch.sh:
# logwatch_health_backoff_in_window, the guard that suppresses the
# hourly logwatch pass when a Claude health backoff (auth/limit)
# overlapped the reviewed clock hour (igor#334).
#
# Skip-safe: exits 0 with a notice if jq is absent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "test-logwatch: jq not installed -- skipping"; exit 0; }

# shellcheck source=lib/logwatch.sh
. "$HERE/lib/logwatch.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (rc0 expected)"; fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (rc!=0 expected)"; else ok "$d"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/discretionary-state.json"

# A fixed "reviewed hour" window: 12:00:00 -> 13:00:00 (epoch, arbitrary).
WIN_START=1000000000
WIN_END=1000003600

write_health() {  # <kind> <first_failure> <cooldown_until>
  jq -n --arg k "$1" --argjson ff "$2" --argjson cu "$3" \
    '{health: {kind: $k, first_failure: $ff, cooldown_until: $cu}}' > "$STATE"
}

echo "== no state file =="
rm -f "$STATE"
no "missing state file -> no suppression" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== healthy (no backoff) =="
write_health "" 0 0
no "cleared health record -> no suppression" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff fully inside the reviewed window =="
write_health "auth" $((WIN_START + 60)) $((WIN_START + 120))
yes "auth backoff inside window -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "limit" $((WIN_START + 60)) $((WIN_START + 120))
yes "limit backoff inside window -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff overlapping only the edges =="
write_health "auth" $((WIN_START - 100)) $((WIN_START + 10))
yes "backoff straddling window start -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "auth" $((WIN_END - 10)) $((WIN_END + 100))
yes "backoff straddling window end -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff entirely outside the window =="
write_health "auth" $((WIN_START - 7200)) $((WIN_START - 3600))
no "backoff well before window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "auth" $((WIN_END + 3600)) $((WIN_END + 7200))
no "backoff well after window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== kind must be auth or limit =="
write_health "other" $((WIN_START + 60)) $((WIN_START + 120))
no "kind=other overlapping window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

if [ "$FAIL" -eq 0 ]; then
  echo "test-logwatch: all checks passed"
else
  echo "test-logwatch: $FAIL FAILED"
  exit 1
fi
