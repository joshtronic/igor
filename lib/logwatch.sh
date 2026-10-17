#!/usr/bin/env bash
# lib/logwatch.sh -- pure helpers for the DAILY logwatch pass
# (bin/tick.sh do_logwatch_tick). Split out from tick.sh only so it's
# unit-testable in isolation; the rest of the pass (journal reads, the
# review-tier model call, ticket filing) stays in tick.sh.
#
# Source order: no dependencies beyond jq.
#
# -- Why daily-with-a-recurrence-bar (igor#432) -------------------
#
# The pass used to run hourly and file on a SINGLE occurrence. Over five
# verified tickets that produced one false positive (an operator pause), one
# duplicate carrying a wrong cause, one real symptom with a wrong cause, and
# two good ones. Each ticket, right or wrong, then cost a full build → review
# → rework cycle, so a ~40% diagnosis hit rate at the top of the funnel set
# the work rate for everything downstream.
#
# Two structural problems, both fixed here:
#
#   1. An hour of context cannot tell a transient from a chronic. They look
#      identical. So every blip read as a defect and got chased. A 24h window
#      can COUNT, and a count is exactly that discriminator.
#
#   2. Filing was triggered by the same threshold as looking. Looking costs
#      one model call; filing commits the fleet to an agentic cycle. The bar
#      for the second is now recurrence (LOGWATCH_MIN_OCCURRENCES), not
#      existence.
#
# A standing red state (a red lint baseline, an expired token) needs no
# separate rule: it recurs by definition, so the same bar catches it while a
# one-off blip drops to a digest line in the journal.
#
# The trade is deliberate: precision over recall. A genuine one-off defect
# that never repeats will now be logged and not filed. That is the intended
# direction -- an unfiled transient costs a grep; a filed phantom costs a
# build, a review, and a rework.

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

# -- Recurrence gate (igor#432) -----------------------------------
#
# How many times a distinct failure signature must appear inside the reviewed
# day before it is worth a ticket. Three, not two: two is a coin-flip that a
# retry-plus-alert pair can reach on its own, and the whole point is to stop
# treating a blip as a defect. Hardcoded per the "strong opinions" convention.
LOGWATCH_MIN_OCCURRENCES=3

# WHO said it. Only two sources count as evidence:
#
#   systemd[N]:  unit lifecycle -- exits, failures, start/stop
#   [agent]      the harness's own structured log lines
#
# Everything else in this journal is the CLAUDE SESSION'S PROSE, streamed
# verbatim, and it is fatal to a syntactic filter: the model narrates about
# failures constantly ("make lint reports the same two pre-existing
# warnings...", "Blocking -- retry scope", "Fixed the root cause"), so a smell
# match on prose is a near-guaranteed false positive. Measured against a real
# day: without this filter 37 signatures matched and the only one to reach the
# bar was `invoking claude for PR review (timeout Nm)` -- routine narration --
# while the two genuine exit-28s sat below it. Git plumbing ("Preparing
# worktree", "remote:", branch names that happen to contain the word timeout)
# is excluded for the same reason; a git failure that matters still surfaces
# as an [agent] warning or a nonzero unit exit.
LOGWATCH_SOURCE='systemd\[[0-9]+\]: |\[agent\] '

# Lines worth counting at all, among those sources. A failure smell,
# deliberately syntactic rather than semantic: deciding what a line MEANS is
# the reviewer's job, and the reviewer being confidently wrong about meaning is
# what this whole change is walking back. This only answers "could this be a
# failure?"
#
# Note "timed out" rather than a bare "timeout": the harness logs its own
# configured limits ("invoking claude (timeout 30m)") on every single tick, so
# the bare word matches a routine line hundreds of times a day and would clear
# any recurrence bar by itself.
LOGWATCH_SMELL='Failed with result|Main process exited|Traceback|command not found|unbound variable|: line [0-9]+:|[Ee]rror|ERROR|[Ww]arning|WARN|[Ff]ailed|[Ff]ailure|cannot |Cannot |No such file|Permission denied|timed out'

# _logwatch_normalize_stream -- the normalization, applied to a STREAM.
#
# One sed over the whole journal, not one sed per line. That distinction is
# the difference between a pass that finishes and one that doesn't: a real day
# of agent.service is ~9,500 lines, and a per-line subprocess costs minutes and
# would eat the tick budget whole.
#
# Collapses each line to a stable SIGNATURE so one condition recurring all day
# counts as one thing rather than 700 distinct lines. Strips the syslog prefix
# (timestamp, host, `unit[pid]:`), then flattens hex-ish tokens and digit runs
# -- pids, epochs, durations, byte counts and shas all differ between
# occurrences of the SAME failure.
#
# Nothing here but `s///` substitutions, so the stream is 1:1 -- exactly one
# output line per input line, including input that collapses to empty. Keep it
# that way: _logwatch_smell_timestamped joins this output against the raw lines
# POSITIONALLY and a dropped or added line would misattribute every timestamp
# after it. test-logwatch.sh asserts the parity.
_logwatch_normalize_stream() {
  sed -E \
    -e 's/^[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //' \
    -e 's/^[A-Za-z0-9_.@-]+\[[0-9]+\]: //' \
    -e 's/\b[0-9a-f]{7,40}\b/HEX/g' \
    -e 's/[0-9]+/N/g' \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^ //; s/ $//'
}

# logwatch_normalize_line <line> -- single-line wrapper, for tests and for
# reading. The bulk paths use the stream form above.
logwatch_normalize_line() {
  printf '%s\n' "$1" | _logwatch_normalize_stream
}

# _logwatch_smell_signatures <journal> -- every failure-smell signature in the
# journal, one per line, unsorted. Used by the untimed fallback below.
_logwatch_smell_signatures() {
  _logwatch_smell_lines "$1" \
    | _logwatch_normalize_stream \
    | grep -v '^$' || true
}

# -- Incidents, not lines (igor#17) --------------------------------
#
# igor#14: a single GitLab API blip produced 4 failed agent.service starts,
# all between 02:11 and 02:12, each recovered by the very next tick -- one
# incident, counted as four recurrences. Raw occurrence counting cannot tell
# a burst from a chronic when the lines arrive close together, so the bar
# groups a signature's occurrences into incidents first: a gap of 15 minutes
# or more between consecutive occurrences starts a new incident. A signature
# clears the bar when it has >= LOGWATCH_MIN_OCCURRENCES incidents, OR any
# single incident spans 60 minutes or more (so a failure repeating every
# minute for hours -- one long incident -- still surfaces). Both numbers are
# hardcoded, same convention as LOGWATCH_MIN_OCCURRENCES.
LOGWATCH_INCIDENT_GAP_SECS=900
LOGWATCH_INCIDENT_SUSTAINED_SECS=3600

# _logwatch_smell_lines <journal> -- raw (unnormalized) lines matching the
# trusted-source + failure-smell filters, one per line. Shared by the
# signature grouping below and by the incident timestamp extraction, so both
# apply the exact same filter.
_logwatch_smell_lines() {
  printf '%s\n' "$1" \
    | grep -E "$LOGWATCH_SOURCE" \
    | grep -E "$LOGWATCH_SMELL" || true
}

# _logwatch_smell_timestamped <journal> -- "<epoch>\t<signature>" per matching
# occurrence, unsorted. `date -d` runs once per matching line, not once per
# journal line -- matching lines are already the filtered minority, unlike
# the whole-journal normalization pass which has to stay a single stream.
#
# The 15-char prefix is journalctl's DEFAULT `short` format ("Oct 16 02:11:33"),
# which is what bin/tick.sh collects -- it passes no `-o`. An occurrence whose
# prefix doesn't parse is dropped here; when that happens to EVERY occurrence
# (`-o cat` and `-o short-unix` both produce prefixes `date -d` rejects
# outright) the caller falls back rather than reporting an empty day.
#
# The paste join is POSITIONAL: it pairs the Nth signature with the Nth raw
# line, which holds because _logwatch_normalize_stream is 1:1 (see there).
_logwatch_smell_timestamped() {
  local journal="$1" raw sig line ts epoch
  raw=$(_logwatch_smell_lines "$journal")
  [ -z "$raw" ] && return 0
  paste -d '\t' \
    <(printf '%s\n' "$raw" | _logwatch_normalize_stream) \
    <(printf '%s\n' "$raw") \
  | while IFS=$'\t' read -r sig line; do
      [ -z "$sig" ] && continue
      ts="${line:0:15}"
      epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
      printf '%s\t%s\n' "$epoch" "$sig"
    done
}

# _logwatch_signature_counts <journal> <min> -- the pre-igor#17 RAW-occurrence
# bar, emitted in the same shape as the incident grouping below. Reached only
# when smell lines are present but not one of them carried a parseable
# timestamp, i.e. the journal format changed under us. A gate that goes silent
# on a format change is worse than one that over-reports a burst: a burst
# ticket gets closed, a quiet gate looks like a healthy day forever. So the
# format assumption fails back to the old bar instead of to nothing.
_logwatch_signature_counts() {
  local journal="$1" min="$2" sigs
  sigs=$(_logwatch_smell_signatures "$journal")
  [ -z "$sigs" ] && return 0
  printf '%s\n' "$sigs" | sort | uniq -c \
    | awk -v m="$min" '{ c=$1; $1=""; sub(/^ /,""); printf "%d\t%d\t%s\n", c, (c+0 >= m+0) ? 1 : 0, $0 }'
}

# _logwatch_signature_incidents <journal> <min> -- "<count>\t<meets>\t<signature>"
# per distinct signature, where <count> is the raw occurrence count and
# <meets> is 1 when the signature clears the incident bar described above,
# 0 otherwise. Shared core for logwatch_recurring and
# logwatch_distinct_transients so both judge a signature the same way.
_logwatch_signature_incidents() {
  local journal="$1" min="$2"
  local timestamped
  timestamped=$(_logwatch_smell_timestamped "$journal")
  if [ -z "$timestamped" ]; then
    _logwatch_signature_counts "$journal" "$min"
    return 0
  fi
  sort -t $'\t' -k2,2 -k1,1n <<<"$timestamped" \
    | awk -F'\t' -v min="$min" -v gap="$LOGWATCH_INCIDENT_GAP_SECS" -v sustained="$LOGWATCH_INCIDENT_SUSTAINED_SECS" '
      function flush() {
        if (n == 0) return
        incidents = 1
        start = times[1]
        prev = times[1]
        maxspan = 0
        for (i = 2; i <= n; i++) {
          if (times[i] - prev >= gap) {
            span = prev - start
            if (span > maxspan) maxspan = span
            incidents++
            start = times[i]
          }
          prev = times[i]
        }
        span = prev - start
        if (span > maxspan) maxspan = span
        meets = (incidents >= min + 0 || maxspan >= sustained + 0) ? 1 : 0
        printf "%d\t%d\t%s\n", n, meets, cur
      }
      {
        if ($2 != cur) { flush(); cur = $2; n = 0; delete times }
        n++
        times[n] = $1
      }
      END { flush() }
    '
}

# logwatch_recurring <journal> [min_occurrences]
# The heart of the gate. Keeps only failure-smell lines from trusted sources,
# groups them into incidents per signature (see above), and prints one row
# per signature that met the bar:
#
#   <count>\t<signature>
#
# <count> is the raw occurrence count, carried through for the ticket body --
# the bar itself is judged on incidents, not this number. Signatures below
# the bar are omitted entirely -- they become the digest line the caller
# logs, not a ticket. Prints nothing when nothing recurred, which is the
# expected common case on a healthy day.
logwatch_recurring() {
  local journal="$1" min="${2:-$LOGWATCH_MIN_OCCURRENCES}"
  _logwatch_signature_incidents "$journal" "$min" \
    | awk -F'\t' '$2 == 1 { print $1"\t"$3 }' \
    | sort -t $'\t' -k1,1rn
}

# logwatch_distinct_transients <journal> [min_occurrences]
# How many distinct failure signatures were seen but did NOT meet the bar. The
# caller logs this so a suppressed day stays greppable -- "nothing recurred"
# and "the pass never ran" must not look alike.
logwatch_distinct_transients() {
  local journal="$1" min="${2:-$LOGWATCH_MIN_OCCURRENCES}"
  _logwatch_signature_incidents "$journal" "$min" \
    | awk -F'\t' '$2 == 0 { n++ } END { print n+0 }'
}

# logwatch_samples <journal> <signature> [max]
# Up to <max> verbatim lines (default 3) whose signature matches, so a finding
# carries real evidence with real timestamps rather than the flattened form.
# First and last matter most -- they bound when the condition started and
# whether it was still going -- so take from both ends.
#
# `paste` of the normalized stream against the original gives signature and
# source line side by side in one pass, instead of re-normalizing per line.
logwatch_samples() {
  local journal="$1" want="$2" max="${3:-3}"
  local -a hits=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && hits+=("$line")
  done < <(paste -d '\t' \
             <(printf '%s\n' "$journal" | _logwatch_normalize_stream) \
             <(printf '%s\n' "$journal") \
           | awk -F'\t' -v w="$want" '$1 == w { sub(/^[^\t]*\t/, ""); print }')
  local n=${#hits[@]}
  [ "$n" -eq 0 ] && return 0
  if [ "$n" -le "$max" ]; then
    printf '%s\n' "${hits[@]}"
    return 0
  fi
  printf '%s\n' "${hits[0]}"
  [ "$max" -ge 3 ] && printf '%s\n' "${hits[$((n / 2))]}"
  printf '%s\n' "${hits[$((n - 1))]}"
}
