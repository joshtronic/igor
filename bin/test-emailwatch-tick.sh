#!/usr/bin/env bash
# test-emailwatch-tick.sh -- integration tests for the bin/tick.sh glue
# around lib/emailwatch.sh (igor#636): emailwatch_alarm, emailwatch_check,
# and do_emailwatch_tick. bin/test-emailwatch.sh already covers the pure
# decision (emailwatch_verdict) off plain strings; this file proves the
# glue wires that decision to the RIGHT channel -- a Forgejo issue, never
# email -- and that the pass never mistakes its own blindness (no
# journalctl, an unreadable state file) for "all clear".
#
# do_emailwatch_tick lives inline in bin/tick.sh (which has top-level
# side-effecting code, so it can't be sourced directly). Following
# test-maintenance.sh/test-cascade.sh's precedent, each function under test
# is lifted out with `sed -n '/^fn() {$/,/^}$/p'` and eval'd here, with its
# dependencies (forgejo_*, journalctl, log, discretionary_state_file)
# stubbed.
#
# Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-emailwatch-tick: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

# shellcheck source=../lib/emailwatch.sh
. "$HERE/lib/emailwatch.sh"

extract_fn() { sed -n "/^$1() {\$/,/^}\$/p" "$TICK"; }

for fn in emailwatch_shipreport_opted_in emailwatch_sports_opted_in \
          emailwatch_alarm emailwatch_check do_emailwatch_tick; do
  SRC="$(extract_fn "$fn")"
  if [ -z "$SRC" ]; then
    echo "test-emailwatch-tick: could not extract $fn() from bin/tick.sh -- skipping"
    exit 0
  fi
  eval "$SRC"
done
# The retired-surfaces denylist is a plain var assignment, not a function --
# pull it from tick.sh too so a future edit there can't silently drift out
# of sync with what this file exercises.
RETIRED_LINE="$(grep '^EMAILWATCH_RETIRED_SURFACES=' "$TICK")"
if [ -z "$RETIRED_LINE" ]; then
  echo "test-emailwatch-tick: could not find EMAILWATCH_RETIRED_SURFACES in bin/tick.sh -- skipping"
  exit 0
fi
eval "$RETIRED_LINE"

log() { printf '[agent] %s\n' "$*" >&2; }
discretionary_state_file() { echo "$AGENT_STATE_DIR/discretionary-state.json"; }

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }

TMP="$(mktemp -d)" || { echo "test-emailwatch-tick: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

AGENT_STATE_DIR="$TMP/state"
# Read only by the eval'd emailwatch_alarm -- static analysis can't see
# through the eval.
# shellcheck disable=SC2034
BOT_USER="igor-bot"
# shellcheck disable=SC2034
AUTOMERGE_SELF_REPO="joshtronic/igor"
# shellcheck disable=SC2034
FORGEJO_REVIEWER="josh"

# email_send stubbed to ALWAYS fail -- proves an alarm reaching Forgejo
# never routes through (or depends on) the email transport at all. Nothing
# under test calls this directly; it exists so a future regression that
# threads email into the alarm path fails loudly here instead of shipping.
email_send() { return 1; }

# Forgejo stubs. emailwatch_alarm calls forgejo_find_marked_issue and
# forgejo_open_issue through command substitution ($(...)), which forks a
# subshell -- a plain shell-variable write inside them would vanish with
# that subshell, so both record to FILES instead. forgejo_assign is called
# directly (no subshell) and could use a variable, but the file keeps every
# recorder here consistent.
ISSUES_OPENED_LOG="$TMP/issues_opened.log"
ASSIGNED_LOG="$TMP/assigned.log"
FIND_MARKED_CALLED_LOG="$TMP/find_marked_calls.log"
FIND_MARKED_RESULT=""
forgejo_find_marked_issue() {
  echo x >> "$FIND_MARKED_CALLED_LOG"
  printf '%s' "$FIND_MARKED_RESULT"
}
NEXT_ISSUE_NUM=100
forgejo_open_issue() {
  local repo="$1" title="$2"
  NEXT_ISSUE_NUM=$((NEXT_ISSUE_NUM + 1))
  printf '%s|%s\n' "$repo" "$title" >> "$ISSUES_OPENED_LOG"
  echo "$NEXT_ISSUE_NUM"
}
forgejo_assign() {
  printf '%s#%s -> %s\n' "$1" "$2" "$3" >> "$ASSIGNED_LOG"
  return 0
}

issues_opened() { cat "$ISSUES_OPENED_LOG" 2>/dev/null; }
issues_opened_count() { issues_opened | grep -c . || true; }

reset_state() {
  rm -rf "$AGENT_STATE_DIR"; mkdir -p "$AGENT_STATE_DIR"
  : > "$ISSUES_OPENED_LOG"; : > "$ASSIGNED_LOG"; : > "$FIND_MARKED_CALLED_LOG"
  FIND_MARKED_RESULT=""
}

# journalctl stub: prints $JOURNAL_FIXTURE regardless of args, so callers
# only need to set that variable, not fake the whole --since/--until
# contract.
JOURNAL_FIXTURE=""
journalctl() { printf '%s\n' "$JOURNAL_FIXTURE"; }

YEST=$(date -d '-1 days' +%F 2>/dev/null || date -v-1d +%F)

echo "== the 2026-09-14 case: stamped sent, no matching success line -> alarms via Forgejo =="
reset_state
PRIMARY_RECIPIENTS="a@b.com"; SMTP2GO_API_KEY="k"; SMTP2GO_SENDER="s@b.com"
unset SPORTS_LEAGUES
cat > "$AGENT_STATE_DIR/discretionary-state.json" <<EOF
{"shipreport": {"date": "$YEST", "sent": true, "failures": 0}}
EOF
JOURNAL_FIXTURE="Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: WARN comment fetch failed for a/b#1"
do_emailwatch_tick >/dev/null 2>"$TMP/err1.log"
RC=$?
eq "do_emailwatch_tick reports it ran (rc0)" "0" "$RC"
eq "exactly one issue opened" "1" "$(issues_opened_count)"
has "the alarm names shipreport and the lying stamp" "$(issues_opened)" "shipreport: stamped sent with no matching success line"
has "filed on AUTOMERGE_SELF_REPO" "$(issues_opened)" "joshtronic/igor|"
has "assigned to FORGEJO_REVIEWER" "$(cat "$ASSIGNED_LOG")" "-> josh"

echo "== email_send forced to fail -- the Forgejo alarm still fires (the circular dependency is broken) =="
# email_send above is ALREADY stubbed to always return 1. The scenario just
# ran end-to-end through that stub and still produced a Forgejo issue --
# this assertion makes the point explicit rather than merely implicit in
# every other scenario passing.
eq "an alarm was filed even though email_send() unconditionally fails" "1" \
  "$(issues_opened_count)"

echo "== genuine send: stamp + success line -> no alarm =="
reset_state
JOURNAL_FIXTURE="Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: sent (2 shipped, 0 needs-you, 1 in-flight, 0 landed, 0 judgment item(s)) to a@b.com"
cat > "$AGENT_STATE_DIR/discretionary-state.json" <<EOF
{"shipreport": {"date": "$YEST", "sent": true, "failures": 0}}
EOF
do_emailwatch_tick >/dev/null 2>"$TMP/err2.log"
eq "a genuine send raises no alarm" "0" "$(issues_opened_count)"

echo "== a genuinely quiet day (mark_sent with no email at all) is also clean =="
reset_state
JOURNAL_FIXTURE="Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: quiet 24h -- nothing to report (stamping done)"
cat > "$AGENT_STATE_DIR/discretionary-state.json" <<EOF
{"shipreport": {"date": "$YEST", "sent": true, "failures": 0}}
EOF
do_emailwatch_tick >/dev/null 2>"$TMP/err2b.log"
eq "a genuinely quiet day raises no alarm" "0" "$(issues_opened_count)"

echo "== the stamp removed entirely (job never ran) -> alarms =="
reset_state
JOURNAL_FIXTURE=""
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"
do_emailwatch_tick >/dev/null 2>"$TMP/err3.log"
eq "one alarm for the missing shipreport stamp" "1" "$(issues_opened_count)"
has "names it as not having sent" "$(issues_opened)" "shipreport: did not send for"

echo "== an unconfigured (opted-out) surface with NO stamp raises nothing =="
reset_state
unset PRIMARY_RECIPIENTS SMTP2GO_API_KEY SMTP2GO_SENDER
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"
do_emailwatch_tick >/dev/null 2>"$TMP/err4.log"
eq "no creds configured -> no alarm for either surface" "0" "$(issues_opened_count)"
PRIMARY_RECIPIENTS="a@b.com"; SMTP2GO_API_KEY="k"; SMTP2GO_SENDER="s@b.com"

echo "== .market: retired, known-vestigial -- skipped, never alarmed =="
reset_state
JOURNAL_FIXTURE="Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: quiet 24h -- nothing to report (stamping done)"
cat > "$AGENT_STATE_DIR/discretionary-state.json" <<EOF
{"shipreport": {"date": "$YEST", "sent": true}, "market": {"date": "2026-06-29", "sent": true}}
EOF
do_emailwatch_tick >/dev/null 2>"$TMP/err5.log"
eq "only the clean shipreport surface was even considered; market never alarms" "0" \
  "$(issues_opened_count)"
has "market's retirement is logged, not silent" "$(cat "$TMP/err5.log")" "market is a known-retired surface"

echo "== an unregistered surface (nobody taught emailwatch about it) -- alarms loudly, not silently =="
reset_state
JOURNAL_FIXTURE="Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: quiet 24h -- nothing to report (stamping done)"
cat > "$AGENT_STATE_DIR/discretionary-state.json" <<EOF
{"shipreport": {"date": "$YEST", "sent": true}, "newsletter": {"date": "$YEST", "sent": true}}
EOF
do_emailwatch_tick >/dev/null 2>"$TMP/err6.log"
eq "exactly one alarm, for the unregistered surface" "1" "$(issues_opened_count)"
has "names it unregistered" "$(issues_opened)" "newsletter: unregistered daily-email surface"

echo "== journalctl unavailable -- the pass says so loudly, not 'all clear' =="
reset_state
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"
unset PRIMARY_RECIPIENTS SMTP2GO_API_KEY SMTP2GO_SENDER
# Shadow the `command` builtin so `command -v journalctl` reports absent,
# without touching PATH (which every other tool here still needs).
command() {
  if [ "$1" = "-v" ] && [ "$2" = "journalctl" ]; then return 1; fi
  builtin command "$@"
}
do_emailwatch_tick >/dev/null 2>"$TMP/err7.log"
unset -f command
eq "no journalctl -> exactly one alarm about the blindness itself" "1" \
  "$(issues_opened_count)"
has "names the actual gap" "$(issues_opened)" "journalctl unavailable"
# Read only by the eval'd emailwatch_*_opted_in -- static analysis can't see
# through the eval. Restored here so the remaining scenarios below (which
# rely on the shipreport surface actually being checked) opt back in.
# shellcheck disable=SC2034
PRIMARY_RECIPIENTS="a@b.com"
# shellcheck disable=SC2034
SMTP2GO_API_KEY="k"
# shellcheck disable=SC2034
SMTP2GO_SENDER="s@b.com"

echo "== state file unreadable -- alarms instead of reading as 'all clear' =="
reset_state
printf '{not valid json' > "$AGENT_STATE_DIR/discretionary-state.json"
do_emailwatch_tick >/dev/null 2>"$TMP/err8.log"
eq "unparseable state -> exactly one alarm" "1" "$(issues_opened_count)"
has "names the actual gap" "$(issues_opened)" "state file unreadable"

echo "== dedup: an already-open alarm for today is not refiled =="
reset_state
JOURNAL_FIXTURE=""
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"
FIND_MARKED_RESULT='{"number": 42, "state": "open"}'
do_emailwatch_tick >/dev/null 2>"$TMP/err9.log"
eq "the existing open issue short-circuits filing" "0" "$(issues_opened_count)"
eq "dedup lookup was actually consulted" "1" "$(wc -l < "$FIND_MARKED_CALLED_LOG" | tr -d " ")"

echo "== the once-daily gate: a second call the same day is a no-op, not a re-check =="
reset_state
JOURNAL_FIXTURE=""
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"
do_emailwatch_tick >/dev/null 2>"$TMP/err10a.log"
FIRST_COUNT=$(issues_opened_count)
do_emailwatch_tick >/dev/null 2>"$TMP/err10b.log"
RC2=$?
eq "the second same-day call returns 1 (no work)" "1" "$RC2"
eq "no new alarm on the second call" "$FIRST_COUNT" "$(issues_opened_count)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-emailwatch-tick: all checks passed"
else
  echo "test-emailwatch-tick: $FAIL FAILED"
  exit 1
fi
