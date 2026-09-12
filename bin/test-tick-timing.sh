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

echo "== tick_timing_summary: a valid-JSON NON-OBJECT line doesn't blank the window =="
# `fromjson?` accepts `7` and then `.timestamp` raises on it, aborting the
# whole `[inputs | ...]` expression -- a day of real ticks would render as "no
# tick-timing data recorded". Same guard, same reason, as cost_ledger_summary.
printf '%s\n' '7' >> "$TICK_TIMING_LEDGER_PATH"
S3=$(tick_timing_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "non-object line: still has_data" "true" "$(jq -r '.has_data' <<<"$S3")"
eq "non-object line: count intact"   "2"    "$(jq -r '.count' <<<"$S3")"
eq "non-object line: max intact"     "30"   "$(jq -r '.max_s' <<<"$S3")"

echo "== tick_timing_record: the ledger is bounded, newest lines kept =="
# 1440 lines/day at the 1-minute cadence, forever, and every ship report
# full-scans it with jq. Cap of 10 with a tenth-over slack means the trim
# fires at 12 (-> 3..12) and again at 14 (-> 5..14), not on every append.
: > "$TICK_TIMING_LEDGER_PATH"
TICK_TIMING_MAX_LINES=10
for i in $(seq 1 14); do tick_timing_record "$i" 0; done
eq "trimmed to the cap"     "10" "$(wc -l < "$TICK_TIMING_LEDGER_PATH" | tr -d ' ')"
eq "keeps the newest line"  "14" "$(tail -1 "$TICK_TIMING_LEDGER_PATH" | jq -r '.duration_s')"
eq "drops the oldest lines" "5"  "$(head -1 "$TICK_TIMING_LEDGER_PATH" | jq -r '.duration_s')"

[ "$FAIL" -eq 0 ] && { echo "test-tick-timing: all checks passed"; exit 0; }
echo "test-tick-timing: $FAIL check(s) FAILED"
exit 1
