#!/usr/bin/env bash
# test-review-ci-staleness.sh -- igor#593: a stored REQUEST_CHANGES verdict
# caused by failing CI survived forever once the patch-id dedup kicked in,
# because the dedup only compared the diff, not the CI status the verdict
# was made under. The directive makes CI failure a hard REQUEST_CHANGES
# regardless of diff quality, so the verdict is a function of (patch, CI),
# not patch alone -- a base-merge that flips CI to success with the same
# patch-id must still trigger a re-review.
#
# do_review_tick lives inline in bin/tick.sh (top-level side-effecting code,
# so it can't be sourced directly). Following test-maintenance.sh's
# precedent, each function under test is lifted out with
# `sed -n '/^fn() {$/,/^}$/p'` and eval'd, with every dependency it touches
# stubbed. Skip-safe: needs jq + git; exits 0 with a notice if either is
# absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-ci-staleness: jq absent -- skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-review-ci-staleness: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

extract_fn() { sed -n "/^$1() {\$/,/^}\$/p" "$TICK"; }

for fn in review_reviewed_sha review_reviewed_patchid review_reviewed_ci \
          review_record review_update_sha review_ci_became_success \
          review_parse_response do_review_tick; do
  SRC="$(extract_fn "$fn")"
  if [ -z "$SRC" ]; then
    echo "test-review-ci-staleness: could not extract $fn() from bin/tick.sh -- skipping"
    exit 0
  fi
  eval "$SRC"
done

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo "== review_ci_became_success: the pure decision (unit) =="
if review_ci_became_success failure success; then ok "failure -> success is a flip"
else bad "failure -> success is a flip"; fi
if review_ci_became_success failure failure; then bad "failure -> failure is not a flip"
else ok "failure -> failure is not a flip"; fi
if review_ci_became_success success success; then bad "success -> success is not a flip"
else ok "success -> success is not a flip"; fi
if review_ci_became_success "" success; then ok "missing stored ci -> success reads as a flip (pinned behaviour)"
else bad "missing stored ci -> success reads as a flip (pinned behaviour)"; fi
if review_ci_became_success "" failure; then bad "missing stored ci -> non-success is not a flip"
else ok "missing stored ci -> non-success is not a flip"; fi

# -- integration: do_review_tick end to end, everything stubbed --------

TMP="$(mktemp -d)" || { echo "test-review-ci-staleness: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state.json"
echo '{}' > "$STATE"
discretionary_state_file() { printf '%s' "$STATE"; }

log() { printf '[agent] %s\n' "$*" >&2; }
# Read only by the eval'd do_review_tick, which shellcheck can't see through.
# shellcheck disable=SC2034
BOT_USER="igor"
# shellcheck disable=SC2034
AGENT_MODEL_REVIEW="test-model"
# shellcheck disable=SC2034
REVIEW_CALL_TIMEOUT_SECS=1

REPO="acme/repo"
NUM=1
KEY="${REPO}#${NUM}"
HEAD_SHA="newsha0000"
# shellcheck disable=SC2034
ANALYSIS_REPOS_JSON="{\"full_name\":\"$REPO\"}"

DIFF="diff --git a/foo b/foo
index 000..111 100644
--- a/foo
+++ b/foo
@@ -0,0 +1 @@
+hi
"
PATCH_ID=$(printf '%s' "$DIFF" | git patch-id --stable 2>/dev/null | awk '{print $1}')
OTHER_DIFF="diff --git a/bar b/bar
index 000..111 100644
--- a/bar
+++ b/bar
@@ -0,0 +1 @@
+bye
"

maintenance_repo_validated() { return 0; }
forgejo_list_open_bot_prs() { printf '[{"number":%s}]' "$NUM"; }
forgejo_get_pr() { printf '{"head":{"sha":"%s"},"title":"a pr"}' "$HEAD_SHA"; }
checkpoint_is_wip() { return 1; }
forgejo_pr_has_comment_containing() { echo 0; }
forgejo_commit_status() { printf '%s' "$CURRENT_CI"; }
forgejo_pr_diff() { printf '%s' "$CUR_DIFF"; }
context_surface() { printf 'directive'; }
review_build_prompt() { printf 'prompt'; }
review_rework_rounds() { echo 0; }
reviewer_effort() { echo high; }
forgejo_comment() { COMMENT_POSTED=1; return 0; }
forgejo_log_time() { return 0; }
review_apply_verdict() { :; }

CLAUDE_CALLED_MARKER="$TMP/claude_called"
# claude_call runs inside `raw=$(claude_call ...)`, a subshell -- a plain
# variable set there never reaches the parent, so use a file as the flag.
claude_call() { : > "$CLAUDE_CALLED_MARKER"; printf 'VERDICT: APPROVE\n===BODY===\nlooks fine\n'; }
claude_called() { [ -f "$CLAUDE_CALLED_MARKER" ] && echo 1 || echo 0; }

reset_run() {
  rm -f "$CLAUDE_CALLED_MARKER"
  COMMENT_POSTED=0
}

echo "== do_review_tick: 1. stored REQUEST_CHANGES/failure, patch unchanged, CI now success -> re-review runs =="
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "REQUEST_CHANGES" "failure" "1000" "$PATCH_ID"
CUR_DIFF="$DIFF"
CURRENT_CI="success"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "claude_call was invoked (re-reviewed)" "1" "$(claude_called)"
eq "a new comment was posted" "1" "$COMMENT_POSTED"
eq "the new verdict was recorded" "APPROVE" "$(jq -r --arg k "$KEY" '.review[$k].verdict' "$STATE")"
eq "the recorded ci reflects the new success" "success" "$(jq -r --arg k "$KEY" '.review[$k].ci' "$STATE")"

echo "== do_review_tick: 2. stored REQUEST_CHANGES/failure, patch unchanged, CI still failure -> skip =="
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "REQUEST_CHANGES" "failure" "1000" "$PATCH_ID"
CUR_DIFF="$DIFF"
CURRENT_CI="failure"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "claude_call was NOT invoked (skipped)" "0" "$(claude_called)"
eq "the stored verdict is unchanged" "REQUEST_CHANGES" "$(jq -r --arg k "$KEY" '.review[$k].verdict' "$STATE")"
eq "the stored ci is unchanged" "failure" "$(jq -r --arg k "$KEY" '.review[$k].ci' "$STATE")"
eq "the sha was still advanced to the new head" "$HEAD_SHA" "$(jq -r --arg k "$KEY" '.review[$k].sha' "$STATE")"

echo "== do_review_tick: 3. stored APPROVE/success, patch unchanged, CI still success -> skip (today's behaviour) =="
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "APPROVE" "success" "1000" "$PATCH_ID"
CUR_DIFF="$DIFF"
CURRENT_CI="success"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "claude_call was NOT invoked (skipped)" "0" "$(claude_called)"
eq "the stored verdict is unchanged" "APPROVE" "$(jq -r --arg k "$KEY" '.review[$k].verdict' "$STATE")"

echo "== do_review_tick: 3b. stored APPROVE/success, patch unchanged, CI now failure -> still skip =="
# The rule is deliberately one-directional: only not-success -> success is a
# flip. A green-CI APPROVE that goes red on a base merge keeps today's skip.
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "APPROVE" "success" "1000" "$PATCH_ID"
CUR_DIFF="$DIFF"
CURRENT_CI="failure"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "claude_call was NOT invoked (skipped)" "0" "$(claude_called)"
eq "the stored verdict is unchanged" "APPROVE" "$(jq -r --arg k "$KEY" '.review[$k].verdict' "$STATE")"
eq "the stored ci is unchanged" "success" "$(jq -r --arg k "$KEY" '.review[$k].ci' "$STATE")"

echo "== do_review_tick: 4. patch-id changed -> re-review regardless of CI =="
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "APPROVE" "success" "1000" "$PATCH_ID"
CUR_DIFF="$OTHER_DIFF"
CURRENT_CI="success"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "claude_call was invoked (re-reviewed on patch change)" "1" "$(claude_called)"

echo "== do_review_tick: 5. stored record with no ci field (older state) -> does not crash, defined behaviour =="
echo '{}' > "$STATE"
review_record "$KEY" "oldsha" "REQUEST_CHANGES" "" "1000" "$PATCH_ID"
jq --arg k "$KEY" '.review[$k] |= del(.ci)' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
eq "fixture really has no ci field" "null" "$(jq -r --arg k "$KEY" '.review[$k].ci' "$STATE")"
CUR_DIFF="$DIFF"
CURRENT_CI="success"
reset_run
do_review_tick >"$TMP/out.log" 2>&1
eq "do_review_tick completes cleanly (no crash on a missing ci field)" "0" "$?"
eq "a missing stored ci with current CI success re-reviews (pinned)" "1" "$(claude_called)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-ci-staleness: all checks passed"
else
  echo "test-review-ci-staleness: $FAIL check(s) failed"
fi
exit "$FAIL"
