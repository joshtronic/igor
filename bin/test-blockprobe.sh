#!/usr/bin/env bash
# Unit tests for lib/blockprobe.sh -- the block-probe sweep (igor#546).
#
# A `Status/Blocked` label is prose: it asserts a condition and can never go
# red when that condition stops holding. This sweep re-evaluates a MACHINE-
# CHECKABLE probe recorded alongside the block reason and clears the label
# when the probe says the cause is gone. Skip-safe: exits 0 with a notice if
# jq is missing. No network -- every Forgejo/automerge boundary is stubbed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/blockprobe.sh
. "$HERE/lib/blockprobe.sh"

command -v jq >/dev/null 2>&1 || { echo "test-blockprobe: jq unavailable -- skipping"; exit 0; }

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

# _issues_payload <number> <body> -- one fake issues-list response, JSON
# built via jq so an embedded newline/quote in <body> can never produce
# invalid JSON (a hand-escaped "\n" inside a printf format string would be
# expanded by printf itself before jq ever saw it).
_issues_payload() {
  jq -cn --argjson n "$1" --arg b "$2" '[{number:$n, body:$b}]'
}

echo "== probe block parsing =="

BODY_MECH='Blocked on igor#537 landing.

---
## Blocked (2026-08-20 01:26Z)

Waiting on igor#537 to merge before this can proceed.

<!-- probe
kind: issue-open
ref: joshtronic/igor#537
-->'

eq "extracts kind"   "issue-open" "$(blockprobe_parse_kind "$BODY_MECH")"
eq "extracts ref"    "joshtronic/igor#537" "$(blockprobe_parse_ref "$BODY_MECH")"
eq "extracts reason" "Waiting on igor#537 to merge before this can proceed." "$(blockprobe_last_reason "$BODY_MECH")"

eq "no probe block -> empty kind" "" "$(blockprobe_parse_kind "just a normal blocked body, no probe here")"

OPBODY='---
## Blocked (2026-08-20 01:26Z)

The operator needs to pick an approach before this can continue.

<!-- probe
kind: operator
-->'
eq "operator kind parses" "operator" "$(blockprobe_parse_kind "$OPBODY")"

# Only the LATEST probe block matters -- an earlier block's stale probe must
# not override a later, corrected one.
TWOBLOCK='---
## Blocked (2026-08-19 10:00Z)

first reason

<!-- probe
kind: issue-open
ref: joshtronic/igor#500
-->

---
## Blocked (2026-08-20 01:26Z)

second reason

<!-- probe
kind: pr-behind
ref: joshtronic/repo#147
-->'
eq "latest probe kind wins" "pr-behind" "$(blockprobe_parse_kind "$TWOBLOCK")"
eq "latest probe ref wins"  "joshtronic/repo#147" "$(blockprobe_parse_ref "$TWOBLOCK")"
eq "latest reason wins"     "second reason" "$(blockprobe_last_reason "$TWOBLOCK")"

# Probe args are OPTIONAL, so "earlier block probed, latest one not" is the
# EXPECTED shape, not an exotic edge case. Reading the probe from anywhere in
# the body while reading the reason from the latest section makes the two
# disagree, and the sweep would then clear a ticket on a condition nobody
# currently means -- exactly the "probe that tests a condition nobody meant"
# failure igor#546 exists to avoid.
MIXED='---
## Blocked (2026-08-19 10:00Z)

first reason

<!-- probe
kind: issue-open
ref: joshtronic/igor#500
-->

---
## Blocked (2026-08-20 01:26Z)

second reason, recorded with no probe at all'
eq "latest block unprobed -> no kind" "" "$(blockprobe_parse_kind "$MIXED")"
eq "latest block unprobed -> no ref"  "" "$(blockprobe_parse_ref "$MIXED")"
eq "latest block unprobed -> latest reason" \
   "second reason, recorded with no probe at all" "$(blockprobe_last_reason "$MIXED")"

echo "== last-confirmed stamp: parse + the pure body transform =="
# igor#546 asks that a probe which still HOLDS record when it was last
# confirmed. The tick log is ephemeral, so the stamp rides in the body next
# to the probe it confirms -- a body PATCH, which (unlike a comment) notifies
# nobody and stays exactly one line however long the block holds.

eq "no stamp yet -> empty" "" "$(blockprobe_parse_confirmed "$BODY_MECH")"

STAMPED=$(blockprobe_body_with_confirmation "$BODY_MECH" "2026-08-28")
eq "stamped body parses the date back"      "2026-08-28" "$(blockprobe_parse_confirmed "$STAMPED")"
eq "stamping preserves the probe kind"      "issue-open" "$(blockprobe_parse_kind "$STAMPED")"
eq "stamping preserves the probe ref"       "joshtronic/igor#537" "$(blockprobe_parse_ref "$STAMPED")"
eq "stamping preserves the human reason"    "Waiting on igor#537 to merge before this can proceed." \
   "$(blockprobe_last_reason "$STAMPED")"

# The stamp is REPLACED, never appended to: a block held for a month must not
# accumulate 30 confirmed: lines in the issue description.
RESTAMPED=$(blockprobe_body_with_confirmation "$STAMPED" "2026-09-04")
eq "re-stamping replaces the old date"  "2026-09-04" "$(blockprobe_parse_confirmed "$RESTAMPED")"
eq "re-stamping leaves exactly one stamp" "1" \
   "$(grep -c 'confirmed:' <<<"$RESTAMPED")"

# Only the LATEST block's probe is stamped -- same rule the rest of the file
# follows, so an earlier block's stale probe can't collect a fresh date that
# reads as "this is what we re-confirmed".
TWO_STAMPED=$(blockprobe_body_with_confirmation "$TWOBLOCK" "2026-08-28")
eq "two blocks: only one stamp written" "1" "$(grep -c 'confirmed:' <<<"$TWO_STAMPED")"
eq "two blocks: the stamp lands on the LATEST probe" "2026-08-28" \
   "$(blockprobe_parse_confirmed "$TWO_STAMPED")"
eq "two blocks: the earlier probe is untouched" "issue-open
ref: joshtronic/igor#500" \
   "$(sed -n '/kind: issue-open/,/ref:/p' <<<"$TWO_STAMPED" | sed 's/^kind: //' | head -2)"

eq "a body with no probe at all is refused (rc 1)" "1" \
   "$(blockprobe_body_with_confirmation "no probe here" "2026-08-28" >/dev/null 2>&1; echo $?)"

echo "== spent stamp: a probe the sweep acted on can never fire again =="
# Without this the probe outlives the episode it describes: it evaluates
# CLEARED forever, so the next Status/Blocked applied WITHOUT a new
# "## Blocked (...)" section -- a human labelling the ticket by hand -- gets
# stripped on the next tick on a condition from an episode that is over.

eq "live probe -> no cleared stamp" "" "$(blockprobe_parse_cleared "$BODY_MECH")"

SPENT=$(blockprobe_body_with_cleared "$BODY_MECH" "2026-08-28")
eq "spent body parses the date back"   "2026-08-28" "$(blockprobe_parse_cleared "$SPENT")"
eq "spending preserves the probe kind" "issue-open" "$(blockprobe_parse_kind "$SPENT")"
eq "spending preserves the human reason" "Waiting on igor#537 to merge before this can proceed." \
   "$(blockprobe_last_reason "$SPENT")"

# The two stamps are independent fields: a probe that held for weeks and then
# cleared keeps both dates, so the ticket records the whole hold, not just its
# end.
BOTH=$(blockprobe_body_with_cleared "$STAMPED" "2026-08-28")
eq "spending leaves the confirmation stamp alone" "2026-08-28" "$(blockprobe_parse_confirmed "$BOTH")"
eq "spending adds its own stamp beside it"        "2026-08-28" "$(blockprobe_parse_cleared "$BOTH")"

echo "== repeat-block guard: exact-reason occurrence counting =="
REPEATED='---
## Blocked (2026-08-20 01:26Z)

scope count was wrong when written

---
## Blocked (2026-08-20 01:42Z)

scope count was wrong when written

---
## Blocked (2026-08-20 02:00Z)

scope count was wrong when written'
eq "reason seen 3 times" "3" "$(blockprobe_reason_repeat_count "$REPEATED" "scope count was wrong when written")"
eq "unrelated reason seen 0 times" "0" "$(blockprobe_reason_repeat_count "$REPEATED" "a totally different reason")"
eq "empty reason -> 0" "0" "$(blockprobe_reason_repeat_count "$REPEATED" "")"

echo "== blockprobe_evaluate: dispatch + malformed ref =="
forgejo_get_issue() { printf '{"state":"open"}'; }
eq "issue-open, ref open -> HOLDS" "HOLDS" "$(blockprobe_evaluate issue-open joshtronic/igor#537)"
forgejo_get_issue() { printf '{"state":"closed"}'; }
eq "issue-open, ref closed -> CLEARED" "CLEARED" "$(blockprobe_evaluate issue-open joshtronic/igor#537)"
forgejo_get_issue() { return 1; }
eq "issue-open, fetch fails -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate issue-open joshtronic/igor#537)"
eq "malformed ref (no #) -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate issue-open "not-a-ref")"
eq "unrecognized kind -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate made-up-kind joshtronic/igor#537)"

# The ref is interpolated straight into an API path, so its shape is checked
# rather than merely assumed: anything that isn't <owner>/<repo>#<digits> is
# UNKNOWN and never reaches a request.
forgejo_get_issue() { printf '{"state":"closed"}'; }
eq "ref with no owner -> UNKNOWN"     "UNKNOWN" "$(blockprobe_evaluate issue-open "igor#537")"
eq "ref with extra path -> UNKNOWN"   "UNKNOWN" "$(blockprobe_evaluate issue-open "a/b/c#537")"
eq "ref with traversal -> UNKNOWN"    "UNKNOWN" "$(blockprobe_evaluate issue-open "../evil#537")"
eq "ref with non-numeric num -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate issue-open "acme/x#537?foo=1")"
eq "well-formed ref still evaluates"  "CLEARED" "$(blockprobe_evaluate issue-open "acme/x#537")"

automerge_behind_count() { printf '0'; }
eq "pr-behind, 0 behind -> CLEARED" "CLEARED" "$(blockprobe_evaluate pr-behind joshtronic/repo#147)"
automerge_behind_count() { printf '3'; }
eq "pr-behind, 3 behind -> HOLDS" "HOLDS" "$(blockprobe_evaluate pr-behind joshtronic/repo#147)"
automerge_behind_count() { printf -- '-1'; }
eq "pr-behind, undetermined -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate pr-behind joshtronic/repo#147)"
# Any negative count is "couldn't tell", not "behind": -1 is the documented
# sentinel, but a different negative must not fall through to HOLDS.
automerge_behind_count() { printf -- '-5'; }
eq "pr-behind, other negative -> UNKNOWN" "UNKNOWN" "$(blockprobe_evaluate pr-behind joshtronic/repo#147)"

echo "== blockprobe_evaluate: kind transient (igor#555) -- always CLEARED, no ref needed =="
# transient has no external condition to poll (e.g. a security gate that
# never produced a verdict): it always evaluates CLEARED so a block records
# with it requeues on the very next sweep, with no ref at all.
eq "transient, no ref -> CLEARED" "CLEARED" "$(blockprobe_evaluate transient "")"
eq "transient, a ref present anyway -> still CLEARED (ref is ignored)" "CLEARED" \
   "$(blockprobe_evaluate transient joshtronic/igor#537)"
# And it never touches the network to get there.
forgejo_get_issue() { echo "forgejo_get_issue should not be called for kind transient" >&2; return 1; }
automerge_behind_count() { echo "automerge_behind_count should not be called for kind transient" >&2; return 1; }
NOCALL_ERR=$(blockprobe_evaluate transient "" 2>&1 1>/dev/null)
eq "transient never calls forgejo_get_issue or automerge_behind_count" "" "$NOCALL_ERR"

echo "== do_blockprobe_tick: end-to-end sweep over stubbed Forgejo =="

# Common stubs. Each scenario below overrides what it needs and resets captures.
log() { :; }
REMOVED=""; UNASSIGNED=""; COMMENTS=""; ASSIGNED=""; PATCHED=""
forgejo_remove_label() { REMOVED="$REMOVED $1#$2:$3"; }
forgejo_unassign_all()  { UNASSIGNED="$UNASSIGNED $1#$2"; }
forgejo_comment()       { COMMENTS="$COMMENTS|$1#$2:$3"; }
forgejo_assign()        { ASSIGNED="$ASSIGNED $1#$2->$3"; }
forgejo_pr_has_comment_containing() { printf '0'; }
# shellcheck disable=SC2034  # read by do_blockprobe_tick (lib/blockprobe.sh)
ANALYSIS_REPOS_JSON='{"full_name":"acme/x"}'

_reset_capture() { REMOVED=""; UNASSIGNED=""; COMMENTS=""; ASSIGNED=""; PATCHED=""; }
_no_issues() { printf '[]'; }

echo "-- scenario: probe fails (cause resolved) -> cleared, unassigned, commented --"
_reset_capture
MECH_BODY='---
## Blocked (2026-08-20 01:26Z)

Waiting on igor#537 to merge.

<!-- probe
kind: issue-open
ref: joshtronic/igor#537
-->'
TODAY=$(date -u '+%Y-%m-%d')
# EPISODE_BODY is the ticket's live body: the fake PATCH writes back to it, so
# a second sweep below sees what the first one actually left behind.
EPISODE_BODY="$MECH_BODY"
_episode_fj() {
  case "$1 $2" in
    "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50")
      _issues_payload 10 "$EPISODE_BODY" ;;
    "PATCH /repos/acme/x/issues/10")
      PATCHED="$3"; EPISODE_BODY=$(jq -r '.body' <<<"$3") ;;
    *) _no_issues ;;
  esac
}
# The blocked TICKET answers with a full issue object (the spent-stamp does a
# read-modify-write on its body); the probe's REF (#537) answers with a state.
_episode_get_issue() {
  case "$1#$2" in
    acme/x#10) jq -cn --arg b "$EPISODE_BODY" '{number:10, body:$b, state:"open"}' ;;
    *)         printf '{"state":"closed"}' ;;   # #537 landed -> probe fails
  esac
}
_fj() { _episode_fj "$@"; }
forgejo_get_issue() { _episode_get_issue "$@"; }
do_blockprobe_tick
has  "cleared: Status/Blocked removed"  "$REMOVED" "acme/x#10:Status/Blocked"
has  "cleared: unassigned"              "$UNASSIGNED" "acme/x#10"
has  "cleared: comment posted"          "$COMMENTS" "acme/x#10"
eq   "cleared: no escalation assignment" "" "$ASSIGNED"
eq   "cleared: the probe is stamped spent" "$TODAY" "$(blockprobe_parse_cleared "$EPISODE_BODY")"

echo "-- scenario: a SPENT probe cannot clear a later, unrelated block --"
# Second episode, same ticket: something re-applies Status/Blocked and writes
# NOTHING to the body (a human labelling it by hand). The old probe is still
# there and still evaluates CLEARED. Before the spent stamp, this sweep undid
# the human's label within a tick and cited a condition from the episode above.
_reset_capture
UNPROBED_SEEN=0
log() { case "$*" in *"UNPROBED"*) UNPROBED_SEEN=1 ;; esac; }
do_blockprobe_tick
log() { :; }
eq "spent probe: reported UNPROBED"        "1" "$UNPROBED_SEEN"
eq "spent probe: label untouched"          "" "$REMOVED"
eq "spent probe: not unassigned"           "" "$UNASSIGNED"
eq "spent probe: no comment"               "" "$COMMENTS"
eq "spent probe: nothing written back"     "" "$PATCHED"

echo "-- scenario: the spent-stamp write fails -> the label is NOT cleared --"
# Fail closed. Clearing the label while the probe stays live is exactly the bug
# above, so a stamp that cannot land keeps the ticket blocked and retries.
_reset_capture
EPISODE_BODY="$MECH_BODY"
forgejo_get_issue() { case "$1#$2" in acme/x#10) return 1 ;; *) printf '{"state":"closed"}' ;; esac; }
do_blockprobe_tick
eq "spent-stamp write fails: label untouched" "" "$REMOVED"
eq "spent-stamp write fails: not unassigned"  "" "$UNASSIGNED"
eq "spent-stamp write fails: no comment"      "" "$COMMENTS"

echo "-- scenario: probe still holds -> left untouched, confirmation stamped --"
_reset_capture
# One stub for two callers: blockprobe_eval_issue_open fetches the PROBE'S REF
# (#537), blockprobe_record_confirmation re-fetches the BLOCKED TICKET itself
# (#11) before rewriting its body -- so the ref answers with a state and the
# ticket answers with a full issue object.
_holds_get_issue() {
  case "$1#$2" in
    acme/x#11) jq -cn --arg b "$HOLDS_BODY" '{number:11, body:$b, state:"open"}' ;;
    *)         printf '{"state":"open"}' ;;   # #537 still open -> probe holds
  esac
}
_holds_fj() {
  case "$1 $2" in
    "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50")
      _issues_payload 11 "$HOLDS_BODY" ;;
    "PATCH /repos/acme/x/issues/11") PATCHED="$3" ;;
    *) _no_issues ;;
  esac
}
HOLDS_BODY="$MECH_BODY"
_fj() { _holds_fj "$@"; }
forgejo_get_issue() { _holds_get_issue "$@"; }
do_blockprobe_tick
eq "holds: label untouched"    "" "$REMOVED"
eq "holds: not unassigned"     "" "$UNASSIGNED"
eq "holds: no comment"         "" "$COMMENTS"
eq "holds: today's confirmation stamped into the body" "$TODAY" \
   "$(blockprobe_parse_confirmed "$(jq -r '.body' <<<"$PATCHED")")"

echo "-- scenario: still holding, already confirmed today -> no repeat write --"
# The sweep runs every tick; without this throttle a single held block would
# PATCH its own body ~1440 times a day.
_reset_capture
HOLDS_BODY=$(blockprobe_body_with_confirmation "$MECH_BODY" "$TODAY")
do_blockprobe_tick
eq "holds: same-day re-confirmation writes nothing" "" "$PATCHED"

echo "-- scenario: still holding, confirmed on an EARLIER day -> re-stamped --"
_reset_capture
HOLDS_BODY=$(blockprobe_body_with_confirmation "$MECH_BODY" "2001-01-01")
do_blockprobe_tick
eq "holds: a stale stamp is refreshed to today" "$TODAY" \
   "$(blockprobe_parse_confirmed "$(jq -r '.body' <<<"$PATCHED")")"

echo "-- scenario: the probe vanished between the list read and the re-fetch --"
# The HOLDS verdict came from the LIST body; the stamp is written against the
# RE-FETCHED one. If the latest block lost its probe in between, stamping
# would land a fresh date on an EARLIER block's probe -- a confirmation of a
# condition nobody currently means.
_reset_capture
HOLDS_BODY="$MECH_BODY"
forgejo_get_issue() {
  case "$1#$2" in
    acme/x#11) jq -cn --arg b "$MIXED" '{number:11, body:$b, state:"open"}' ;;
    *)         printf '{"state":"open"}' ;;
  esac
}
do_blockprobe_tick
eq "probe vanished mid-sweep: nothing stamped" "" "$PATCHED"
eq "probe vanished mid-sweep: label untouched" "" "$REMOVED"

echo "-- scenario: the confirmation write fails -> block still left alone --"
# The stamp is bookkeeping, not a gate: a PATCH that can't land must never
# turn into a cleared label or a lost block.
_reset_capture
HOLDS_BODY="$MECH_BODY"
forgejo_get_issue() { case "$1#$2" in acme/x#11) return 1 ;; *) printf '{"state":"open"}' ;; esac; }
do_blockprobe_tick
eq "stamp write fails: label untouched" "" "$REMOVED"
eq "stamp write fails: no comment"      "" "$COMMENTS"

echo "-- scenario: no probe recorded -> UNPROBED, not cleared --"
_reset_capture
NOPROBE_BODY='---
## Blocked (2026-08-20 01:26Z)

Some vague reason with no probe recorded.'
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 12 "$NOPROBE_BODY"
  else
    _no_issues
  fi
}
UNPROBED_SEEN=0
log() { case "$*" in *"UNPROBED"*) UNPROBED_SEEN=1 ;; esac; }
do_blockprobe_tick
eq "unprobed: reported via log"  "1" "$UNPROBED_SEEN"
eq "unprobed: label untouched"   "" "$REMOVED"
eq "unprobed: no comment"        "" "$COMMENTS"
log() { :; }

echo "-- scenario: earlier block probed, latest one not -> UNPROBED, not cleared --"
_reset_capture
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 17 "$MIXED"
  else
    _no_issues
  fi
}
forgejo_get_issue() { printf '{"state":"closed"}'; }   # the STALE probe's ref did close
UNPROBED_SEEN=0
log() { case "$*" in *"UNPROBED"*) UNPROBED_SEEN=1 ;; esac; }
do_blockprobe_tick
eq "mixed body: reported UNPROBED" "1" "$UNPROBED_SEEN"
eq "mixed body: label untouched"   "" "$REMOVED"
eq "mixed body: no comment"        "" "$COMMENTS"
log() { :; }

echo "-- scenario: operator-decision block -> never auto-requeued --"
_reset_capture
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 13 "$OPBODY"
  else
    _no_issues
  fi
}
do_blockprobe_tick
eq "operator: label untouched" "" "$REMOVED"
eq "operator: no comment"      "" "$COMMENTS"

echo "-- scenario: transient block (igor#555) -- self-clears on the very next sweep --"
# The motivating case: a security gate that produced no verdict at all
# (fail-closed) has no external condition to poll, so the probe always
# evaluates CLEARED and the ticket is requeued unconditionally.
#
# blockprobe_evaluate itself never calls forgejo_get_issue for kind
# transient (asserted directly above), but do_blockprobe_tick's CLEARED
# path still re-fetches the TICKET's own body to stamp the probe spent
# (_blockprobe_record_stamp) -- so forgejo_get_issue must answer for the
# ticket number, same shape as the "probe fails (cause resolved)" scenario.
_reset_capture
TRANSIENT_BODY='---
## Blocked (2026-08-28 01:26Z)

The harness security review could not produce a verdict, so this change was NOT pushed.

<!-- probe
kind: transient
-->'
_fj() {
  case "$1 $2" in
    "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50")
      _issues_payload 18 "$TRANSIENT_BODY" ;;
    "PATCH /repos/acme/x/issues/18") : ;;
    *) _no_issues ;;
  esac
}
forgejo_get_issue() { jq -cn --arg b "$TRANSIENT_BODY" '{number:18, body:$b, state:"open"}'; }
do_blockprobe_tick
has "transient: Status/Blocked removed"  "$REMOVED" "acme/x#18:Status/Blocked"
has "transient: unassigned"              "$UNASSIGNED" "acme/x#18"
has "transient: comment posted"          "$COMMENTS" "acme/x#18"
eq  "transient: no escalation assignment" "" "$ASSIGNED"

echo "-- scenario: same TRANSIENT reason blocking 3x -> escalate, not requeue forever --"
# Boundedness comes from the existing repeat-block guard, not a second retry
# counter: a security gate that keeps failing the same way must not requeue
# indefinitely, so the identical reason accumulating across requeue cycles
# trips the same escalation a mechanical probe would.
_reset_capture
TRANSIENT_REPEAT_BODY='---
## Blocked (2026-08-28 01:00Z)

The harness security review could not produce a verdict, so this change was NOT pushed.

<!-- probe
kind: transient
-->

---
## Blocked (2026-08-28 01:05Z)

The harness security review could not produce a verdict, so this change was NOT pushed.

<!-- probe
kind: transient
-->

---
## Blocked (2026-08-28 01:10Z)

The harness security review could not produce a verdict, so this change was NOT pushed.

<!-- probe
kind: transient
-->'
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 19 "$TRANSIENT_REPEAT_BODY"
  else
    _no_issues
  fi
}
# shellcheck disable=SC2034  # read by do_blockprobe_tick (lib/blockprobe.sh)
FORGEJO_REVIEWER="josh"
do_blockprobe_tick
eq   "transient escalate: label NOT removed" "" "$REMOVED"
eq   "transient escalate: not unassigned"    "" "$UNASSIGNED"
has  "transient escalate: comment posted"    "$COMMENTS" "acme/x#19"
has  "transient escalate: reviewer assigned" "$ASSIGNED" "acme/x#19->josh"
unset FORGEJO_REVIEWER

echo "-- scenario: same reason blocking 3x -> escalate, not requeue --"
_reset_capture
REPEAT_BODY='---
## Blocked (2026-08-20 01:26Z)

scope count was wrong when written

<!-- probe
kind: issue-open
ref: joshtronic/igor#500
-->

---
## Blocked (2026-08-20 01:42Z)

scope count was wrong when written

<!-- probe
kind: issue-open
ref: joshtronic/igor#500
-->

---
## Blocked (2026-08-20 02:00Z)

scope count was wrong when written

<!-- probe
kind: issue-open
ref: joshtronic/igor#500
-->'
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 14 "$REPEAT_BODY"
  else
    _no_issues
  fi
}
forgejo_get_issue() { printf '{"state":"closed"}'; }   # probe would otherwise clear
# shellcheck disable=SC2034  # read by do_blockprobe_tick (lib/blockprobe.sh)
FORGEJO_REVIEWER="josh"
do_blockprobe_tick
eq   "escalate: label NOT removed"       "" "$REMOVED"
eq   "escalate: not unassigned"          "" "$UNASSIGNED"
has  "escalate: comment posted"          "$COMMENTS" "acme/x#14"
has  "escalate: reviewer assigned"       "$ASSIGNED" "acme/x#14->josh"

echo "-- scenario: escalation comment is not re-posted every sweep (dedup) --"
_reset_capture
forgejo_pr_has_comment_containing() { printf '1'; }   # already escalated
do_blockprobe_tick
eq "escalate dedup: no duplicate comment" "" "$COMMENTS"
eq "escalate dedup: no duplicate assign"  "" "$ASSIGNED"
forgejo_pr_has_comment_containing() { printf '0'; }
unset FORGEJO_REVIEWER

echo "-- negative test: sever probe evaluation -> stale ticket stays blocked --"
_reset_capture
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 15 "$MECH_BODY"
  else
    _no_issues
  fi
}
# Sever the evaluation seam: even though the real cause resolved (closed),
# a transport failure means blockprobe_evaluate cannot know that -- fail
# closed, proving the SWEEP (not something else) is what clears a ticket.
forgejo_get_issue() { return 1; }
do_blockprobe_tick
eq "severed evaluation: label untouched (fails closed)" "" "$REMOVED"
eq "severed evaluation: no comment"                      "" "$COMMENTS"

echo "== deferred-gated tickets are left to lib/deferred.sh =="
_reset_capture
GATE_BODY='<!-- gate
url: https://example.test/x
condition: something happened
-->'
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 16 "$GATE_BODY"
  else
    _no_issues
  fi
}
do_blockprobe_tick
eq "gate-block ticket: untouched by blockprobe" "" "$REMOVED"

echo "== the analysis set really is newline-delimited objects =="
# do_blockprobe_tick reads ANALYSIS_REPOS_JSON line by line, which the stubs
# above supply themselves -- so if tick.sh ever built an ARRAY instead, each
# line would be "[" / "  {" and never a repo, the sweep would go blind
# fleet-wide, and this suite would stay green. Assert the real construction.
if grep -qF "ANALYSIS_REPOS_JSON=\$(jq -c '.[]' <<<\"\$ALL_REPOS\")" "$HERE/bin/tick.sh"; then
  printf '  + %s\n' "tick.sh builds ANALYSIS_REPOS_JSON as newline-delimited objects"
else
  printf '  x %s\n' "tick.sh no longer builds ANALYSIS_REPOS_JSON as \`jq -c '.[]'\` -- do_blockprobe_tick's line-by-line read is broken"
  FAIL=$((FAIL + 1))
fi

echo "== BOT_USER is guaranteed by tick.sh, not hoped for =="
# blockprobe_escalate dedups by comment AUTHOR. Every scenario above stubs
# forgejo_pr_has_comment_containing, so an unset BOT_USER would match nothing,
# re-post the escalation comment every tick, and leave this suite green --
# spam on exactly the tickets the repeat-block guard exists to quiet. The
# guarantee lives in tick.sh; assert it there, like ANALYSIS_REPOS_JSON above.
if grep -qF 'BOT_USER=$(forgejo_resolve_bot_user) || BOT_USER=""' "$HERE/bin/tick.sh" \
   && grep -qF '[ -n "$BOT_USER" ] || {' "$HERE/bin/tick.sh"; then
  printf '  + %s\n' "tick.sh resolves BOT_USER and hard-exits when it is empty"
else
  printf '  x %s\n' "tick.sh no longer guarantees a non-empty BOT_USER -- blockprobe_escalate's dedup fails OPEN"
  FAIL=$((FAIL + 1))
fi

echo "== the two cross-library helpers PRINT their result (not an exit status) =="
# Every scenario above stubs forgejo_pr_has_comment_containing and
# automerge_behind_count with `printf`, so the suite would stay green even if
# the REAL helpers signalled through exit status -- which their predicate-ish
# names invite. That is not cosmetic: blockprobe_escalate reads
# `cnt=$(forgejo_pr_has_comment_containing ...)` and coerces a non-numeric to
# 0, so a status-signalling helper would make the dedup fail OPEN and re-post
# the escalation comment every tick, on exactly the tickets the repeat-block
# guard exists to quiet. Exercise the real definitions against a stubbed
# transport instead. Subshell: sourcing the real libs here would clobber the
# stubs the scenarios above installed.
_real_helper_contract() (
  export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  export AUTOMERGE_SELF_REPO="joshtronic/igor"   # required, no default (igor#558)
  # shellcheck source=../lib/forgejo.sh
  . "$HERE/lib/forgejo.sh"
  # shellcheck source=../lib/automerge.sh
  . "$HERE/lib/automerge.sh"
  _fj() {
    case "$1 $2" in
      "GET /repos/acme/x/issues/7/comments")
        jq -cn '[{user:{login:"igor"},body:"nope"},
                 {user:{login:"igor"},body:"tail <!-- m --> end"},
                 {user:{login:"igor"},body:"<!-- m -->"},
                 {user:{login:"josh"},body:"<!-- m -->"}]' ;;
      "GET /repos/acme/x/pulls/7")   printf '{"head":{"sha":"abc"},"base":{"ref":"master"}}' ;;
      "GET /repos/acme/x/compare/abc...master") printf '{"total_commits":4}' ;;
      *) printf '{}' ;;
    esac
  }
  printf '%s|%s' \
    "$(forgejo_pr_has_comment_containing acme/x 7 igor '<!-- m -->')" \
    "$(automerge_behind_count acme/x 7)"
)
eq "both helpers echo a number on stdout, with the arity blockprobe.sh calls" \
   "2|4" "$(_real_helper_contract)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-blockprobe: all checks passed"
else
  echo "test-blockprobe: $FAIL FAILED"
  exit 1
fi
