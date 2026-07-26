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
  if jq --arg d "$day" --argjson cap "$LOGWATCH_BACKOFF_DAYS_CAP" \
    '.logwatch.backoff_days = (((.logwatch.backoff_days // []) + [$d]) | unique | .[-$cap:])' \
    "$state_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
  fi
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

# -- Timer-aware silence (igor#420) -------------------------------
#
# How long before the reviewed window to look for the timer's last
# state change. A pause longer than the window leaves NO transition
# inside it, so the window alone can't tell "continuously active" from
# "stopped since yesterday" -- see logwatch_timer_verdict.
# shellcheck disable=SC2034  # read only by bin/tick.sh, which sources this
LOGWATCH_TIMER_LOOKBACK_HOURS=24

# _logwatch_timer_re [unit] -- ERE fragment matching the timer unit in
# a systemd log line. Named unit when given (dots escaped), any
# *.timer otherwise.
_logwatch_timer_re() {
  local unit="${1:-}"
  if [ -n "$unit" ]; then
    printf '%s' "${unit//./\\.}"
  else
    printf '%s' '[^ ]+\.timer'
  fi
}

# logwatch_timer_transitioned <timer_journal> [timer_unit]
# 0 (true) when <timer_journal> (journalctl output for a *.timer unit)
# contains a Stopped or Started transition line for <timer_unit> (any
# *.timer when the unit is omitted). systemd only emits these on an
# actual unit state change -- an operator's `systemctl stop/start`, or
# boot/shutdown -- never on the timer's ordinary per-minute firing, so
# their presence in the reviewed window means a deliberate pause
# explains any apparent gap in the paired service's journal for it
# (igor#420: a `Stopped`/`Started agent.timer` pair was previously
# invisible to the reviewer, which guessed a long-running tick from the
# resulting silence instead).
logwatch_timer_transitioned() {
  local timer_journal="$1" unit="${2:-}"
  grep -qE "(Stopped|Started) $(_logwatch_timer_re "$unit")" <<<"$timer_journal"
}

# logwatch_timer_last_transition <timer_journal> [timer_unit]
# Prints "started", "stopped", or "" (no transition logged) for the
# LAST transition in <timer_journal> -- i.e. the state the timer was
# left in at the end of that journal's range.
logwatch_timer_last_transition() {
  local timer_journal="$1" unit="${2:-}" last
  last=$(grep -oE "(Stopped|Started) $(_logwatch_timer_re "$unit")" <<<"$timer_journal" \
    | tail -n 1 | cut -d' ' -f1)
  case "$last" in
    Started) printf 'started' ;;
    Stopped) printf 'stopped' ;;
    *) printf '' ;;
  esac
}

# logwatch_timer_verdict <since_journal> <prior_journal> <current_state> [timer_unit]
# The timer's disposition across the reviewed window, printed as one of:
#
#   paused   -- it was NOT continuously active (a state change touched
#               the window, or it was already stopped going in, or it's
#               stopped now). Any silence in the paired service's
#               journal is explained; file nothing for it.
#   active   -- positive evidence it ran the whole window: no
#               transition since the window opened, not stopped going
#               in, and still active now. Silence here is unexplained.
#   unknown  -- can't tell (systemctl gave us nothing). Treated as
#               paused by callers -- never file on a guess.
#
# <since_journal> covers [window start, now] rather than just the
# window, so a stop/start that landed between the window closing and
# this review still counts as "state changed". <prior_journal> covers
# the LOGWATCH_TIMER_LOOKBACK_HOURS before the window. This three-signal
# shape exists because a transition-in-window check alone reports
# "continuously active" for every hour of a multi-hour pause after the
# first -- exactly backwards, and worth a false ticket each hour.
logwatch_timer_verdict() {
  local since_journal="$1" prior_journal="$2" current_state="$3" unit="${4:-}"
  if logwatch_timer_transitioned "$since_journal" "$unit"; then
    printf 'paused'
    return 0
  fi
  if [ "$(logwatch_timer_last_transition "$prior_journal" "$unit")" = "stopped" ]; then
    printf 'paused'
    return 0
  fi
  case "$current_state" in
    active) printf 'active' ;;
    inactive|failed|deactivating) printf 'paused' ;;
    *) printf 'unknown' ;;
  esac
}

# logwatch_timer_lookback_since <win_start>
# The `--since` stamp for the prior-state journal read:
# LOGWATCH_TIMER_LOOKBACK_HOURS before <win_start>. A function so the
# expression is testable -- `date -d "$win_start -24 hours"` (the
# obvious spelling) parses the `-24` as a UTC OFFSET and walks
# FORWARD, which would quietly hand logwatch_timer_verdict a journal
# range from the future.
logwatch_timer_lookback_since() {
  date -d "$1 ${LOGWATCH_TIMER_LOOKBACK_HOURS} hours ago" '+%Y-%m-%d %H:%M:%S'
}

# logwatch_timespan_secs <span>
# Seconds for a systemd time span ("1min", "90s", "1h 30min", bare
# "60" = seconds). Non-zero when it can't be parsed.
logwatch_timespan_secs() {
  local span total=0 toks i n num unit mult
  span=$(tr '[:upper:]' '[:lower:]' <<<"$1" \
    | sed -E 's/([0-9])([a-z])/\1 \2/g; s/([a-z])([0-9])/\1 \2/g')
  read -r -a toks <<<"$span"
  n=${#toks[@]}
  [ "$n" -gt 0 ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    num="${toks[$i]}"
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    unit="${toks[$((i + 1))]:-}"
    case "$unit" in
      us|usec|ms|msec) mult=0 ;;
      s|sec|secs|second|seconds) mult=1 ;;
      m|min|mins|minute|minutes) mult=60 ;;
      h|hr|hour|hours) mult=3600 ;;
      d|day|days) mult=86400 ;;
      w|week|weeks) mult=604800 ;;
      *) mult=1; unit="" ;;   # bare number -- seconds
    esac
    total=$((total + num * mult))
    i=$((i + 1))
    [ -n "$unit" ] && i=$((i + 1))
  done
  printf '%s' "$total"
}

# logwatch_calendar_hourly <oncalendar_value>
# 0 (true) when an OnCalendar= expression fires at least once in every
# clock hour: the shorthands minutely/hourly, or an hour field that
# covers every hour (any minute spec matches at least once per hour, so
# the hour field is the whole question).
logwatch_calendar_hourly() {
  local spec time_tok hour
  spec=$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$spec" in
    minutely|hourly) return 0 ;;
    daily|weekly|monthly|yearly|annually|quarterly|semiannually) return 1 ;;
  esac
  time_tok=$(tr ' ' '\n' <<<"$spec" | grep ':' | tail -n 1)
  [ -n "$time_tok" ] || return 1
  hour="${time_tok%%:*}"
  case "$hour" in
    '*'|'*/1'|'0/1') return 0 ;;
    *) return 1 ;;
  esac
}

# logwatch_timer_subhourly <timer_file_contents>
# 0 (true) when the unit file DECLARES a schedule that fires at least
# once an hour. Only then does an empty service journal for one hour
# mean something is wrong -- a daily timer is silent for 23 hours a day
# by design, and logwatch reviews every repo that ships a systemd/ dir,
# not just per-minute ones. Unparseable or unreadable content answers
# "no": cadence unverified, so silence stays a skip.
logwatch_timer_subhourly() {
  local content="$1" line value secs
  while IFS= read -r line; do
    line=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$line")
    case "$line" in
      '#'*|';'*) continue ;;
    esac
    value="${line#*=}"
    case "$line" in
      OnUnitActiveSec=*|OnUnitInactiveSec=*)
        secs=$(logwatch_timespan_secs "$value") || continue
        if [ "$secs" -gt 0 ] && [ "$secs" -le 3600 ]; then return 0; fi
        ;;
      OnCalendar=*)
        logwatch_calendar_hourly "$value" && return 0
        ;;
    esac
  done <<<"$content"
  return 1
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
