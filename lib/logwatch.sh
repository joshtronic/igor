#!/usr/bin/env bash
# lib/logwatch.sh -- pure helper for the hourly logwatch pass
# (bin/tick.sh do_logwatch_tick). Split out from tick.sh only so it's
# unit-testable in isolation; the rest of the pass (journal reads, the
# review-tier model call, ticket filing) stays in tick.sh.
#
# Source order: no dependencies beyond jq.

# logwatch_health_backoff_in_window <state_file> <win_start_epoch> <win_end_epoch>
# 0 (true) when the CURRENT Claude health record (lib/claude.sh's
# .health: first_failure/cooldown_until/kind) shows an auth/limit
# backoff that overlapped [win_start_epoch, win_end_epoch) -- the
# clock hour do_logwatch_tick is about to review. Deliberately reads
# claude_health_blocked-style raw state rather than that function
# itself: claude_health_blocked answers "is a backoff live right now",
# but logwatch reviews the hour that already closed, by which the
# backoff may have lifted.
#
# Known MVP gap: a successful call after the cooldown lapses resets
# first_failure/cooldown_until to 0 (claude_health_record_ok), which
# erases the overlap this checks for. Accepted for now -- the common
# case (a cooldown still live, or just-lapsed with no successful call
# yet) is caught; recovering the erased-history case is a follow-up.
logwatch_health_backoff_in_window() {
  local state_file="$1" win_start_epoch="$2" win_end_epoch="$3"
  local kind first_failure cooldown_until
  [ -f "$state_file" ] || return 1
  kind=$(jq -r '.health.kind // ""' "$state_file" 2>/dev/null)
  case "$kind" in
    auth|limit) ;;
    *) return 1 ;;
  esac
  first_failure=$(jq -r '.health.first_failure // 0' "$state_file" 2>/dev/null)
  cooldown_until=$(jq -r '.health.cooldown_until // 0' "$state_file" 2>/dev/null)
  [ "$first_failure" -gt 0 ] || return 1
  [ "$first_failure" -lt "$win_end_epoch" ] && [ "$cooldown_until" -gt "$win_start_epoch" ]
}

# -- Chronic escalation (igor#340) --------------------------------
#
# The MVP (igor#334) suppresses every logwatch pass whose hour
# overlapped a Claude health backoff -- correct for a one-off blip
# (the once-daily health email already owns it) but wrong for a
# backoff that keeps recurring: a persistent ticket surfaces that
# better than an email that re-fires once a day and is easy to miss.
# Distinct-day tracking lives here, in logwatch's OWN state
# (".logwatch.backoff_days" in discretionary-state.json), not in
# lib/claude.sh's ".health" -- a successful call resets .health's
# first_failure/cooldown_until (claude_health_record_ok), which would
# erase any history kept there. Logwatch's own log survives recoveries.
#
# Day granularity is the reviewed-HOUR's calendar day, not the
# failure's own start time: a single cooldown straddling midnight (the
# longest, the auth kind, is 60 minutes) can count as 2 "distinct"
# days after just one incident. Accepted -- the false-chronic window is
# at most an hour, and the alternative (tracking exact failure
# timestamps here too) duplicates what lib/claude.sh already tracks
# and then loses on recovery, the exact problem this section exists to
# avoid.

LOGWATCH_CHRONIC_BACKOFF_DAYS=2
LOGWATCH_BACKOFF_DAYS_CAP=30

# logwatch_record_backoff_day <state_file> <day (YYYY-MM-DD)>
# Add <day> to the distinct set of days a backoff overlapped a
# reviewed hour. Deduped and capped so a long-lived chronic condition
# can't grow the array unboundedly.
logwatch_record_backoff_day() {
  local state_file="$1" day="$2" tmp
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$day" --argjson cap "$LOGWATCH_BACKOFF_DAYS_CAP" \
    '.logwatch.backoff_days = (((.logwatch.backoff_days // []) + [$d]) | unique | .[-$cap:])' \
    "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file" || rm -f "$tmp"
}

# logwatch_chronic_backoff <state_file>
# 0 (true) once a backoff has overlapped a reviewed hour on
# LOGWATCH_CHRONIC_BACKOFF_DAYS or more DISTINCT calendar days --
# chronic, not noise.
logwatch_chronic_backoff() {
  local state_file="$1" count
  [ -f "$state_file" ] || return 1
  count=$(jq -r '(.logwatch.backoff_days // []) | length' "$state_file" 2>/dev/null || echo 0)
  [ "${count:-0}" -ge "$LOGWATCH_CHRONIC_BACKOFF_DAYS" ]
}

# logwatch_strip_backoff_noise <journal>
# Remove only the lines that ARE the backoff's own narration --
# health's alert-emailed line, tick.sh's "backoff active" skip-gate
# line, and logwatch's own downstream review-call failures/unparseable
# responses caused by the same backoff -- so a genuine unrelated
# failure elsewhere in the same window still stands out and files
# instead of the whole pass going dark. Only meant to be called for a
# TRANSIENT (non-chronic) backoff; once chronic, the caller skips this
# so the recurring pattern stays visible to the reviewer.
logwatch_strip_backoff_noise() {
  local journal="$1"
  grep -vE 'claude health: backoff active \(kind=|health: (auth|limit) alert emailed|logwatch: [^:]+: (review call failed|no parseable review)' \
    <<<"$journal"
}
