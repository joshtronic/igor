#!/usr/bin/env bash
# test-review-comment-rework.sh -- a COMMENT verdict that carries findings
# routes into the same rework loop REQUEST_CHANGES uses, instead of reaching
# the operator unadjudicated (igor#552).
#
# do_review_tick itself needs a network and a model call to reach, so -- same
# lift-the-function pattern test-review-directive.sh and test-review-timeout.sh
# already use -- the functions under test are extracted straight out of
# bin/tick.sh with sed and evaluated here, with every external call (Forgejo,
# review-state, maintenance validation, adjudication) stubbed to a recording
# function.
#
# Two ends of the loop are covered: review_apply_verdict, which decides whether
# a verdict enters rework at all, and the converged/stuck terminus a rework
# round reaches when the agent commits nothing. What runs BETWEEN them -- the
# worktree, the claude invocation, the push -- needs a network and is not
# covered here.
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

# The converged/stuck terminus is not a function -- it is an inline branch of
# tick.sh's PR-review pickup, and its position relative to the push and the
# worktree teardown is itself pinned by test-adjudication.sh's source
# assertions. Promoting it to a function to make it callable would move those
# positions; lifting the block into one HERE gets the behaviour under test
# without reshaping production code. It reads its inputs from the PR_* globals
# the pickup sets, so the tests below set those directly.
lift_block() {
  local anchor="$1" fn="$2" src
  src=$(awk -v a="$anchor" 'index($0, a) { on = 1 } on && /^    fi$/ { exit } on' "$TICK")
  [ -n "$src" ] || { echo "test-review-comment-rework: could not extract the no-commits block from bin/tick.sh" >&2; exit 1; }
  eval "${fn}() { $src
}"
}
lift_block '# No commits. Two very different situations' rework_no_commits

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
forgejo_unassign_all() { echo "forgejo_unassign_all $*" >> "$CALLLOG"; return 0; }
# The real ones live in lib/adjudication.sh (covered by test-adjudication.sh);
# here they only have to distinguish "the agent dismissed something" from "it
# came back empty-handed".
DISMISSED=""
adjudication_read() { [ -n "$DISMISSED" ] && printf '%s' "$DISMISSED"; }
adjudication_comment() { echo "adjudication_comment converged=$2" >> "$CALLLOG"; printf 'dismissal comment'; }
adjudication_log_line() { printf 'adjudication log line'; }

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
if called "forgejo_request_review"; then
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

echo "== a COMMENT that keeps not converging hits the shared round cap =="
# rc_rounds=3 is the existing REQUEST_CHANGES escalation threshold
# (review_route_into_rework); a COMMENT with findings reuses the exact same
# function, so it escalates at the same round rather than looping forever.
reset_calls
review_apply_verdict acme/repo 12 acme/repo#12 COMMENT PRESENT "still not fixed" 3
if called "forgejo_assign"; then bad "escalation does not re-assign the bot"; else ok "escalation does not re-assign the bot"; fi
if called "forgejo_request_review"; then ok "escalation hands the PR to the human"; else bad "escalation hands the PR to the human"; fi
if called "review_set_rework_rounds"; then bad "the round count does not advance past the cap"; else ok "the round count does not advance past the cap"; fi
# The escalation comment is read by a human on a PR Igor may never have
# requested changes on -- it must name the verdict that stalled, not assume one.
ESC=$(grep -F 'forgejo_comment acme/repo 12' "$CALLLOG")
has "the escalation comment names the COMMENT verdict" "$ESC" "COMMENT review did not converge"
lacks "and does not claim changes were requested" "$ESC" "requested changes"

echo "== a COMMENT-opened round with no commits and no dismissals is STUCK =="
# The rework agent came back empty-handed. BINDING_RC_BODY is what the pickup
# reads, and a COMMENT sets it exactly as a REQUEST_CHANGES does -- so this is
# the terminus a COMMENT-opened round actually reaches, not an analogy to one.
reset_calls
# Consumed inside the lifted block, which shellcheck cannot trace through.
# shellcheck disable=SC2034
{ PR_REPO=acme/repo; PR_NUMBER=30; REVIEW_KEY=acme/repo#30; PR_WORKTREE=/nonexistent
  BINDING_RC_BODY="findings from a COMMENT verdict"; }
DISMISSED=""
rework_no_commits
if called "adjudication_comment"; then bad "no dismissal comment when nothing was dismissed"; else ok "no dismissal comment when nothing was dismissed"; fi
if called "The agent reopened this PR"; then ok "the operator gets the no-new-commits note"; else bad "the operator gets the no-new-commits note"; fi
if called "review_set_pending_rc_body acme/repo#30 "; then ok "the pending findings are cleared -- the loop ends here"; else bad "the pending findings are cleared -- the loop ends here"; fi
if called "forgejo_unassign_all acme/repo 30"; then ok "the bot is unassigned"; else bad "the bot is unassigned"; fi
if called "forgejo_request_review acme/repo 30 operator"; then ok "escalated to the human"; else bad "escalated to the human"; fi

echo "== a COMMENT-opened round that dismissed every finding is CONVERGED =="
reset_calls
# shellcheck disable=SC2034
{ PR_NUMBER=31; REVIEW_KEY=acme/repo#31; }
DISMISSED="- Finding 1: the guard already covers that input. Dismissed."
rework_no_commits
if called "adjudication_comment converged=true"; then ok "the reasoning is posted as a converged adjudication"; else bad "the reasoning is posted as a converged adjudication"; fi
if called "The agent reopened this PR"; then bad "the stuck note is NOT posted over a converged round"; else ok "the stuck note is NOT posted over a converged round"; fi
if called "review_set_pending_rc_body acme/repo#31 "; then ok "the pending findings are cleared"; else bad "the pending findings are cleared"; fi
if called "forgejo_request_review acme/repo 31 operator"; then ok "handed to the human with the argument attached"; else bad "handed to the human with the argument attached"; fi
DISMISSED=""

echo "== a plain reassignment (no pending findings) still ends the old way =="
reset_calls
# shellcheck disable=SC2034
{ PR_NUMBER=32; REVIEW_KEY=acme/repo#32; BINDING_RC_BODY=""; }
rework_no_commits
if called "review_set_pending_rc_body"; then bad "nothing to clear outside the binding flow"; else ok "nothing to clear outside the binding flow"; fi
if called "forgejo_request_review acme/repo 32 operator"; then ok "the human is still asked"; else bad "the human is still asked"; fi

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

echo "== the terminus cannot branch on which verdict opened the round =="
# A verdict-specific branch here would be the "second mechanism" igor#552's
# deliverable rules out. Scoped to the lifted block via declare -f (which
# strips comments) rather than grepped over all of bin/tick.sh, where an
# unrelated line naming a verdict would fail the check for no reason.
BLOCK_SRC=$(declare -f rework_no_commits)
lacks "no verdict token reaches the converged/stuck decision" "$BLOCK_SRC" "REQUEST_CHANGES"
lacks "and none reaches it under the other name either" "$BLOCK_SRC" "COMMENT"
has  "it is gated on the pending findings alone" "$BLOCK_SRC" '-n "$BINDING_RC_BODY"'

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-comment-rework: all checks passed"
else
  echo "test-review-comment-rework: $FAIL FAILED"
  exit 1
fi
