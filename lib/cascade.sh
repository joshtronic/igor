#!/usr/bin/env bash
# cascade.sh -- fairness for the per-tick cascade (igor#441).
#
# The cascade is a run of `if do_<stage>_tick; then exit 0; fi` gates. The first
# stage that does work ends the tick, which is the point: one unit of work per
# tick. The cost is that a busy upper stage can mean a lower stage is never
# REACHED at all.
#
# Measured 2026-07-27: ZERO ceo/seo/sports/maintenance lines across a 2.5-hour
# window -- no tick got deep enough to run them, because automerge, deploy
# watching, PR review and issue work consumed every one. That is not a
# theoretical fairness concern: igor#435 had just shipped a same-tick path for
# acting on board steering, and a fast path behind a stage nothing reaches for
# hours is not fast.
#
# The fix is NOT to reorder the cascade -- that just moves the starvation to
# whatever ends up last. Instead each stage records the tick number at which it
# was last reached, and a stage that has gone CASCADE_STARVE_TICKS without being
# reached gets to run FIRST on the next tick. Normal order is untouched whenever
# nothing is starving, which is the common case.
#
# State lives in discretionary-state.json under ".cascade":
#   { "tick": <monotonic counter>, "reached": { "<stage>": <tick number> } }
#
# Pure functions here operate on JSON TEXT so they are testable without a state
# file; bin/tick.sh wraps them with the file read/write.

# How many ticks a stage may go unreached before it jumps the queue. With the
# post-#447 cadence (~15s gap, median tick ~79s) this is roughly 15-25 minutes
# of starvation -- long enough that normal contention never trips it, short
# enough that the 2.5-hour blackout above becomes impossible. Hardcoded per the
# "strong opinions, not configuration" convention.
CASCADE_STARVE_TICKS=20

# _cascade_state <state_json>
# The state argument, or an empty object when missing or empty. Not written
# inline as ${1:-{}}: the braces need escaping inside double quotes, and bash
# strips a backslash there only before $ ` " \ -- so `\{\}` reaches jq verbatim
# as an invalid document. The empty case is reachable in production, where the
# state file exists but is zero-length.
_cascade_state() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '{}'; fi
}

# cascade_tick_number <state_json>
# The current monotonic tick counter, 0 when unset.
cascade_tick_number() {
  local state; state=$(_cascade_state "${1:-}")
  jq -r '.cascade.tick // 0' <<<"$state" 2>/dev/null || echo 0
}

# cascade_bump_tick <state_json>
# Echo the state with the tick counter incremented. Called once per tick.
cascade_bump_tick() {
  local state; state=$(_cascade_state "${1:-}")
  jq -c '.cascade //= {} | .cascade.tick = ((.cascade.tick // 0) + 1)' <<<"$state" 2>/dev/null \
    || printf '%s' "$state"
}

# cascade_mark_reached <state_json> <stage> <tick_no>
# Echo the state with <stage> stamped as reached at <tick_no>.
cascade_mark_reached() {
  local state; state=$(_cascade_state "${1:-}")
  jq -c --arg s "$2" --argjson t "${3:-0}" \
    '.cascade //= {} | .cascade.reached //= {} | .cascade.reached[$s] = $t' \
    <<<"$state" 2>/dev/null || printf '%s' "$state"
}

# cascade_starved_stage <state_json> <stages> <tick_no> [threshold]
# The single most-starved stage from <stages> (whitespace separated, in cascade
# order), or empty when nothing has starved.
#
# A stage never recorded is treated as reached at tick 0, so a fresh state file
# does not declare everything starved at once on the first tick -- the counter
# has to actually climb past the threshold first.
#
# Ties break toward the EARLIER stage in the supplied order, so the cascade's
# own priority still decides between two equally-starved stages.
cascade_starved_stage() {
  local stages="$2" now="${3:-0}" thresh="${4:-$CASCADE_STARVE_TICKS}"
  local state stage last age worst_stage="" worst_age=0
  state=$(_cascade_state "${1:-}")
  # Fail CLOSED on unparseable state. Every lookup would fall back to
  # "never reached", making the whole cascade look starved at once and
  # reordering it on the strength of a corrupt file. Reordering is the
  # exceptional path; it needs positive evidence, not the absence of it.
  jq -e . >/dev/null 2>&1 <<<"$state" || return 0
  for stage in $stages; do
    last=$(jq -r --arg s "$stage" '.cascade.reached[$s] // 0' <<<"$state" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    age=$((now - last))
    if [ "$age" -gt "$thresh" ] && [ "$age" -gt "$worst_age" ]; then
      worst_age=$age
      worst_stage=$stage
    fi
  done
  printf '%s' "$worst_stage"
}

# cascade_stage_age <state_json> <stage> <tick_no>
# Ticks since <stage> was last reached -- for the log line, so a starvation
# rescue says how bad it had got rather than just that it happened.
cascade_stage_age() {
  local state last
  state=$(_cascade_state "${1:-}")
  last=$(jq -r --arg s "$2" '.cascade.reached[$s] // 0' <<<"$state" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  printf '%s' $(( ${3:-0} - last ))
}
