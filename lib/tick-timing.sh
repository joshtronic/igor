#!/usr/bin/env bash
# lib/tick-timing.sh -- per-tick wall-clock duration ledger.
#
# Append-only JSONL, one line per tick.sh invocation (recorded from
# cleanup(), so every exit path is covered -- success, no-work, and
# error alike). Answers "is the 1-minute cadence actually being kept,
# and is that changing" (igor#612) -- the same aggregate-visibility
# charter as lib/cost.sh, just for time instead of money.
#
# Schema (one JSON object per line):
#   {
#     "timestamp": "2026-09-12T00:01:18Z",  // tick end time
#     "tick_pid": "83810",
#     "duration_s": int,
#     "rc": int                             // the tick's own exit code
#   }

: "${AGENT_STATE_DIR:?AGENT_STATE_DIR must be set before sourcing lib/tick-timing.sh}"

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

TICK_TIMING_LEDGER_PATH="$AGENT_STATE_DIR/tick-timing.jsonl"

# Retention: ~1440 lines/day at the 1-minute cadence, forever, and every ship
# report full-scans the file with jq. 20k lines is about two weeks -- far more
# than the 48h the report reads, and small enough that the scan stays free.
TICK_TIMING_MAX_LINES="${TICK_TIMING_MAX_LINES:-20000}"

# Trim to the newest TICK_TIMING_MAX_LINES, but only once the file is a tenth
# OVER the cap: trimming on every append past it would rewrite the whole file
# every minute to drop one line. Same best-effort discipline as the write --
# a failed trim leaves the ledger intact and oversized, which is fine.
_tick_timing_trim() {
  local n tmp
  n=$(wc -l < "$TICK_TIMING_LEDGER_PATH" 2>/dev/null | tr -d ' ') || return 0
  [ -n "$n" ] || return 0
  [ "$n" -gt $(( TICK_TIMING_MAX_LINES + TICK_TIMING_MAX_LINES / 10 )) ] || return 0
  tmp="$TICK_TIMING_LEDGER_PATH.trim.$$"
  if tail -n "$TICK_TIMING_MAX_LINES" "$TICK_TIMING_LEDGER_PATH" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$TICK_TIMING_LEDGER_PATH" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# tick_timing_record <duration_s> <rc> -- append one line. Best-effort,
# same discipline as _cost_write_line: bookkeeping must never break a
# tick, so a write failure is swallowed (nothing else to do about it,
# and cleanup() is not a place to introduce a new failure mode).
tick_timing_record() {
  local duration="$1" rc="$2"
  mkdir -p "$(dirname "$TICK_TIMING_LEDGER_PATH")"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pid "${TICK_PID:-$$}" \
    --argjson duration "$duration" \
    --argjson rc "$rc" \
    '{timestamp: $ts, tick_pid: $pid, duration_s: $duration, rc: $rc}' \
    >> "$TICK_TIMING_LEDGER_PATH" 2>/dev/null || true
  _tick_timing_trim
}

# tick_timing_summary <since_iso> <until_iso> -- count/median/p90/max tick
# duration over [since, until). has_data distinguishes "checked, ticks were
# fast" from "no ticks recorded" -- the same stale-vs-zero distinction
# cost_ledger_summary makes, and for the same reason (igor#612).
#
# `fromjson? | objects` mirrors cost_ledger_summary: `inputs` feeds one
# expression, so `.timestamp` raising on a valid-JSON non-object line would
# render a day of real ticks as "no tick-timing data recorded".
tick_timing_summary() {
  local since="$1" until_="$2"
  if [ ! -f "$TICK_TIMING_LEDGER_PATH" ]; then
    printf '{"count":0,"has_data":false,"median_s":null,"p90_s":null,"max_s":null}'
    return 0
  fi
  jq -cnR --arg since "$since" --arg until "$until_" '
    def percentile(p):
      sort as $s
      | ($s | length) as $n
      | if $n == 0 then null
        else
          (($n - 1) * p) as $idx
          | ($idx | floor) as $lo
          | ($idx | ceil) as $hi
          | if $lo == $hi then $s[$lo]
            else $s[$lo] + ($s[$hi] - $s[$lo]) * ($idx - $lo)
            end
        end;
    [inputs | fromjson? | objects | select(.timestamp >= $since and .timestamp < $until) | .duration_s] as $durs
    | {
        count: ($durs | length),
        has_data: ($durs | length > 0),
        median_s: ($durs | percentile(0.5)),
        p90_s: ($durs | percentile(0.9)),
        max_s: (if ($durs | length) == 0 then null else ($durs | max) end)
      }
  ' "$TICK_TIMING_LEDGER_PATH" 2>/dev/null \
    || printf '{"count":0,"has_data":false,"median_s":null,"p90_s":null,"max_s":null}'
}
