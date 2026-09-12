#!/usr/bin/env bash
# test-tick-timing.sh -- unit tests for lib/tick-timing.sh: the per-tick
# duration ledger backing the ship report's tick-timing section (igor#612).
#
# Skip-safe: needs jq; exits 0 with a notice if absent, like the other
# bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-tick-timing: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_STATE_DIR="$TMP/state"
mkdir -p "$AGENT_STATE_DIR"

log() { :; }

# shellcheck source=lib/tick-timing.sh
. "$HERE/lib/tick-timing.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

echo "== tick_timing_summary: no ledger file -> no data, not an error =="
S0=$(tick_timing_summary "2020-01-01T00:00:00Z" "2099-01-01T00:00:00Z")
eq "empty: has_data false" "false" "$(jq -r '.has_data' <<<"$S0")"
eq "empty: count zero"     "0"     "$(jq -r '.count' <<<"$S0")"
eq "empty: median null"    "null"  "$(jq -r '.median_s' <<<"$S0")"

echo "== tick_timing_record: appends one line per call =="
TICK_PID=100 tick_timing_record 8 0
TICK_PID=101 tick_timing_record 12 0
TICK_PID=102 tick_timing_record 20 0
TICK_PID=103 tick_timing_record 300 1
eq "ledger has 4 lines" "4" "$(wc -l < "$TICK_TIMING_LEDGER_PATH" | tr -d ' ')"

echo "== tick_timing_summary: count/median/p90/max over a window =="
S1=$(tick_timing_summary "2020-01-01T00:00:00Z" "2099-01-01T00:00:00Z")
eq "count"     "4"    "$(jq -r '.count' <<<"$S1")"
eq "has_data"  "true" "$(jq -r '.has_data' <<<"$S1")"
eq "median (8,12,20,300 -> 16)" "16" "$(jq -r '.median_s' <<<"$S1")"
eq "max"       "300"  "$(jq -r '.max_s' <<<"$S1")"

echo "== tick_timing_summary: window excludes out-of-range entries =="
: > "$TICK_TIMING_LEDGER_PATH"
cat >> "$TICK_TIMING_LEDGER_PATH" <<'EOF'
{"timestamp":"2026-09-11T10:00:00Z","tick_pid":"1","duration_s":10,"rc":0}
{"timestamp":"2026-09-11T11:00:00Z","tick_pid":"1","duration_s":30,"rc":0}
{"timestamp":"2026-09-10T10:00:00Z","tick_pid":"1","duration_s":999,"rc":0}
EOF
S2=$(tick_timing_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "windowed count excludes the prior day" "2"  "$(jq -r '.count' <<<"$S2")"
eq "windowed max excludes the prior day"   "30" "$(jq -r '.max_s' <<<"$S2")"

EMPTY_WINDOW=$(tick_timing_summary "2020-01-01T00:00:00Z" "2020-01-02T00:00:00Z")
eq "a window with no matching entries -> has_data false" "false" "$(jq -r '.has_data' <<<"$EMPTY_WINDOW")"

[ "$FAIL" -eq 0 ] && { echo "test-tick-timing: all checks passed"; exit 0; }
echo "test-tick-timing: $FAIL check(s) FAILED"
exit 1
