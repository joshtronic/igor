#!/usr/bin/env bash
# Unit tests for lib/cascade.sh -- the per-tick cascade fairness gate (igor#441).
#
# The regression this guards: on 2026-07-27 a 2.5-hour window produced ZERO
# ceo/seo/sports/maintenance lines. No tick reached them, because the stages
# above consumed every one. Reordering would only move the starvation, so a
# stage that goes unreached for CASCADE_STARVE_TICKS jumps the queue once.
#
# Pure-function tests against JSON text -- no state file, no tick.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-cascade: jq absent -- skipping"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/cascade.sh
. "$HERE/lib/cascade.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

STAGES="review maintenance seo shipreport sports ceo feedback logwatch deferred"

echo "== tick counter =="
eq "empty state -> tick 0" "0" "$(cascade_tick_number '{}')"
S=$(cascade_bump_tick '{}')
eq "bump from empty -> 1" "1" "$(cascade_tick_number "$S")"
S=$(cascade_bump_tick "$S"); S=$(cascade_bump_tick "$S")
eq "bump is monotonic -> 3" "3" "$(cascade_tick_number "$S")"
eq "bump preserves unrelated keys" "keepme" \
  "$(cascade_bump_tick '{"weekly":{"x":"keepme"}}' | jq -r '.weekly.x')"

echo "== nothing starves on a fresh state =="
# Every stage reads as reached-at-0, so with the counter still low nothing is
# past the threshold. A fresh state file must not declare the whole cascade
# starved on tick 1.
eq "fresh state, tick 1 -> no starved stage" "" \
  "$(cascade_starved_stage '{}' "$STAGES" 1)"
eq "fresh state, tick == threshold -> still none" "" \
  "$(cascade_starved_stage '{}' "$STAGES" "$CASCADE_STARVE_TICKS")"

echo "== a stage that goes unreached eventually jumps the queue =="
# ceo last reached at tick 5; by tick 5+threshold+1 it is starved.
ST=$(cascade_mark_reached '{}' ceo 5)
for s in review maintenance seo shipreport sports feedback logwatch deferred; do
  ST=$(cascade_mark_reached "$ST" "$s" 100)
done
eq "ceo starved at tick 100" "ceo" "$(cascade_starved_stage "$ST" "$STAGES" 100)"
eq "and the age is reported" "95" "$(cascade_stage_age "$ST" ceo 100)"
# One tick after being reached it is no longer starved -- the rescue is one-shot.
ST2=$(cascade_mark_reached "$ST" ceo 100)
eq "once reached, ceo is no longer starved" "" "$(cascade_starved_stage "$ST2" "$STAGES" 100)"

echo "== the MOST starved wins, ties break toward cascade order =="
M=$(cascade_mark_reached '{}' ceo 90)
M=$(cascade_mark_reached "$M" seo 50)
for s in review maintenance shipreport sports feedback logwatch deferred; do
  M=$(cascade_mark_reached "$M" "$s" 100)
done
eq "seo (age 50) beats ceo (age 10)" "seo" "$(cascade_starved_stage "$M" "$STAGES" 100)"
T=$(cascade_mark_reached '{}' seo 40)
T=$(cascade_mark_reached "$T" ceo 40)
for s in review maintenance shipreport sports feedback logwatch deferred; do
  T=$(cascade_mark_reached "$T" "$s" 100)
done
eq "equal ages -> the earlier stage in cascade order" "seo" "$(cascade_starved_stage "$T" "$STAGES" 100)"

echo "== threshold is respected, not hardcoded into the caller =="
B=$(cascade_mark_reached '{}' ceo 95)
for s in review maintenance seo shipreport sports feedback logwatch deferred; do
  B=$(cascade_mark_reached "$B" "$s" 100)
done
eq "age 5 under the default threshold -> not starved" "" "$(cascade_starved_stage "$B" "$STAGES" 100)"
eq "same state with threshold 3 -> starved" "ceo" "$(cascade_starved_stage "$B" "$STAGES" 100 3)"
eq "the shipped threshold is 20" "20" "$CASCADE_STARVE_TICKS"

echo "== malformed state degrades to 'nothing starved', never to a crash =="
eq "garbage state -> empty, no crash" "" "$(cascade_starved_stage 'not json' "$STAGES" 100 2>/dev/null)"
eq "non-numeric reached value is treated as never-reached" "ceo" \
  "$(cascade_starved_stage '{"cascade":{"reached":{"ceo":"banana"}}}' "ceo" 100)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-cascade: all checks passed"
else
  echo "test-cascade: $FAIL FAILED"
  exit 1
fi
