#!/usr/bin/env bash
# test-logwatch.sh -- unit tests for lib/logwatch.sh:
# logwatch_health_backoff_in_window, the guard that flags when a
# Claude health backoff (auth/limit) overlapped the reviewed clock
# hour (igor#334), plus the chronic-escalation + narration-line
# precision refinement on top of it (igor#340):
#   - logwatch_record_backoff_day / logwatch_chronic_backoff --
#     distinct-day tracking so a backoff recurring on >=2 calendar
#     days escalates instead of staying suppressed forever.
#   - logwatch_strip_backoff_noise -- removes only the backoff's own
#     narration lines from a journal, so a genuine unrelated failure
#     in the same window still stands out.
#   - logwatch_timer_transitioned -- distinguishes a timer-explained
#     silence from a real one, so a deliberate `systemctl stop
#     agent.timer` doesn't get misread as a stuck tick (igor#420).
#
# Skip-safe: exits 0 with a notice if jq is absent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "test-logwatch: jq not installed -- skipping"; exit 0; }

# shellcheck source=lib/logwatch.sh
. "$HERE/lib/logwatch.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (rc0 expected)"; fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (rc!=0 expected)"; else ok "$d"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has()    { case "$2" in *"$3"*) ok "$1";; *) bad "$1: missing [$3]";; esac; }
hasnt()  { case "$2" in *"$3"*) bad "$1: unexpected [$3]";; *) ok "$1";; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/discretionary-state.json"

# A fixed "reviewed hour" window: 12:00:00 -> 13:00:00 (epoch, arbitrary).
WIN_START=1000000000
WIN_END=1000003600

write_health() {  # <kind> <first_failure> <cooldown_until>
  jq -n --arg k "$1" --argjson ff "$2" --argjson cu "$3" \
    '{health: {kind: $k, first_failure: $ff, cooldown_until: $cu}}' > "$STATE"
}

echo "== no state file =="
rm -f "$STATE"
no "missing state file -> no suppression" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== healthy (no backoff) =="
write_health "" 0 0
no "cleared health record -> no suppression" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff fully inside the reviewed window =="
write_health "auth" $((WIN_START + 60)) $((WIN_START + 120))
yes "auth backoff inside window -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "limit" $((WIN_START + 60)) $((WIN_START + 120))
yes "limit backoff inside window -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff overlapping only the edges =="
write_health "auth" $((WIN_START - 100)) $((WIN_START + 10))
yes "backoff straddling window start -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "auth" $((WIN_END - 10)) $((WIN_END + 100))
yes "backoff straddling window end -> suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== backoff entirely outside the window =="
write_health "auth" $((WIN_START - 7200)) $((WIN_START - 3600))
no "backoff well before window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

write_health "auth" $((WIN_END + 3600)) $((WIN_END + 7200))
no "backoff well after window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== kind must be auth or limit =="
write_health "other" $((WIN_START + 60)) $((WIN_START + 120))
no "kind=other overlapping window -> not suppressed" logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "== logwatch_record_backoff_day / logwatch_chronic_backoff =="
rm -f "$STATE"
no "no days recorded yet -> not chronic" logwatch_chronic_backoff "$STATE"

logwatch_record_backoff_day "$STATE" "2026-07-01"
no "1 distinct day -> not chronic (transient)" logwatch_chronic_backoff "$STATE"

logwatch_record_backoff_day "$STATE" "2026-07-01"
eq "re-recording the same day dedups" 1 "$(jq '.logwatch.backoff_days | length' "$STATE")"
no "still 1 distinct day after a dup -> not chronic" logwatch_chronic_backoff "$STATE"

logwatch_record_backoff_day "$STATE" "2026-07-02"
eq "2 distinct days recorded" 2 "$(jq '.logwatch.backoff_days | length' "$STATE")"
yes "2 distinct days -> chronic" logwatch_chronic_backoff "$STATE"

logwatch_record_backoff_day "$STATE" "2026-07-03"
yes "3 distinct days -> still chronic" logwatch_chronic_backoff "$STATE"

echo "== logwatch_record_backoff_day preserves sibling .logwatch keys =="
jq -n '{logwatch: {hour: "2026-07-03T09"}}' > "$STATE"
logwatch_record_backoff_day "$STATE" "2026-07-03"
eq "hour survives a backoff-day write" "2026-07-03T09" "$(jq -r '.logwatch.hour' "$STATE")"
eq "backoff_days recorded alongside hour" 1 "$(jq '.logwatch.backoff_days | length' "$STATE")"

echo "== logwatch_strip_backoff_noise =="
NOISE_ONLY="$(cat <<'EOF'
Jul 03 09:00:01 host agent[1]: claude health: backoff active (kind=auth) -- skipping all model work this tick
Jul 03 09:15:00 host agent[1]: health: auth alert emailed to ops@example.com
Jul 03 09:20:00 host agent[1]: logwatch: agent.service: review call failed (attempt 1)
Jul 03 09:20:05 host agent[1]: logwatch: agent.service: no parseable review after 2 attempts -- giving up until tomorrow
EOF
)"
eq "pure backoff noise strips to empty" "" "$(logwatch_strip_backoff_noise "$NOISE_ONLY")"

MIXED="$(cat <<'EOF'
Jul 03 09:00:01 host agent[1]: claude health: backoff active (kind=auth) -- skipping all model work this tick
Jul 03 09:05:00 host agent[1]: Traceback (most recent call last): unbound variable in do_seo_tick
Jul 03 09:15:00 host agent[1]: health: auth alert emailed to ops@example.com
EOF
)"
STRIPPED=$(logwatch_strip_backoff_noise "$MIXED")
hasnt "noise lines removed from mixed journal" "$STRIPPED" "backoff active (kind=auth)"
hasnt "health-alert-emailed line removed from mixed journal" "$STRIPPED" "alert emailed"
has   "unrelated failure survives noise-stripping" "$STRIPPED" "unbound variable in do_seo_tick"

echo "== full test matrix (igor#340) -- mapped onto do_logwatch_tick's decision (see bin/tick.sh) =="
# do_logwatch_tick computes suppress_noise=1 only for a TRANSIENT
# backoff (logwatch_health_backoff_in_window true, logwatch_chronic_backoff
# false) and passes it to logwatch_review_unit, which then runs the
# journal through logwatch_strip_backoff_noise before reviewing. Each
# scenario below is that same decision, exercised end to end on the
# pure functions it's built from.

echo "-- no-backoff-normal: no backoff overlapped the window -> suppress_noise stays 0, journal is never filtered --"
no "no-backoff case computes suppress_noise=0 (via logwatch_health_backoff_in_window)" \
  logwatch_health_backoff_in_window "$STATE" "$WIN_START" "$WIN_END"

echo "-- transient-suppressed: backoff on its first distinct day -> suppress_noise=1, noise-only journal strips to nothing (unit skipped, no ticket) --"
rm -f "$STATE"
logwatch_record_backoff_day "$STATE" "2026-07-03"
no "backoff on 1 distinct day -> not chronic -> suppress_noise=1" logwatch_chronic_backoff "$STATE"
eq "suppress_noise=1 applied to a noise-only journal -> empty (skipped)" "" "$(logwatch_strip_backoff_noise "$NOISE_ONLY")"

echo "-- chronic->=2-day-files: backoff recurs on a 2nd distinct day -> suppress_noise=0, narration stays intact for the reviewer --"
logwatch_record_backoff_day "$STATE" "2026-07-04"
yes "backoff on 2 distinct days -> chronic -> suppress_noise=0" logwatch_chronic_backoff "$STATE"
# Chronic means logwatch_review_unit is called with suppress_noise=0,
# so logwatch_strip_backoff_noise is never invoked -- the journal the
# reviewer sees is byte-for-byte what journalctl produced.
has "chronic path's unfiltered journal still carries the backoff narration" "$NOISE_ONLY" "backoff active (kind=auth)"

echo "-- unrelated-failure-during-backoff-still-files: transient backoff, but a real failure shares the window -> it survives stripping --"
has "unrelated failure line survives suppress_noise=1 stripping" "$(logwatch_strip_backoff_noise "$MIXED")" "unbound variable in do_seo_tick"

echo "== logwatch_timer_transitioned (igor#420) =="
# do_logwatch_tick's decision, exercised on the pure function it's built
# from (see bin/tick.sh's logwatch_review_unit): when a companion
# *.timer unit's own journal for the window shows a Stopped/Started
# transition, any silence in the paired service's journal is explained
# by that operator-initiated pause and no finding is filed for it. When
# it shows no transition, the timer is presumed to have run
# continuously -- so an EMPTY service journal for that same window
# becomes itself a finding (a per-minute unit producing nothing is the
# failure), while a NON-empty, normal-looking journal files nothing (no
# gap to explain in the first place).

STOPPED_STARTED="$(cat <<'EOF'
Jul 24 19:42:14 igor.sherver.org systemd[805]: Stopped agent.timer - Agent tick timer -- fires the next tick.
Jul 24 21:46:32 igor.sherver.org systemd[805]: Started agent.timer - Agent tick timer -- fires the next tick.
EOF
)"
yes "window containing a Stopped/Started pair -> transitioned (gap explained, no finding filed)" \
  logwatch_timer_transitioned "$STOPPED_STARTED"

no "empty timer journal (continuously active, no state change logged) -> not transitioned" \
  logwatch_timer_transitioned ""
# -> service journal empty in this case: real fault, finding filed.
# -> service journal has normal per-minute ticks: nothing to explain, no finding filed.

no "'Starting'/'Stopping' (in-progress, not completed) do not count as a transition" \
  logwatch_timer_transitioned "Jul 24 19:42:10 igor.sherver.org systemd[805]: Stopping agent.timer - Agent tick timer -- fires the next tick..."

no "a Started/Stopped line for a DIFFERENT unit does not count" \
  logwatch_timer_transitioned "Jul 24 21:01:00 igor.sherver.org systemd[805]: Started agent.service - Agent tick."

no "a transition for a DIFFERENT timer does not count when the unit is named" \
  logwatch_timer_transitioned "Jul 24 21:01:00 igor.sherver.org systemd[805]: Stopped backup.timer - Backup." "agent.timer"

yes "a transition for the NAMED timer counts" \
  logwatch_timer_transitioned "$STOPPED_STARTED" "agent.timer"

echo "== logwatch_timer_verdict (igor#421 review) =="
# The in-window transition check alone can't tell "continuously active"
# from "stopped for hours": systemd logs a state CHANGE, so a pause
# spanning 10:30-14:00 leaves the 11:00, 12:00 and 13:00 windows with no
# transition at all. The verdict therefore folds in two more signals --
# the last transition BEFORE the window, and the timer's state RIGHT NOW
# -- and only says "active" (the one verdict that lets an empty service
# journal file a finding) on positive evidence of continuous activity.

STARTED_ONLY="Jul 24 21:46:32 igor.sherver.org systemd[805]: Started agent.timer - Agent tick timer."
STOPPED_ONLY="Jul 24 19:42:14 igor.sherver.org systemd[805]: Stopped agent.timer - Agent tick timer."

eq "transition inside the window -> paused (the #420 case)" \
  "paused" "$(logwatch_timer_verdict "$STOPPED_STARTED" "" "active" "agent.timer")"
eq "no transition, stopped before the window, still stopped -> paused (hour 2+ of a long pause)" \
  "paused" "$(logwatch_timer_verdict "" "$STOPPED_ONLY" "inactive" "agent.timer")"
eq "no transition anywhere, but the timer is stopped right now -> paused" \
  "paused" "$(logwatch_timer_verdict "" "" "inactive" "agent.timer")"
eq "no transition, started before the window, active now -> active (silence is unexplained)" \
  "active" "$(logwatch_timer_verdict "" "$STARTED_ONLY" "active" "agent.timer")"
eq "no evidence either way but active now -> active" \
  "active" "$(logwatch_timer_verdict "" "" "active" "agent.timer")"
eq "systemctl gave us nothing -> unknown (never file on a guess)" \
  "unknown" "$(logwatch_timer_verdict "" "" "" "agent.timer")"

echo "== logwatch_timer_lookback_since =="
# The prior-state read must look BACKWARD. `date -d "<stamp> -24 hours"`
# reads the -24 as a UTC offset and lands a day and change in the
# FUTURE -- an empty journal every time, which reads as "no prior
# transition" and quietly undoes the fix above.
eq "lookback walks back a full day" \
  "2026-07-23 21:00:00" "$(logwatch_timer_lookback_since '2026-07-24 21:00:00')"
eq "lookback across a year boundary" \
  "2025-12-31 00:00:00" "$(logwatch_timer_lookback_since '2026-01-01 00:00:00')"

echo "== logwatch_timer_subhourly (igor#421 review) =="
# "Has a companion .timer" does not mean "fires within the hour". A
# daily timer would otherwise hit the empty-journal branch for 23 of 24
# hourly passes. Only a schedule that provably fires at least once an
# hour may turn silence into a finding.

AGENT_TIMER="$(cat <<'EOF'
[Timer]
OnBootSec=2min
OnUnitInactiveSec=1min
Persistent=true
EOF
)"
yes "OnUnitInactiveSec=1min -> fires within the hour (the harness's own agent.timer)" \
  logwatch_timer_subhourly "$AGENT_TIMER"
yes "OnUnitActiveSec=30min -> fires within the hour" \
  logwatch_timer_subhourly "[Timer]
OnUnitActiveSec=30min"
yes "OnUnitActiveSec=1h -> exactly hourly, still counts" \
  logwatch_timer_subhourly "[Timer]
OnUnitActiveSec=1h"
no "OnUnitActiveSec=6h -> too slow to expect an entry every hour" \
  logwatch_timer_subhourly "[Timer]
OnUnitActiveSec=6h"
no "OnBootSec alone -> one-shot, no recurrence to expect" \
  logwatch_timer_subhourly "[Timer]
OnBootSec=2min"
yes "OnCalendar=*-*-* *:*:00 -> every minute" \
  logwatch_timer_subhourly "[Timer]
OnCalendar=*-*-* *:*:00"
yes "OnCalendar=*:0/5 -> every five minutes" \
  logwatch_timer_subhourly "[Timer]
OnCalendar=*:0/5"
yes "OnCalendar=hourly -> once an hour" \
  logwatch_timer_subhourly "[Timer]
OnCalendar=hourly"
no "OnCalendar=daily -> once a day" \
  logwatch_timer_subhourly "[Timer]
OnCalendar=daily"
no "OnCalendar=*-*-* 03:00:00 -> a fixed hour, silent the other 23" \
  logwatch_timer_subhourly "[Timer]
OnCalendar=*-*-* 03:00:00"
no "commented-out schedule does not count" \
  logwatch_timer_subhourly "[Timer]
# OnUnitInactiveSec=1min"
no "unreadable/empty timer file -> cadence unverifiable, no finding" \
  logwatch_timer_subhourly ""

echo "== logwatch_normalize_line: a signature stable across occurrences (igor#432) =="
# The same failure recurring all day differs only in timestamp, pid and the
# volatile numbers inside it. If those don't collapse, 700 occurrences of one
# condition count as 700 distinct things and nothing ever meets the bar.
N1=$(logwatch_normalize_line 'Jul 25 00:32:37 igor.sherver.org systemd[805]: agent.service: Main process exited, code=exited, status=28/n/a')
N2=$(logwatch_normalize_line 'Jul 26 11:54:35 igor.sherver.org systemd[991]: agent.service: Main process exited, code=exited, status=28/n/a')
eq "same failure on different days/pids -> identical signature" "$N1" "$N2"
eq "signature drops the syslog prefix" "agent.service: Main process exited, code=exited, status=N/n/a" "$N1"

N3=$(logwatch_normalize_line 'Jul 25 00:32:37 h systemd[805]: agent.service: Main process exited, code=exited, status=1/FAILURE')
if [ "$N1" != "$N3" ]; then ok "a DIFFERENT failure keeps a different signature"
else bad "distinct failures collapsed into one signature"; fi

N4=$(logwatch_normalize_line 'Jul 25 21:10:21 h tick.sh[2597922]: [agent] review: joshtronic/igor#427 head 5212f914 -> APPROVE')
N5=$(logwatch_normalize_line 'Jul 25 21:12:59 h tick.sh[2604823]: [agent] review: joshtronic/igor#428 head 3d54a9ee -> APPROVE')
eq "shas and issue numbers flatten so per-PR lines group" "$N4" "$N5"

echo "== logwatch_recurring: only what met the bar (igor#432) =="
# A day with one transient blip and one genuinely chronic condition. The blip
# is the exact shape that used to get filed and chased.
DAY=$(cat <<'EOF'
Jul 25 00:32:37 h systemd[805]: agent.service: Main process exited, code=exited, status=28/n/a
Jul 25 01:00:01 h tick.sh[100]: [agent] no claimable work -- idle
Jul 25 02:00:01 h tick.sh[101]: [agent] warning: could not log time on acme/x#1
Jul 25 03:00:01 h tick.sh[102]: [agent] warning: could not log time on acme/x#2
Jul 25 04:00:01 h tick.sh[103]: [agent] warning: could not log time on acme/x#3
Jul 25 05:00:01 h tick.sh[104]: [agent] warning: could not log time on acme/x#4
Jul 25 06:00:01 h tick.sh[105]: [agent] no claimable work -- idle
EOF
)
REC=$(logwatch_recurring "$DAY")
has "the 4x warning is reported" "$REC" "could not log time"
if grep -q 'Main process exited' <<<"$REC"; then
  bad "a single exit-28 met the bar -- the transient is still being filed"
else
  ok "the ONE-OFF exit-28 does NOT meet the bar (the igor#424/#419 class)"
fi
eq "count is carried, tab-separated" "4" "$(awk -F'\t' '/could not log time/{print $1}' <<<"$REC")"
if grep -q 'no claimable work' <<<"$REC"; then
  bad "a routine idle line was counted as a failure smell"
else
  ok "routine non-failure lines are never counted, however often they repeat"
fi

eq "clean journal -> nothing recurred" "" "$(logwatch_recurring 'Jul 25 01:00:01 h tick.sh[1]: [agent] no claimable work -- idle')"
eq "empty journal -> empty" "" "$(logwatch_recurring '')"

echo "== the bar is configurable for testing, and 3 is the shipped value =="
eq "LOGWATCH_MIN_OCCURRENCES is 3" "3" "$LOGWATCH_MIN_OCCURRENCES"
has "lowering the bar to 1 surfaces the transient" "$(logwatch_recurring "$DAY" 1)" "Main process exited"

echo "== logwatch_distinct_transients: suppressed things stay greppable =="
# "Nothing recurred" and "the pass never ran" must not look identical in the
# journal, or a silently broken pass reads as a clean day.
eq "counts the distinct below-bar signatures" "1" "$(logwatch_distinct_transients "$DAY")"
eq "clean day -> 0 transients" "0" "$(logwatch_distinct_transients 'Jul 25 01:00:01 h tick.sh[1]: [agent] idle')"

echo "== logwatch_samples: verbatim evidence, not the flattened form =="
SIG=$(awk -F'\t' '/could not log time/{print $2}' <<<"$REC")
SAMP=$(logwatch_samples "$DAY" "$SIG")
eq "returns at most 3 samples" "3" "$(printf '%s\n' "$SAMP" | grep -c .)"
has "samples are the ORIGINAL lines, timestamps intact" "$SAMP" "Jul 25 02:00:01"
has "samples bound the condition: the last occurrence is included" "$SAMP" "acme/x#4"

echo "== source filter: the model's own prose is never evidence (igor#432) =="
# The Claude session's narration is streamed verbatim into this journal, and it
# talks about failures constantly. Measured on a real day, without this filter
# 37 signatures matched and the ONLY one to clear the bar was routine
# narration, while the two genuine exit-28s sat below it.
PROSE=$(cat <<'EOF'
Jul 25 21:47:01 h tick.sh[100]: `agent-ask.sh` is blocked by this session's permission profile, so I can't file that follow-up.
Jul 25 21:47:02 h tick.sh[100]: `make lint` reports the same two pre-existing warnings as before -- neither is in the lines this PR touches.
Jul 25 21:47:03 h tick.sh[100]: Fixed the root cause: an unguarded pipe aborted the whole tick under set -e.
Jul 25 21:47:04 h tick.sh[100]: **Blocking -- retry scope.** Anything else returns curl's own status immediately.
Jul 25 21:47:05 h tick.sh[100]: No failures across the whole suite. Let's confirm the exit status.
EOF
)
eq "five prose lines about failures -> nothing counted" "" "$(logwatch_recurring "$PROSE" 1)"
eq "and none of them register as transients either" "0" "$(logwatch_distinct_transients "$PROSE" 1)"

# Same words, but emitted by systemd and by the harness's own [agent] logger.
TRUSTED=$(cat <<'EOF'
Jul 25 00:32:37 h systemd[805]: agent.service: Failed with result 'exit-code'.
Jul 25 11:54:35 h systemd[805]: agent.service: Failed with result 'exit-code'.
Jul 25 14:00:00 h tick.sh[101]: [agent] warning: could not log time on acme/x#1
EOF
)
has "systemd lines ARE counted" "$(logwatch_recurring "$TRUSTED" 1)" "Failed with result"
has "[agent] lines ARE counted" "$(logwatch_recurring "$TRUSTED" 1)" "could not log time"

echo "== 'timeout' as a configured limit is not a failure =="
# The harness logs its own timeout setting on every tick; a bare-word match
# would clear any recurrence bar by itself, every single day.
ROUTINE=$(printf '%s\n%s\n%s\n%s\n' \
  'Jul 25 01:00:00 h tick.sh[1]: [agent] invoking claude (timeout 30m)' \
  'Jul 25 02:00:00 h tick.sh[2]: [agent] invoking claude (timeout 30m)' \
  'Jul 25 03:00:00 h tick.sh[3]: [agent] invoking claude (timeout 30m)' \
  'Jul 25 04:00:00 h tick.sh[4]: [agent] invoking claude (timeout 30m)')
eq "4x 'invoking claude (timeout 30m)' -> not a finding" "" "$(logwatch_recurring "$ROUTINE")"
has "but a real 'timed out' IS counted" \
  "$(logwatch_recurring 'Jul 25 01:00:00 h tick.sh[1]: [agent] deploy barrier timed out waiting for sha' 1)" \
  "timed out"

if [ "$FAIL" -eq 0 ]; then
  echo "test-logwatch: all checks passed"
else
  echo "test-logwatch: $FAIL FAILED"
  exit 1
fi
