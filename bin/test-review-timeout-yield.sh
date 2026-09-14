#!/usr/bin/env bash
# test-review-timeout-yield.sh -- igor#638: a review call that times out must
# not be retried identically, and a head that keeps timing out must not
# monopolize the cascade tick after tick.
#
# Observed on igor#637: two attempts per do_review_tick invocation, each at
# the SAME effort and the SAME REVIEW_CALL_TIMEOUT_SECS budget, both timing
# out -- ten minutes each, twenty minutes per tick, repeated every tick since
# nothing about the retry differed and the same un-reviewed head was picked
# again. In thirty minutes the harness completed exactly one claim scan.
#
# The fix has two parts, both exercised here:
#   1. reviewer_retry_effort steps the effort DOWN after an in-tick timeout,
#      so attempt 2 is a genuinely different (cheaper, faster) call.
#   2. A persistent per-head timeout streak yields the head after
#      REVIEW_TIMEOUT_STREAK_CAP consecutive timeout-caused failures: further
#      ticks skip it (no model call at all) until a new commit changes the
#      head sha, or the cooldown lapses -- and a human is notified once per
#      head, not once per lapsed cooldown.
#
# Same lifting pattern as test-review-ci-staleness.sh: do_review_tick lives
# inline in bin/tick.sh (top-level side-effecting code), so each function
# under test is extracted with sed and eval'd, with every dependency stubbed.
# Skip-safe: needs jq + git; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-timeout-yield: jq absent -- skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-review-timeout-yield: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

extract_fn() { sed -n "/^$1() {\$/,/^}\$/p" "$TICK"; }

for fn in review_reviewed_sha review_reviewed_patchid review_reviewed_ci \
          review_record review_update_sha review_ci_became_success \
          review_parse_response reviewer_effort reviewer_retry_effort \
          review_timeout_streak review_set_timeout_streak \
          review_set_timeout_yield review_timeout_yielded \
          review_clear_timeout_streak review_note_timeout_failure \
          do_review_tick; do
  SRC="$(extract_fn "$fn")"
  if [ -z "$SRC" ]; then
    echo "test-review-timeout-yield: could not extract $fn() from bin/tick.sh -- skipping"
    exit 0
  fi
  eval "$SRC"
done

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo "== reviewer_retry_effort: steps down, never repeats the exact same rung =="
eq "max steps down to high" "high" "$(reviewer_retry_effort max)"
eq "high steps down to medium" "medium" "$(reviewer_retry_effort high)"
eq "an already-stepped-down effort floors at medium" "medium" "$(reviewer_retry_effort medium)"

echo "== review_timeout_yielded: pure cooldown-boundary checks =="
TMP="$(mktemp -d)" || { echo "test-review-timeout-yield: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state.json"
discretionary_state_file() { printf '%s' "$STATE"; }

echo '{}' > "$STATE"
review_set_timeout_yield "acme/repo#9" "shaAAA" 2 5000
if review_timeout_yielded "acme/repo#9" "shaAAA" 4999; then ok "before the cooldown expires, still yielded"
else bad "before the cooldown expires, still yielded"; fi
if review_timeout_yielded "acme/repo#9" "shaAAA" 5000; then bad "at/after the cooldown epoch, no longer yielded"
else ok "at/after the cooldown epoch, no longer yielded"; fi
if review_timeout_yielded "acme/repo#9" "shaBBB" 100; then bad "a yield recorded against a DIFFERENT sha never applies"
else ok "a yield recorded against a DIFFERENT sha never applies"; fi
if review_timeout_yielded "acme/repo#unknown" "shaAAA" 100; then bad "an unrelated key is never yielded"
else ok "an unrelated key is never yielded"; fi

echo '{}' > "$STATE"
review_set_timeout_yield "acme/repo#9" "shaAAA" 2 5000
review_clear_timeout_streak "acme/repo#9"
if review_timeout_yielded "acme/repo#9" "shaAAA" 100; then bad "review_clear_timeout_streak lifts a yield"
else ok "review_clear_timeout_streak lifts a yield"; fi
eq "and the streak count itself is cleared too" "0" "$(jq -r '.review["acme/repo#9"].timeout_streak' "$STATE")"

# -- integration: do_review_tick end to end, everything stubbed --------

log() { printf '[agent] %s\n' "$*" >&2; }
# Read only by the eval'd do_review_tick / review_note_timeout_failure.
# shellcheck disable=SC2034
BOT_USER="igor"
# shellcheck disable=SC2034
AGENT_MODEL_REVIEW="test-model"
# shellcheck disable=SC2034
REVIEW_CALL_TIMEOUT_SECS=1
# shellcheck disable=SC2034
REVIEW_TIMEOUT_STREAK_CAP=2
# shellcheck disable=SC2034
REVIEW_TIMEOUT_YIELD_COOLDOWN_SECS=3600
# shellcheck disable=SC2034
FORGEJO_REVIEWER="josh"

REPO="acme/repo"
NUM=9
KEY="${REPO}#${NUM}"
HEAD_SHA="deadbeef01"
HEAD_SHA2="deadbeef02"
HEAD_SHA3="deadbeef03"
HEAD_SHA4="deadbeef04"
# shellcheck disable=SC2034
ANALYSIS_REPOS_JSON="{\"full_name\":\"$REPO\"}"

maintenance_repo_validated() { return 0; }
forgejo_list_open_bot_prs() { printf '[{"number":%s}]' "$NUM"; }
forgejo_get_pr() { printf '{"head":{"sha":"%s"},"title":"a pr"}' "$CURRENT_HEAD_SHA"; }
checkpoint_is_wip() { return 1; }
forgejo_commit_status() { printf 'success'; }
# Content varies with the head so each sha has its own patch-id -- otherwise the
# base-merge dedup treats a later head as "same net diff" and skips it.
forgejo_pr_diff() { printf 'diff --git a/foo b/foo\nindex 000..111 100644\n--- a/foo\n+++ b/foo\n@@ -0,0 +1 @@\n+hi %s\n' "$CURRENT_HEAD_SHA"; }
context_surface() { printf 'directive'; }
review_build_prompt() { printf 'prompt'; }
review_rework_rounds() { echo 0; }
forgejo_log_time() { return 0; }
review_apply_verdict() { :; }
review_request_human() { printf '%s\n' "$3" >> "$REQUEST_HUMAN_LOG"; return 0; }

CLAUDE_CALL_LOG="$TMP/claude_calls.log"
COMMENT_LOG="$TMP/comments.log"
REQUEST_HUMAN_LOG="$TMP/request_human.log"
# COMMENT_LOG is per-block (reset between scenarios); PR_COMMENTS_LOG is the
# PR's whole comment history, never reset -- what the harness's own dedup reads
# back over. A marker posted in one scenario has to still be findable in the
# next, or the re-escalation check below would pass vacuously.
PR_COMMENTS_LOG="$TMP/pr_comments.log"
: > "$PR_COMMENTS_LOG"
reset_logs() { : > "$CLAUDE_CALL_LOG"; : > "$COMMENT_LOG"; : > "$REQUEST_HUMAN_LOG"; }
claude_call_count() { wc -l < "$CLAUDE_CALL_LOG" | tr -d ' '; }
forgejo_comment() {
  printf '%s\n' "$3" >> "$COMMENT_LOG"
  printf '%s\n' "$3" >> "$PR_COMMENTS_LOG"
  return 0
}
forgejo_pr_has_comment_containing() {
  local n
  n=$(grep -cF -- "$4" "$PR_COMMENTS_LOG" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# Always-times-out stub: `timeout` itself exits 124 on kill, and claude_call
# now propagates that real rc (igor#638) instead of collapsing it to a flat 1
# -- this is what lets do_review_tick tell a timeout apart from any other
# failure. Records the model:effort argument so the test can see whether the
# retry actually differs.
claude_call_always_times_out() {
  printf '%s\n' "$1" >> "$CLAUDE_CALL_LOG"
  return 124
}

echo "== do_review_tick: attempt 2 uses a different (stepped-down) effort, not an identical retry =="
echo '{}' > "$STATE"
CURRENT_HEAD_SHA="$HEAD_SHA"
claude_call() { claude_call_always_times_out "$@"; }
reset_logs
do_review_tick >"$TMP/out.log" 2>&1
RC=$?
eq "do_review_tick returns non-zero (no verdict) so the cascade falls through" "1" "$RC"
eq "both attempts were made" "2" "$(claude_call_count)"
EFFORT1=$(sed -n '1p' "$CLAUDE_CALL_LOG"); EFFORT2=$(sed -n '2p' "$CLAUDE_CALL_LOG")
eq "attempt 1 runs at the normal effort" "test-model:high" "$EFFORT1"
eq "attempt 2 steps the effort down -- NOT an identical retry" "test-model:medium" "$EFFORT2"
eq "streak is 1/2 -- below the cap, no human notification yet" "1" "$(jq -r --arg k "$KEY" '.review[$k].timeout_streak' "$STATE")"
eq "no PR comment posted (verdict or escalation) below the cap" "" "$(cat "$COMMENT_LOG")"
eq "no human requested yet" "" "$(cat "$REQUEST_HUMAN_LOG")"

echo "== do_review_tick: second consecutive timeout on the same head reaches the cap -> yields + notifies once =="
reset_logs
do_review_tick >"$TMP/out.log" 2>&1
RC=$?
eq "still returns non-zero" "1" "$RC"
eq "both attempts were made again" "2" "$(claude_call_count)"
eq "streak reached the cap" "2" "$(jq -r --arg k "$KEY" '.review[$k].timeout_streak' "$STATE")"
YIELD_UNTIL=$(jq -r --arg k "$KEY" '.review[$k].timeout_yield_until' "$STATE")
if [ "${YIELD_UNTIL:-0}" -gt "$(date +%s)" ]; then ok "a future cooldown was recorded"
else bad "a future cooldown was recorded: got [$YIELD_UNTIL]"; fi
case "$(cat "$COMMENT_LOG")" in
  *"timed out 2 times"*) ok "a human-readable comment was posted on the PR" ;;
  *) bad "a human-readable comment was posted on the PR: got [$(cat "$COMMENT_LOG")]" ;;
esac
eq "the human reviewer was requested, with the timeout context" "review timed out 2x" "$(cat "$REQUEST_HUMAN_LOG")"

echo "== do_review_tick: a yielded head is skipped -- NO model call, so the cascade is not blocked =="
reset_logs
do_review_tick >"$TMP/out.log" 2>&1
RC=$?
eq "returns non-zero (nothing to review this tick)" "1" "$RC"
eq "claude_call was NOT invoked -- the doomed head cost nothing this tick" "0" "$(claude_call_count)"
eq "no duplicate escalation comment/request while yielded" "" "$(cat "$COMMENT_LOG")$(cat "$REQUEST_HUMAN_LOG")"

echo "== do_review_tick: once the cooldown lapses the head is re-tried, but the escalation does NOT repeat =="
# The yield is a backoff, not a permanent skip: after
# REVIEW_TIMEOUT_YIELD_COOLDOWN_SECS the head is selectable again and, on a
# permanently-timing-out head, hits the cap again. Without a dedup that is one
# comment + one review request per cooldown, forever.
reset_logs
jq --arg k "$KEY" '.review[$k].timeout_yield_until = 1' "$STATE" > "$TMP/state.next" && mv "$TMP/state.next" "$STATE"
do_review_tick >"$TMP/out.log" 2>&1
RC=$?
eq "still returns non-zero" "1" "$RC"
eq "the head IS re-tried once the cooldown lapses" "2" "$(claude_call_count)"
eq "streak keeps climbing" "3" "$(jq -r --arg k "$KEY" '.review[$k].timeout_streak' "$STATE")"
YIELD_UNTIL=$(jq -r --arg k "$KEY" '.review[$k].timeout_yield_until' "$STATE")
if [ "${YIELD_UNTIL:-0}" -gt "$(date +%s)" ]; then ok "the yield is re-armed for another cooldown"
else bad "the yield is re-armed for another cooldown: got [$YIELD_UNTIL]"; fi
eq "no SECOND escalation comment for the same head" "" "$(cat "$COMMENT_LOG")"
eq "and no second review request either" "" "$(cat "$REQUEST_HUMAN_LOG")"

echo "== do_review_tick: a new commit (new head sha) lifts the yield immediately, and a normal review still works =="
reset_logs
CURRENT_HEAD_SHA="$HEAD_SHA2"
claude_call() { printf '%s\n' "$1" >> "$CLAUDE_CALL_LOG"; printf 'VERDICT: APPROVE\n===BODY===\nlooks fine\n'; }
do_review_tick >"$TMP/out.log" 2>&1
RC=$?
eq "a normal review on the new head succeeds (same verdict path as always)" "0" "$RC"
eq "exactly one call -- a healthy review needs no retry" "1" "$(claude_call_count)"
eq "the new head's verdict was recorded" "APPROVE" "$(jq -r --arg k "$KEY" '.review[$k].verdict' "$STATE")"
eq "the timeout streak is clear after a successful review" "0" "$(jq -r --arg k "$KEY" '.review[$k].timeout_streak' "$STATE")"

echo "== do_review_tick: with no FORGEJO_REVIEWER configured the PR comment still surfaces the yield =="
# Only the review REQUEST needs a reviewer name (review_request_human self-gates
# on it). Gating the comment too would leave a repo with no configured reviewer
# with nothing but a journal line -- which is the trace igor#638 was filed over.
# shellcheck disable=SC2034  # read by the eval'd review_note_timeout_failure
FORGEJO_REVIEWER=""
CURRENT_HEAD_SHA="$HEAD_SHA3"
claude_call() { claude_call_always_times_out "$@"; }
reset_logs
do_review_tick >"$TMP/out.log" 2>&1
do_review_tick >"$TMP/out.log" 2>&1
eq "the cap is still reached on the new head" "2" "$(jq -r --arg k "$KEY" '.review[$k].timeout_streak' "$STATE")"
case "$(cat "$COMMENT_LOG")" in
  *"timed out 2 times"*) ok "the escalation comment is posted anyway" ;;
  *) bad "the escalation comment is posted anyway: got [$(cat "$COMMENT_LOG")]" ;;
esac

echo "== do_review_tick is errexit-safe: a failing review call returns, it does not abort the shell =="
# bin/tick.sh runs under `set -euo pipefail`. do_review_tick happens to be
# invoked from `if cascade_run review`, which suppresses errexit for its whole
# dynamic extent -- but that is the caller's accident, not this function's
# property. A bare failing `raw=$(claude_call ...)` would kill the entire tick
# on the first timeout, which is worse starvation than the bug being fixed.
CURRENT_HEAD_SHA="$HEAD_SHA4"
reset_logs
( set -e; do_review_tick ) >"$TMP/out.log" 2>&1
RC=$?
eq "returns 1 under errexit, not the timeout rc of an aborted shell" "1" "$RC"
eq "and both attempts still ran" "2" "$(claude_call_count)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-timeout-yield: all checks passed"
else
  echo "test-review-timeout-yield: $FAIL check(s) failed"
fi
exit "$FAIL"
