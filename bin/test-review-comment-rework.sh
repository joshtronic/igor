#!/usr/bin/env bash
# test-review-comment-rework.sh -- a COMMENT verdict that carries findings
# routes into the same rework loop REQUEST_CHANGES uses, instead of reaching
# the operator unadjudicated (igor#552).
#
# do_review_tick itself needs a network and a model call to reach, so -- same
# lift-the-function pattern test-review-directive.sh and test-review-timeout.sh
# already use -- the functions under test are extracted straight out of
# bin/tick.sh with sed and evaluated here, with every external call (Forgejo,
# review-state, maintenance validation) stubbed to a recording function. That
# proves the routing DECISION, not the plumbing around it -- the plumbing
# (BINDING_RC_BODY-gated rework/adjudication/converge/escalate flow) never
# inspects which verdict produced it (grepped for below), so whatever already
# holds for a REQUEST_CHANGES-triggered rework holds for a COMMENT-triggered
# one too.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-comment-rework: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$2] should lack [$3]" ;; *) ok "$1" ;; esac; }

# Lift the real functions rather than reimplementing them -- a hand-rolled
# copy would happily agree with a routing decision the shipping code doesn't
# make.
lift() {
  local fn="$1" src
  src=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$TICK")
  [ -n "$src" ] || { echo "test-review-comment-rework: could not extract ${fn}() from bin/tick.sh" >&2; exit 1; }
  eval "$src"
}
for fn in review_parse_response review_request_human review_comment_has_findings \
          review_handoff_now review_route_into_rework review_apply_verdict; do
  lift "$fn"
done

# -- stubs: every external call the lifted functions make -------------------
#
# A CALL LOG FILE, not a shell array: review_request_human invokes
# forgejo_request_review through `reason=$( ... )` command substitution, which
# forks a subshell -- an array append inside that stub would mutate only the
# subshell's copy and vanish the moment it exits. A file survives the fork.
CALLLOG=$(mktemp); trap 'rm -f "$CALLLOG"' EXIT
reset_calls() { : > "$CALLLOG"; }
called() { grep -qF -- "$1" "$CALLLOG"; }

log() { :; }
# Read only inside the eval'd function bodies above, which shellcheck can't
# trace through -- both are genuinely consumed (FORGEJO_REVIEWER by
# review_request_human, BOT_USER by review_route_into_rework's forgejo_assign
# call).
# shellcheck disable=SC2034
FORGEJO_REVIEWER="operator"
# shellcheck disable=SC2034
BOT_USER="igor-bot"
AUTOMERGE_WILL_TAKE=1   # 1 = false (do not auto-merge) by default
automerge_will_take() { echo "automerge_will_take $*" >> "$CALLLOG"; return "$AUTOMERGE_WILL_TAKE"; }
forgejo_request_review() { echo "forgejo_request_review $*" >> "$CALLLOG"; return 0; }
forgejo_comment() { echo "forgejo_comment $*" >> "$CALLLOG"; return 0; }
forgejo_assign() { echo "forgejo_assign $*" >> "$CALLLOG"; return 0; }
MAINTENANCE_VALIDATED=0  # 0 = true by default
maintenance_repo_validated() { echo "maintenance_repo_validated $*" >> "$CALLLOG"; return "$MAINTENANCE_VALIDATED"; }
review_reset_rework() { echo "review_reset_rework $*" >> "$CALLLOG"; }
review_set_rework_rounds() { echo "review_set_rework_rounds $*" >> "$CALLLOG"; }
review_set_pending_rc_body() { echo "review_set_pending_rc_body $*" >> "$CALLLOG"; }

echo "== the parser: an optional FINDINGS: line, defaulting to PRESENT (igor#552) =="
P=$(review_parse_response "VERDICT: COMMENT
===BODY===
some review prose")
eq "no FINDINGS line -> defaults to PRESENT" "PRESENT" "$(jq -r '.findings' <<<"$P")"

P=$(review_parse_response "VERDICT: COMMENT
FINDINGS: NONE
===BODY===
clean read, nothing to flag")
eq "FINDINGS: NONE round-trips" "NONE" "$(jq -r '.findings' <<<"$P")"

P=$(review_parse_response "VERDICT: COMMENT
FINDINGS: PRESENT
===BODY===
some review prose")
eq "FINDINGS: PRESENT round-trips" "PRESENT" "$(jq -r '.findings' <<<"$P")"

P=$(review_parse_response "VERDICT: COMMENT
FINDINGS: none
===BODY===
clean read")
eq "a lower-case FINDINGS value still normalizes to NONE" "NONE" "$(jq -r '.findings' <<<"$P")"

P=$(review_parse_response "VERDICT: REQUEST_CHANGES
===BODY===
a real defect")
eq "REQUEST_CHANGES ignores FINDINGS entirely (still PRESENT, unused)" "PRESENT" "$(jq -r '.findings' <<<"$P")"

echo "== review_comment_has_findings: the routing predicate =="
if review_comment_has_findings PRESENT; then ok "PRESENT -> has findings"; else bad "PRESENT -> has findings"; fi
if review_comment_has_findings NONE; then bad "NONE -> no findings"; else ok "NONE -> no findings"; fi
if review_comment_has_findings ""; then ok "missing/empty defaults to has-findings (safe default)"; else bad "missing/empty defaults to has-findings (safe default)"; fi

echo "== a COMMENT with findings enters rework rather than handing over =="
reset_calls
review_apply_verdict acme/repo 10 acme/repo#10 COMMENT PRESENT "some finding" 0
if called "forgejo_assign"; then ok "the bot is assigned (rework)"; else bad "the bot is assigned (rework)"; fi
if called "review_set_pending_rc_body"; then ok "the findings ride in pending_rc_body"; else bad "the findings ride in pending_rc_body"; fi
if called "review_set_rework_rounds acme/repo#10 1"; then ok "rework round bumps to 1"; else bad "rework round bumps to 1"; fi
if called "review_request_human" || called "forgejo_request_review"; then
  bad "the human is NOT asked while rework is pending"
else ok "the human is NOT asked while rework is pending"; fi
if called "review_reset_rework"; then bad "rework state is not reset on entry"; else ok "rework state is not reset on entry"; fi

echo "== a COMMENT with no findings hands over immediately, no extra round =="
reset_calls
review_apply_verdict acme/repo 11 acme/repo#11 COMMENT NONE "nothing wrong here" 0
if called "forgejo_assign"; then bad "the bot is NOT assigned"; else ok "the bot is NOT assigned"; fi
if called "review_set_pending_rc_body"; then bad "no pending_rc_body is set"; else ok "no pending_rc_body is set"; fi
if called "review_set_rework_rounds"; then bad "no rework round is spent"; else ok "no rework round is spent"; fi
if called "review_reset_rework"; then ok "rework state is (re)reset"; else bad "rework state is (re)reset"; fi
if called "forgejo_request_review"; then ok "the human is asked, same tick"; else bad "the human is asked, same tick"; fi

echo "== a COMMENT producing neither commits nor dismissals escalates -- shared cap =="
# rc_rounds=3 is the existing REQUEST_CHANGES escalation threshold
# (review_route_into_rework); a COMMENT with findings reuses the exact same
# function, so it escalates at the same round rather than looping forever.
reset_calls
review_apply_verdict acme/repo 12 acme/repo#12 COMMENT PRESENT "still not fixed" 3
if called "forgejo_assign"; then bad "escalation does not re-assign the bot"; else ok "escalation does not re-assign the bot"; fi
if called "forgejo_request_review"; then ok "escalation hands the PR to the human"; else bad "escalation hands the PR to the human"; fi
if called "review_set_rework_rounds"; then bad "the round count does not advance past the cap"; else ok "the round count does not advance past the cap"; fi

echo "== a COMMENT with findings on an unvalidated repo skips rework, same as REQUEST_CHANGES =="
reset_calls
MAINTENANCE_VALIDATED=1  # false
review_apply_verdict acme/repo 13 acme/repo#13 COMMENT PRESENT "a finding" 0
if called "forgejo_assign"; then bad "no autonomous rework on an unvalidated repo"; else ok "no autonomous rework on an unvalidated repo"; fi
if called "forgejo_request_review"; then ok "the human is asked instead"; else bad "the human is asked instead"; fi
MAINTENANCE_VALIDATED=0

echo "== REQUEST_CHANGES and APPROVE behavior is unchanged =="
reset_calls
review_apply_verdict acme/repo 20 acme/repo#20 REQUEST_CHANGES PRESENT "a real defect" 0
if called "forgejo_assign"; then ok "REQUEST_CHANGES still enters rework"; else bad "REQUEST_CHANGES still enters rework"; fi
if called "review_set_rework_rounds acme/repo#20 1"; then ok "REQUEST_CHANGES still bumps the round the same way"; else bad "REQUEST_CHANGES still bumps the round the same way"; fi

reset_calls
review_apply_verdict acme/repo 21 acme/repo#21 REQUEST_CHANGES PRESENT "still broken" 3
if called "forgejo_request_review"; then ok "REQUEST_CHANGES still escalates at round 3"; else bad "REQUEST_CHANGES still escalates at round 3"; fi

reset_calls
review_apply_verdict acme/repo 22 acme/repo#22 APPROVE PRESENT "looks good" 2
if called "review_reset_rework"; then ok "APPROVE still resets rework state"; else bad "APPROVE still resets rework state"; fi
if called "forgejo_assign"; then bad "APPROVE never enters rework"; else ok "APPROVE never enters rework"; fi
if called "forgejo_request_review"; then ok "APPROVE still asks the human when auto-merge won't take it"; else bad "APPROVE still asks the human when auto-merge won't take it"; fi

reset_calls
AUTOMERGE_WILL_TAKE=0  # true -- auto-merge takes this APPROVE
review_apply_verdict acme/repo 23 acme/repo#23 APPROVE PRESENT "looks good" 0
if called "forgejo_request_review"; then bad "APPROVE does not double-ask when auto-merge already takes it"; else ok "APPROVE does not double-ask when auto-merge already takes it"; fi
AUTOMERGE_WILL_TAKE=1

echo "== negative test: sever the routing, and a COMMENT-with-findings goes straight to handover =="
# Proves the FINDINGS check above is actually what changes the path, not some
# other branch: pretend review_comment_has_findings always says "nothing to
# adjudicate" (the pre-igor#552 behavior, where every COMMENT handed over
# unconditionally) and confirm the SAME inputs that entered rework above now
# hand over instead.
review_comment_has_findings() { return 1; }
reset_calls
review_apply_verdict acme/repo 10 acme/repo#10 COMMENT PRESENT "some finding" 0
if called "forgejo_assign"; then
  bad "severed routing: a COMMENT with findings still entered rework (routing had no effect)"
else ok "severed routing: the same COMMENT-with-findings input now hands over"
fi
if called "forgejo_request_review"; then
  ok "severed routing: and asks the human immediately, exactly like pre-igor#552"
else bad "severed routing: and asks the human immediately, exactly like pre-igor#552"; fi

echo "== source assertions: the downstream rework flow never re-checks verdict type =="
# BINDING_RC_BODY is what gates the rework/adjudication/converge/escalate flow
# once a PR is picked back up (bin/tick.sh's PR-review pickup, below
# do_review_tick). It must stay keyed on non-emptiness alone -- adding a
# verdict-specific branch there would be the "second mechanism" igor#552's
# deliverable explicitly rules out.
BRANCHES=$(grep -c 'BINDING_RC_BODY' "$TICK")
if [ "$BRANCHES" -ge 1 ]; then ok "BINDING_RC_BODY gates the rework pickup (${BRANCHES} reference(s))"
else bad "BINDING_RC_BODY gates the rework pickup"; fi
if grep -E 'BINDING_RC_BODY.*(REQUEST_CHANGES|COMMENT)|(REQUEST_CHANGES|COMMENT).*BINDING_RC_BODY' "$TICK" >/dev/null; then
  bad "the rework pickup must not branch on verdict type alongside BINDING_RC_BODY"
else
  ok "the rework pickup branches on BINDING_RC_BODY alone, not on which verdict set it"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-comment-rework: all checks passed"
else
  echo "test-review-comment-rework: $FAIL FAILED"
  exit 1
fi
