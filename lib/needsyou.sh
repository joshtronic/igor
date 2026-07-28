#!/usr/bin/env bash
# needsyou.sh -- what is waiting on the OPERATOR right now (igor#439).
#
# The operator's stated biggest problem is not knowing when he is the blocker.
# Today that is only discoverable by asking, or by opening Forgejo and reading.
#
# This half is DETECTION only: build the set of items waiting on the human, and
# work out what is NEW since the last look. Delivery (email) is deliberately a
# separate change -- the first attempt at this issue tried both at once and hit
# the 400-line scope cap at 792 lines.
#
# EVENT-DRIVEN, not periodic. An hourly digest that usually says "nothing needs
# you" trains the reader to stop opening it, and then it fails exactly when it
# matters. The arrival of a notification IS the signal, so only ADDITIONS to the
# set are worth announcing; removals are silent, and an unchanged set says
# nothing at all.
#
# State lives in discretionary-state.json under ".needsyou": a map of
# key -> { repo, kind, number, why, since }. `since` is the epoch when the item
# FIRST entered the set, so a later report can say how long it has been waiting
# without needing a second store.
#
# Pure functions operate on JSON TEXT so they are testable without a state file
# or a single API call; the scan that builds the live set lives in bin/tick.sh.

# needsyou_key <repo> <kind> <number>
# Stable identity for one waiting item. Kind is in the key because an issue and
# a PR can share a number in Forgejo's numbering.
needsyou_key() {
  printf '%s/%s/%s' "${1:-}" "${2:-}" "${3:-}"
}

# needsyou_item <repo> <kind> <number> <why> <since_epoch>
# One item as a compact JSON object, ready to be folded into a set.
needsyou_item() {
  jq -cn --arg r "${1:-}" --arg k "${2:-}" --arg n "${3:-}" --arg w "${4:-}" \
    --argjson s "${5:-0}" \
    '{repo:$r, kind:$k, number:$n, why:$w, since:$s}' 2>/dev/null || printf '{}'
}

# needsyou_merge <previous_set_json> <current_set_json> <now_epoch>
# The set to persist: every key currently waiting, carrying the `since` it had
# in the previous set if it was already there, or <now_epoch> if it is new.
#
# Preserving `since` across scans is the whole reason this is a merge rather
# than a replace -- otherwise every scan resets the clock and nothing can ever
# be reported as "waiting three days".
needsyou_merge() {
  local prev="${1:-\{\}}" cur="${2:-\{\}}" now="${3:-0}"
  jq -cn --argjson p "$(_needsyou_obj "$prev")" --argjson c "$(_needsyou_obj "$cur")" \
    --argjson now "$now" '
      $c | with_entries(
        .value.since = ( ($p[.key].since // $now) )
      )' 2>/dev/null || printf '{}'
}

# needsyou_added <previous_set_json> <current_set_json>
# Keys present now and absent before, newline separated, sorted. These are the
# only things worth announcing.
needsyou_added() {
  jq -rn --argjson p "$(_needsyou_obj "${1:-}")" --argjson c "$(_needsyou_obj "${2:-}")" \
    '($c | keys) - ($p | keys) | sort | .[]' 2>/dev/null || true
}

# needsyou_removed <previous_set_json> <current_set_json>
# Keys that have left the set -- the operator dealt with them. Never announced;
# available so a caller can log that the queue drained.
needsyou_removed() {
  jq -rn --argjson p "$(_needsyou_obj "${1:-}")" --argjson c "$(_needsyou_obj "${2:-}")" \
    '($p | keys) - ($c | keys) | sort | .[]' 2>/dev/null || true
}

# needsyou_describe <set_json> <key> <now_epoch>
# One human line for an item: what it is, why it is waiting, and how long.
# Shared by the log line here and by delivery later, so both phrase it the same.
needsyou_describe() {
  local set_json key="$2" now="${3:-0}"
  set_json=$(_needsyou_obj "${1:-}")
  jq -rn --argjson s "$set_json" --arg k "$key" --argjson now "$now" '
    ($s[$k] // empty) as $i
    | if $i == null then empty
      else
        (($now - ($i.since // $now)) / 60 | floor) as $mins
        | ( if $mins < 60 then "\($mins)m"
            elif $mins < 1440 then "\(($mins/60)|floor)h"
            else "\(($mins/1440)|floor)d" end ) as $age
        | "\($i.repo)#\($i.number) (\($i.kind)) -- \($i.why) [waiting \($age)]"
      end' 2>/dev/null || true
}

# _needsyou_obj <json>
# The argument as a JSON object, or {} when empty or unparseable. Written as a
# helper rather than inline `${1:-{}}` because braces need escaping inside
# double quotes and bash strips a backslash there only before $ ` " \ -- so
# `\{\}` would reach jq verbatim as an invalid document (the igor#441 lesson).
_needsyou_obj() {
  local v="${1:-}"
  [ -n "$v" ] || { printf '{}'; return 0; }
  jq -ce . >/dev/null 2>&1 <<<"$v" || { printf '{}'; return 0; }
  printf '%s' "$v"
}
