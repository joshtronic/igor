#!/usr/bin/env bash
# emailwatch.sh -- pure helpers for the daily email liveness check
# (bin/tick.sh do_emailwatch_tick, igor#636).
#
# Every safeguard on the daily-email path (shipreport's #633 retry/cooldown,
# sports' failure cap) asks "did the call fail?" Nothing asked "did the
# thing happen?" -- on 2026-09-14 the ship report died at exec time with
# E2BIG, the failure was stamped .shipreport.sent=true anyway, and the only
# trace was a `warning:` line a human happened to notice.
#
# This module answers "did the thing happen?" for exactly that class of
# surface: a daily job that stamps discretionary-state.json under
# `.<surface> = {date, sent, ...}` once it believes it's done for the day.
# Two things it deliberately does NOT trust on their own:
#
#   1. The stamp. It's written by the code being checked, so a stamp that
#      lies (E2BIG case) looks identical to one that's telling the truth.
#   2. Silence. A day+sent-shaped key with no OWN success-log pattern
#      registered anywhere must still surface as something to look at --
#      see do_emailwatch_tick's EMAILWATCH_RETIRED_SURFACES for the one
#      surface (.market) that got read this way and turned out to already
#      be dead, and stays skipped deliberately rather than silently.
#
# So the cross-check is an independent signal: the sender's own SUCCESS log
# line, which by construction is written only from inside the success
# branch (never the stamp, never a generic "ran" line). emailwatch_verdict
# is the pure decision over (stamp, window day, journal, success patterns);
# do_emailwatch_tick in bin/tick.sh owns the journalctl read, the per-surface
# pattern registry, and filing the Forgejo alarm -- kept out of this file so
# the decision itself is testable with plain strings, no journal, no network.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# Defers to bin/tick.sh's own definition when sourced there, so enumeration
# and do_emailwatch_tick's parseability guard can never read different files;
# the literal is the standalone-test fallback, same pattern as log above.
_emailwatch_state_file() {
  if declare -F discretionary_state_file >/dev/null; then
    discretionary_state_file
  else
    printf '%s/discretionary-state.json' "${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
  fi
}

# emailwatch_window_day -- the day under review: yesterday, whole and closed.
# Same discipline as logwatch_window_day -- a partial day can't be judged
# "the email never went out" while there's still time left for it to.
# Portable (GNU then BSD date, matching the rest of tick.sh).
emailwatch_window_day() {
  date -d '-1 days' +%F 2>/dev/null || date -v-1d +%F
}

# emailwatch_done_today -- true once today's pass has already reviewed
# emailwatch_window_day. Mirrors logwatch_done_today exactly (day-stamp
# holds the WINDOW reviewed, not the run date).
emailwatch_done_today() {
  local sf; sf=$(_emailwatch_state_file)
  [ -f "$sf" ] || return 1
  [ "$(jq -r '.emailwatch.day // ""' "$sf" 2>/dev/null)" = "$(emailwatch_window_day)" ]
}

# emailwatch_mark_done -- stamp the window day as reviewed. Called BEFORE
# any alarm is filed (slot semantics, like logwatch_mark_done) so a crash
# mid-pass doesn't retry-storm the rest of the day; merges rather than
# replaces so a sibling key under the same state file survives.
emailwatch_mark_done() {
  local sf tmp day
  sf=$(_emailwatch_state_file); day=$(emailwatch_window_day)
  [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg d "$day" '.emailwatch = ((.emailwatch // {}) + {day: $d})' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
    log "emailwatch: could not stamp done -- $sf unparseable?"
  fi
}

# emailwatch_surfaces -- every top-level discretionary-state.json key
# shaped like a daily-email stamp (an object carrying BOTH `date` and
# `sent`), one per line, sorted. Dynamic on purpose: a new daily sender
# that starts stamping the same shape shows up here with no code change,
# so do_emailwatch_tick's registry-vs-unregistered split (bin/tick.sh) is
# what has to be taught about it, not this enumeration. Empty (not a
# crash) when the state file is missing or unparseable.
emailwatch_surfaces() {
  local sf; sf=$(_emailwatch_state_file)
  [ -f "$sf" ] || return 0
  jq -r '
    to_entries[]
    | select(.value | type == "object")
    | select((.value | has("date")) and (.value | has("sent")))
    | .key
  ' "$sf" 2>/dev/null | sort -u
}

# emailwatch_surface_date <surface> -- that surface's stamped `.date`, or
# empty if absent/missing entirely.
emailwatch_surface_date() {
  local sf surface; sf=$(_emailwatch_state_file); surface="$1"
  [ -f "$sf" ] || return 0
  jq -r --arg s "$surface" '.[$s].date // ""' "$sf" 2>/dev/null
}

# emailwatch_surface_sent <surface> -- "true"/"false", defaulting to
# "false" for a surface with no stamp at all (never claimed to have sent).
emailwatch_surface_sent() {
  local sf surface; sf=$(_emailwatch_state_file); surface="$1"
  [ -f "$sf" ] || { echo false; return 0; }
  jq -r --arg s "$surface" '(.[$s].sent // false) | tostring' "$sf" 2>/dev/null
}

# emailwatch_verdict <sent> <stamp_date> <window_day> <journal> <pattern...>
# Pure decision, no IO. Three outcomes, printed to stdout:
#
#   not-run     the stamp doesn't cover the window day at all -- either it
#               was never written (removed, or a surface that's never
#               attempted), it's stale/frozen from an earlier day (an
#               opted-out surface whose date just never advances again --
#               see .market), or it covers the window day but sent is
#               still false (attempted, never completed: abandoned after
#               the failure cap, or a gate blocked it all day).
#   no-evidence the stamp claims sent=true for the window day, but nothing
#               in <journal> matches ANY <pattern> -- the 2026-09-14 case
#               exactly: a lying stamp.
#   ok          the stamp claims sent=true for the window day AND at least
#               one <pattern> is found in <journal> -- an independent
#               signal backs the stamp.
#
# Deliberately takes >= 2 patterns from callers in practice: a sender's
# success path covers BOTH "sent an email" and "genuinely nothing to
# report today" (both call *_mark_sent), and only the stamp can't tell
# those apart from a silent failure -- the journal line can.
emailwatch_verdict() {
  local sent="$1" stamp_date="$2" window_day="$3" journal="$4"
  shift 4
  if [ "$stamp_date" != "$window_day" ] || [ "$sent" != "true" ]; then
    echo "not-run"
    return 0
  fi
  local pat
  for pat in "$@"; do
    if grep -qE "$pat" <<<"$journal"; then
      echo "ok"
      return 0
    fi
  done
  echo "no-evidence"
}
