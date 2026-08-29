#!/usr/bin/env bash
# Unit tests for lib/cascade.sh -- the per-tick cascade fairness gate (igor#441).
#
# The regression this guards: on 2026-07-27 a 2.5-hour window produced ZERO
# ceo/seo/sports/maintenance lines. No tick reached them, because the stages
# above consumed every one. Reordering would only move the starvation, so a
# stage that goes unreached for CASCADE_STARVE_TICKS jumps the queue once.
#
# Mostly pure-function tests against JSON text -- no state file, no tick. The
# last section lifts cascade_run out of bin/tick.sh and drives it with stubs,
# since the dispatch and the rescued-stage skip live there.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-cascade: jq absent -- skipping"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/cascade.sh
. "$HERE/lib/cascade.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

STAGES="review maintenance seo shipreport sports feedback logwatch deferred"

echo "== tick counter =="
eq "empty state -> tick 0" "0" "$(cascade_tick_number '{}')"
S=$(cascade_bump_tick '{}')
eq "bump from empty -> 1" "1" "$(cascade_tick_number "$S")"
S=$(cascade_bump_tick "$S"); S=$(cascade_bump_tick "$S")
eq "bump is monotonic -> 3" "3" "$(cascade_tick_number "$S")"
eq "bump preserves unrelated keys" "keepme" \
  "$(cascade_bump_tick '{"weekly":{"x":"keepme"}}' | jq -r '.weekly.x')"

echo "== a missing or empty state argument means an empty document =="
# cascade_state_file_read returns "" -- not "{}" -- when the state file exists
# but is zero-length or whitespace, so every function has to survive it. The
# original ${1:-\{\}} default fed jq a literal backslash-brace and only looked
# safe because each caller had a fallback behind it.
eq "no argument -> tick 0" "0" "$(cascade_tick_number)"
eq "empty argument -> tick 0" "0" "$(cascade_tick_number '')"
eq "no argument bumps to a real document" "1" "$(cascade_bump_tick | jq -r '.cascade.tick')"
eq "empty argument bumps to a real document" "1" "$(cascade_bump_tick '' | jq -r '.cascade.tick')"
eq "empty argument marks a real document" "7" \
  "$(cascade_mark_reached '' feedback 7 | jq -r '.cascade.reached.feedback')"
eq "empty argument starves nothing at tick 1" "" "$(cascade_starved_stage '' "$STAGES" 1)"
eq "empty argument, stage age is the tick number" "9" "$(cascade_stage_age '' feedback 9)"

echo "== nothing starves on a fresh state =="
# Every stage reads as reached-at-0, so with the counter still low nothing is
# past the threshold. A fresh state file must not declare the whole cascade
# starved on tick 1.
eq "fresh state, tick 1 -> no starved stage" "" \
  "$(cascade_starved_stage '{}' "$STAGES" 1)"
eq "fresh state, tick == threshold -> still none" "" \
  "$(cascade_starved_stage '{}' "$STAGES" "$CASCADE_STARVE_TICKS")"

echo "== a stage that goes unreached eventually jumps the queue =="
# feedback last reached at tick 5; by tick 5+threshold+1 it is starved.
ST=$(cascade_mark_reached '{}' feedback 5)
for s in review maintenance seo shipreport sports logwatch deferred; do
  ST=$(cascade_mark_reached "$ST" "$s" 100)
done
eq "feedback starved at tick 100" "feedback" "$(cascade_starved_stage "$ST" "$STAGES" 100)"
eq "and the age is reported" "95" "$(cascade_stage_age "$ST" feedback 100)"
# One tick after being reached it is no longer starved -- the rescue is one-shot.
ST2=$(cascade_mark_reached "$ST" feedback 100)
eq "once reached, feedback is no longer starved" "" "$(cascade_starved_stage "$ST2" "$STAGES" 100)"

echo "== the MOST starved wins, ties break toward cascade order =="
M=$(cascade_mark_reached '{}' feedback 90)
M=$(cascade_mark_reached "$M" seo 50)
for s in review maintenance shipreport sports logwatch deferred; do
  M=$(cascade_mark_reached "$M" "$s" 100)
done
eq "seo (age 50) beats feedback (age 10)" "seo" "$(cascade_starved_stage "$M" "$STAGES" 100)"
T=$(cascade_mark_reached '{}' seo 40)
T=$(cascade_mark_reached "$T" feedback 40)
for s in review maintenance shipreport sports logwatch deferred; do
  T=$(cascade_mark_reached "$T" "$s" 100)
done
eq "equal ages -> the earlier stage in cascade order" "seo" "$(cascade_starved_stage "$T" "$STAGES" 100)"

echo "== threshold is respected, not hardcoded into the caller =="
B=$(cascade_mark_reached '{}' feedback 95)
for s in review maintenance seo shipreport sports logwatch deferred; do
  B=$(cascade_mark_reached "$B" "$s" 100)
done
eq "age 5 under the default threshold -> not starved" "" "$(cascade_starved_stage "$B" "$STAGES" 100)"
eq "same state with threshold 3 -> starved" "feedback" "$(cascade_starved_stage "$B" "$STAGES" 100 3)"
eq "the shipped threshold is 20" "20" "$CASCADE_STARVE_TICKS"

echo "== malformed state degrades to 'nothing starved', never to a crash =="
eq "garbage state -> empty, no crash" "" "$(cascade_starved_stage 'not json' "$STAGES" 100 2>/dev/null)"
eq "non-numeric reached value is treated as never-reached" "widget" \
  "$(cascade_starved_stage '{"cascade":{"reached":{"widget":"banana"}}}' "widget" 100)"

echo "== cascade_run dispatches, and a rescued stage does not run twice =="
# cascade_run lives in bin/tick.sh (it needs the state file and log), so lift
# the function out and drive it with stubs -- the dispatch and the skip are the
# risky part, and neither is reachable from the pure functions above.
CASCADE_RUN_SRC=$(sed -n '/^cascade_run() {$/,/^}$/p' "$HERE/bin/tick.sh")
if [ -z "$CASCADE_RUN_SRC" ]; then
  bad "could not extract cascade_run() from bin/tick.sh"
else
  eval "$CASCADE_RUN_SRC"
  # Both globals are read by the eval'd cascade_run, which shellcheck can't see.
  # shellcheck disable=SC2034
  CASCADE_TICK=1
  MARKED=""; RAN=""
  cascade_mark_reached_file() { MARKED="$MARKED $1"; }
  do_alpha_tick() { RAN="$RAN alpha"; return 1; }   # reached, did no work
  do_beta_tick()  { RAN="$RAN beta";  return 0; }   # reached, did work

  CASCADE_RESCUED=""
  cascade_run alpha
  eq "a stage that does no work returns non-zero" "1" "$?"
  cascade_run beta
  eq "a stage that works returns zero" "0" "$?"
  eq "both stages ran" " alpha beta" "$RAN"
  eq "both were stamped as reached" " alpha beta" "$MARKED"

  # The blocking case: the rescue at the top of the cascade ran alpha, alpha
  # returned non-zero, so the cascade falls through to alpha's normal gate.
  MARKED=""; RAN=""
  # shellcheck disable=SC2034
  CASCADE_RESCUED="alpha"
  cascade_run alpha
  eq "the rescued stage's normal gate returns non-zero" "1" "$?"
  eq "and it is NOT invoked a second time" "" "$RAN"
  eq "and it is not re-stamped" "" "$MARKED"
  cascade_run beta
  eq "other stages are unaffected by the rescue" " beta" "$RAN"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-cascade: all checks passed"
else
  echo "test-cascade: $FAIL FAILED"
  exit 1
fi
