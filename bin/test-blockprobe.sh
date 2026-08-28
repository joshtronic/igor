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

Josh needs to pick an approach before this can continue.

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

echo "== do_blockprobe_tick: end-to-end sweep over stubbed Forgejo =="

# Common stubs. Each scenario below overrides what it needs and resets captures.
log() { :; }
REMOVED=""; UNASSIGNED=""; COMMENTS=""; ASSIGNED=""
forgejo_remove_label() { REMOVED="$REMOVED $1#$2:$3"; }
forgejo_unassign_all()  { UNASSIGNED="$UNASSIGNED $1#$2"; }
forgejo_comment()       { COMMENTS="$COMMENTS|$1#$2:$3"; }
forgejo_assign()        { ASSIGNED="$ASSIGNED $1#$2->$3"; }
forgejo_pr_has_comment_containing() { printf '0'; }
# shellcheck disable=SC2034  # read by do_blockprobe_tick (lib/blockprobe.sh)
ANALYSIS_REPOS_JSON='{"full_name":"acme/x"}'

_reset_capture() { REMOVED=""; UNASSIGNED=""; COMMENTS=""; ASSIGNED=""; }
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
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 10 "$MECH_BODY"
  else
    _no_issues
  fi
}
forgejo_get_issue() { printf '{"state":"closed"}'; }   # #537 landed -> probe fails
do_blockprobe_tick
has  "cleared: Status/Blocked removed"  "$REMOVED" "acme/x#10:Status/Blocked"
has  "cleared: unassigned"              "$UNASSIGNED" "acme/x#10"
has  "cleared: comment posted"          "$COMMENTS" "acme/x#10"
eq   "cleared: no escalation assignment" "" "$ASSIGNED"

echo "-- scenario: probe still holds -> left untouched --"
_reset_capture
_fj() {
  if [ "$1 $2" = "GET /repos/acme/x/issues?state=open&type=issues&labels=Status/Blocked&limit=50" ]; then
    _issues_payload 11 "$MECH_BODY"
  else
    _no_issues
  fi
}
forgejo_get_issue() { printf '{"state":"open"}'; }     # #537 still open -> probe holds
do_blockprobe_tick
eq "holds: label untouched"    "" "$REMOVED"
eq "holds: not unassigned"     "" "$UNASSIGNED"
eq "holds: no comment"         "" "$COMMENTS"

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

if [ "$FAIL" -eq 0 ]; then
  echo "test-blockprobe: all checks passed"
else
  echo "test-blockprobe: $FAIL FAILED"
  exit 1
fi
