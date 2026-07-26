#!/usr/bin/env bash
# test-forgejo.sh -- unit tests for forgejo_find_claimable (lib/forgejo.sh), the
# greenlight gate. The `Agent` label is REQUIRED and re-verified client-side, so
# the gate fails CLOSED even when Forgejo ignores the `labels=Agent` API filter
# -- which it does on a repo that has no `Agent` label, returning every open
# issue instead of none. Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-forgejo: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# _fj must pass fail-fast timeouts so a brief git.sherver.org blip can't wedge a
# tick (igor#395): a --max-time 30 with no --connect-timeout once hung a tick
# ~30s and tripped the task-fail healthcheck. Shim curl to capture the args the
# REAL _fj builds (run before the fixtures below stub _fj out).
echo "== _fj: fail-fast connect + max timeouts (igor#395) =="
curl() { printf '%s\n' "$*"; }
FJ_ARGS=$(_fj GET /version)
unset -f curl
eq "_fj sets --connect-timeout ${FORGEJO_CONNECT_TIMEOUT}" "true" \
  "$(grep -q -- "--connect-timeout ${FORGEJO_CONNECT_TIMEOUT}" <<<"$FJ_ARGS" && echo true || echo false)"
eq "_fj sets --max-time ${FORGEJO_MAX_TIME} (fail-fast, not the old 30)" "true" \
  "$(grep -q -- "--max-time ${FORGEJO_MAX_TIME}" <<<"$FJ_ARGS" && echo true || echo false)"
eq "the connect timeout is fail-fast (< old 30s max)" "true" \
  "$([ "$FORGEJO_CONNECT_TIMEOUT" -lt 30 ] && echo true || echo false)"

# Fixture: what Forgejo returns when it IGNORES the labels=Agent filter (a repo
# with no Agent label) -- a mix of Agent-labeled and unlabeled/other issues,
# assignees, and a blocked one.
FIXTURE='[
  {"number":1,"created_at":"2026-01-01T00:00:00Z","assignees":[],"labels":[{"name":"Agent"}]},
  {"number":2,"created_at":"2026-01-02T00:00:00Z","assignees":[],"labels":[]},
  {"number":3,"created_at":"2026-01-03T00:00:00Z","assignees":[],"labels":[{"name":"Kind/Bug"}]},
  {"number":4,"created_at":"2026-01-04T00:00:00Z","assignees":[{"login":"josh"}],"labels":[{"name":"Agent"}]},
  {"number":5,"created_at":"2026-01-05T00:00:00Z","assignees":[{"login":"someone"}],"labels":[{"name":"Agent"}]},
  {"number":6,"created_at":"2026-01-06T00:00:00Z","assignees":[],"labels":[{"name":"Agent"},{"name":"Status/Blocked"}]},
  {"number":7,"created_at":"2025-12-31T00:00:00Z","assignees":[],"labels":[{"name":"Agent"}]}
]'
_fj() { printf '%s' "$FIXTURE"; }

echo "== forgejo_find_claimable: Agent label required, fails closed =="

OUT=$(forgejo_find_claimable acme/x josh)
eq "only Agent-labeled survive (unlabeled #2, other-label #3 dropped)" \
  "1 4 7" "$(jq -r '[.[].number] | sort | join(" ")' <<<"$OUT")"
eq "oldest-first ordering" "7 1 4" "$(jq -r '[.[].number] | join(" ")' <<<"$OUT")"
eq "assigned-to-reviewer kept, assigned-to-other dropped" \
  "true" "$(jq -r '([.[].number] | index(4) != null) and ([.[].number] | index(5) == null)' <<<"$OUT")"
eq "Status/Blocked dropped even with Agent" \
  "true" "$(jq -r '[.[].number] | index(6) == null' <<<"$OUT")"

OUT=$(forgejo_find_claimable acme/x "")
eq "no reviewer -> only unassigned Agent issues" \
  "1 7" "$(jq -r '[.[].number] | sort | join(" ")' <<<"$OUT")"

# The regression this guards: a repo with NO Agent label makes Forgejo return
# every open issue (filter ignored). The client-side check must drop them all.
NOAGENT='[
  {"number":10,"created_at":"2026-02-01T00:00:00Z","assignees":[],"labels":[]},
  {"number":11,"created_at":"2026-02-02T00:00:00Z","assignees":[],"labels":[{"name":"Kind/Feature"}]}
]'
_fj() { printf '%s' "$NOAGENT"; }
eq "repo missing Agent label -> nothing claimable (fails CLOSED)" \
  "[]" "$(forgejo_find_claimable acme/x josh | jq -c '[.[].number]')"

# forgejo_request_review (#377): retries once on a transient code and surfaces
# the real HTTP reason instead of a bare, ambiguous warning. Stub the HTTP seam
# (_forgejo_post_reviewers echoes "<body>\n<code>") and no-op sleep so the retry
# path doesn't actually pause. The seam runs in a command-substitution subshell,
# so cross-call state lives in a temp file, not a shell var.
echo "== forgejo_request_review: success / transient-retry / real-error =="
sleep() { :; }

_forgejo_post_reviewers() { printf '[]\n201'; }
forgejo_request_review acme/x 1 josh 2>/dev/null; eq "201 -> rc 0 (requested)" "0" "$?"

RR_STATE=$(mktemp)
_forgejo_post_reviewers() {
  local n; n=$(cat "$RR_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RR_STATE"
  if [ "$n" -eq 1 ]; then printf 'upstream unavailable\n503'; else printf '[]\n201'; fi
}
forgejo_request_review acme/x 1 josh 2>/dev/null; eq "transient 503 then 201 -> rc 0 (retried)" "0" "$?"
eq "retry re-POSTed exactly once (2 attempts)" "2" "$(cat "$RR_STATE")"
rm -f "$RR_STATE"

_forgejo_post_reviewers() { printf 'gateway timeout\n503'; }
ERR=$(forgejo_request_review acme/x 1 josh 2>&1); eq "persistent 503 -> rc 1" "1" "$?"
eq "persistent failure surfaces the HTTP status" "true" "$(grep -q 503 <<<"$ERR" && echo true || echo false)"

_forgejo_post_reviewers() { printf '{"message":"reviewer invalid"}\n422'; }
ERR=$(forgejo_request_review acme/x 1 josh 2>&1); eq "client 422 -> rc 1 (no retry)" "1" "$?"
eq "422 surfaces the reason" "true" "$(grep -qi 'reviewer invalid' <<<"$ERR" && echo true || echo false)"
# forgejo_repo_has_label: the onboarding check behind #376. Distinct exit codes
# let validate-repo.sh tell "absent" (flag it) from "couldn't check" (skip).
echo "== forgejo_repo_has_label: present / absent / indeterminate =="

_fj() { printf '%s' '[{"id":1,"name":"Agent"},{"id":2,"name":"Kind/Bug"}]'; }
forgejo_repo_has_label acme/x Agent; eq "defined label -> rc 0 (present)" "0" "$?"
forgejo_repo_has_label acme/x Nope;  eq "undefined name -> rc 1 (absent)" "1" "$?"

_fj() { printf '%s' '[]'; }
forgejo_repo_has_label acme/x Agent; eq "empty label set -> rc 1 (absent)" "1" "$?"

# curl -sf exits nonzero on an HTTP error; the read must surface as indeterminate
# (rc 2), NOT be mistaken for "label absent".
_fj() { return 22; }
forgejo_repo_has_label acme/x Agent; eq "API read failed -> rc 2 (indeterminate)" "2" "$?"

# forgejo_list_open_bot_prs: the PR-review + auto-merge ticks pick PRs through
# this helper, so it must request sort=oldest -- matching the issue grind
# (forgejo_find_claimable) so a PR can't starve at the back of a deep queue. The
# _fj call pipes to jq (a subshell), so capture its URL to a temp file, not a var.
echo "== forgejo_list_open_bot_prs: oldest-first, consistent with the grind =="
LOBP_CAP=$(mktemp)
_fj() { printf '%s\n' "$*" >"$LOBP_CAP"; printf '%s' '[]'; }
forgejo_list_open_bot_prs acme/x bot >/dev/null
eq "requests sort=oldest (review + merge match the issue grind)" \
  "true" "$(grep -q 'sort=oldest' "$LOBP_CAP" && echo true || echo false)"
rm -f "$LOBP_CAP"

# forgejo_commit_status: the CI-green signal the auto-merge / deploy-barrier /
# review ticks all key on. v16 marks a SKIPPED Actions check as its own
# non-success individual status, which can knock the COMBINED .state off
# "success" even though nothing failed -- and would then silently stop
# auto-merge. The fold rescues that WITHOUT ever greening a head that carries a
# real pending/failure/error (igor#414). Each case runs in a $() subshell, so
# the per-case _fj stub doesn't leak.
echo "== forgejo_commit_status: v16 skipped-check fold (igor#414) =="
cs() { local fx="$1"; _fj() { printf '%s' "$fx"; }; forgejo_commit_status acme/x deadbeef; }
eq "combined success -> success (baseline, unchanged)" "success" \
  "$(cs '{"state":"success","statuses":[{"status":"success"}]}')"
eq "v16: combined off-success but all statuses success/skipped -> folded green" "success" \
  "$(cs '{"state":"warning","statuses":[{"status":"success","context":"CI"},{"status":"skipped","context":"Deploy"}]}')"
eq "a real failure is NEVER folded green" "failure" \
  "$(cs '{"state":"failure","statuses":[{"status":"success"},{"status":"failure"}]}')"
eq "a still-running (pending) check is NEVER folded green" "pending" \
  "$(cs '{"state":"pending","statuses":[{"status":"success"},{"status":"pending"}]}')"
eq "no statuses at all is not falsely greened" "" \
  "$(cs '{"state":"","statuses":[]}')"

# forgejo_failing_ci_logs / forgejo_action_job_log (igor#415): on a PR head whose
# CI is RED, pull the failing Actions job-log tails into the rework prompt. These
# are v16-only endpoints, so the function MUST no-op (empty) on v15 (404) and on
# green CI -- that self-gating is what makes it safe to call on every rework. Each
# case stubs _fj (dispatch on path) + curl (the job log) inside a $() subshell so
# the stubs don't leak. Endpoint shapes were verified against a live v16.0.1.
echo "== forgejo_failing_ci_logs: v16 CI-failure logs into rework (igor#415) =="
fcl() {  # <runs-json> <jobs-json> <job-log-text>
  local RUNS="$1" JOBS="$2" JOBLOG="$3"
  _fj() { case "$2" in
            *"/actions/runs?head_sha="*) printf '%s' "$RUNS" ;;
            *"/jobs")                     printf '%s' "$JOBS" ;;
            *)                            printf '' ;;
          esac; }
  curl() { printf '%s' "$JOBLOG"; }
  forgejo_failing_ci_logs acme/x deadbeefsha
}
FCL_RUNS='{"workflow_runs":[{"id":1406,"status":"failure"},{"id":1407,"status":"success"}]}'
FCL_JOBS='[{"id":1853,"name":"check-sync","status":"failure"},{"id":1854,"name":"lint","status":"success"}]'
FCL_LOG=$(printf 'line one\nboom: build failed exit 1\nJob failed')
OUT=$(fcl "$FCL_RUNS" "$FCL_JOBS" "$FCL_LOG")
eq "failing CI -> heading present" "true" \
  "$(grep -q 'CI is failing on this PR head' <<<"$OUT" && echo true || echo false)"
eq "failing CI -> failed job (check-sync) block shown" "true" \
  "$(grep -q 'Job .check-sync' <<<"$OUT" && echo true || echo false)"
eq "failing CI -> the failing log tail is included" "true" \
  "$(grep -q 'boom: build failed exit 1' <<<"$OUT" && echo true || echo false)"
eq "failing CI -> passing job (lint) is excluded" "false" \
  "$(grep -q 'Job .lint' <<<"$OUT" && echo true || echo false)"
eq "green CI -> empty (no failing run to report)" "" \
  "$(fcl '{"workflow_runs":[{"id":1,"status":"success"}]}' '[]' 'unused')"
# v15 / pre-Actions-API: the runs endpoint 404s -> _fj nonzero -> empty (no-op).
fcl_v15() { _fj() { return 22; }; forgejo_failing_ci_logs acme/x deadbeef; }
eq "v15 / Actions API 404 -> empty (graceful no-op, v15-safe)" "" "$(fcl_v15)"
eq "empty sha -> empty (nothing to look up)" "" "$(forgejo_failing_ci_logs acme/x '')"
eq "job log: empty job id -> empty (guard)" "" "$(forgejo_action_job_log acme/x '')"

# _fj bounded retry, GET/HEAD only (igor#425): a stalled read (curl exit 28,
# timeout) used to propagate fatally -- an unguarded caller like
# `x=$(_fj GET ... | jq ...)` in tick.sh's PR-review pickup loop would abort
# the WHOLE TICK under `set -e -o pipefail` on one transient blip. A GET/HEAD
# is idempotent, so it should retry instead. POST/PATCH/DELETE must NEVER
# retry here -- they can land server-side and still time out client-side, and
# a naive retry would double-post/double-act. Stub `curl` itself (not `_fj`)
# with a call-counter file so the real retry loop runs; no-op `sleep` so the
# retry delay doesn't actually pause the test (same pattern as the
# forgejo_request_review retry tests above). Re-source first: earlier
# fixtures above redefine `_fj` itself (bash function defs aren't scoped to
# their enclosing function), so the real _fj must be restored before testing
# it directly.
echo "== _fj: bounded retry on GET/HEAD, never on writes (igor#425) =="
. "$HERE/../lib/forgejo.sh"
sleep() { :; }

RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  if [ "$n" -eq 1 ]; then return 28; else printf '{"ok":true}'; return 0; fi
}
OUT=$(_fj GET /repos/acme/x/pulls/1/reviews); RC=$?
eq "GET: timeout then success -> rc 0" "0" "$RC"
eq "GET: timeout then success -> returns the successful body" '{"ok":true}' "$OUT"
eq "GET: retried exactly once (2 attempts total)" "2" "$(cat "$RETRY_STATE")"
rm -f "$RETRY_STATE"

RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  return 28
}
OUT=$(_fj GET /repos/acme/x/pulls/1/reviews); RC=$?
eq "GET: persistent timeout -> gives up, rc != 0" "true" "$([ "$RC" -ne 0 ] && echo true || echo false)"
eq "GET: persistent timeout -> bounded attempts (not infinite)" \
  "$((FORGEJO_RETRY_COUNT + 1))" "$(cat "$RETRY_STATE")"
rm -f "$RETRY_STATE"

# An HTTP error is an ANSWER, not a hiccup. With `-sf`, curl exits 22 for every
# HTTP >= 400: the v15 Actions-API 404 probe above is the NORMAL response there,
# a 403 is a rate-limit that wants backing off rather than hammering, a 401 is a
# bad token. Retrying any of them triples the request count and the wall clock
# for a result that will not change -- and on an unhealthy instance that turns a
# fast guarded miss into a slow one, which is the failure mode this whole change
# exists to avoid. Only transport codes (7/28/35/52/56) are retryable.
RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  return 22
}
OUT=$(_fj GET /repos/acme/x/actions/runs); RC=$?
eq "GET: HTTP error (curl 22) -> attempted exactly once, never retried" "1" "$(cat "$RETRY_STATE")"
eq "GET: HTTP error -> curl's own exit code is preserved" "22" "$RC"
ERRTXT=$(_fj GET /repos/acme/x/actions/runs 2>&1 >/dev/null)
eq "GET: HTTP error stays SILENT (a 404 for an absent agent.json is the common path)" \
  "" "$ERRTXT"
rm -f "$RETRY_STATE"

# igor#424: a tick died `status=28` with no error line at all, leaving nothing to
# separate a network blip from a harness bug. Exhausting every retry on a
# transport failure must say so -- and must say it on STDERR, or the message
# lands inside the caller's `$( )` and becomes the value.
RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  return 28
}
GIVEUP_ERR=$(_fj GET /repos/acme/x/pulls/1/reviews 2>&1 >/dev/null)
GIVEUP_OUT=$(_fj GET /repos/acme/x/pulls/1/reviews 2>/dev/null)
eq "exhausted retries -> logs the give-up" "true" \
  "$(grep -q 'failed after' <<<"$GIVEUP_ERR" && echo true || echo false)"
eq "give-up line names the curl exit code" "true" \
  "$(grep -q 'curl exit 28' <<<"$GIVEUP_ERR" && echo true || echo false)"
eq "give-up line names the method and path" "true" \
  "$(grep -q 'GET /repos/acme/x/pulls/1/reviews' <<<"$GIVEUP_ERR" && echo true || echo false)"
eq "give-up goes to stderr, NOT into the caller's captured stdout" "" "$GIVEUP_OUT"
rm -f "$RETRY_STATE"

RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  return 7
}
_fj GET /repos/acme/x/pulls >/dev/null 2>&1
eq "GET: connect failure (curl 7) IS retried (transport, not HTTP)" \
  "$((FORGEJO_RETRY_COUNT + 1))" "$(cat "$RETRY_STATE")"
rm -f "$RETRY_STATE"

RETRY_STATE=$(mktemp)
curl() {
  local n; n=$(cat "$RETRY_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$RETRY_STATE"
  return 28
}
_fj POST /repos/acme/x/issues/1/comments '{"body":"hi"}' >/dev/null 2>&1
eq "POST: never retried even on failure (exactly 1 attempt)" "1" "$(cat "$RETRY_STATE")"
rm -f "$RETRY_STATE"
unset -f curl sleep

# forgejo_pr_actionable_request_changes (igor#425): the Signal-1 pickup check
# factored out of tick.sh's PR-review loop specifically so a fetch failure
# degrades to "no signal" instead of propagating a fatal exit. Stubs `_fj`
# directly (like the fixtures above), so these don't depend on the retry loop.
echo "== forgejo_pr_actionable_request_changes: pickup signal, best-effort (igor#425) =="
parc() { local fx="$1"; _fj() { printf '%s' "$fx"; }; forgejo_pr_actionable_request_changes acme/x 42 bot; }

LIVE_RC='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","stale":false,"dismissed":false,"submitted_at":"2026-01-01T00:00:00Z"}]'
eq "live REQUEST_CHANGES -> returns that review" "REQUEST_CHANGES" "$(jq -r '.state' <<<"$(parc "$LIVE_RC")")"

STALE_RC='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","stale":true,"dismissed":false,"submitted_at":"2026-01-01T00:00:00Z"}]'
eq "stale REQUEST_CHANGES -> not actionable (empty)" "" "$(parc "$STALE_RC")"

DISMISSED_RC='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","stale":false,"dismissed":true,"submitted_at":"2026-01-01T00:00:00Z"}]'
eq "dismissed REQUEST_CHANGES -> not actionable (empty)" "" "$(parc "$DISMISSED_RC")"

APPROVED_RC='[{"user":{"login":"josh"},"state":"APPROVED","stale":false,"dismissed":false,"submitted_at":"2026-01-01T00:00:00Z"}]'
eq "latest review APPROVED -> empty (no request-changes signal)" "" "$(parc "$APPROVED_RC")"

eq "no reviews at all -> empty" "" "$(parc '[]')"

# The regression this guards: a transient fetch failure (curl exit 28) on this
# read must degrade to "no signal", NOT propagate a nonzero exit that would
# abort the caller's scan loop under `set -e -o pipefail` -- exactly the crash
# this issue reports (two exit-28 ticks landing in this PR-review pickup scan).
frc_fail() { _fj() { return 28; }; forgejo_pr_actionable_request_changes acme/x 42 bot; }
eq "fetch failure -> empty (best-effort, not fatal)" "" "$(frc_fail)"

(
  set -euo pipefail
  _fj() { return 28; }
  RESULT=$(forgejo_pr_actionable_request_changes acme/x 42 bot)
  [ -z "$RESULT" ]
)
eq "fetch failure under set -e -o pipefail does not abort the caller" "0" "$?"

# Structural regression net: the PR-review pickup Signal-1 loop in tick.sh
# must call the guarded helper, not re-inline the unguarded fetch+jq this
# issue fixed. Anchored to the ASSIGNMENT, not a bare name match -- the diff
# adds a comment mentioning the helper two lines above the call, so a plain
# `grep -q <name>` would pass on the comment alone and could never fail for
# the reason it exists.
echo "== tick.sh: PR-review pickup Signal 1 uses the guarded helper (igor#425) =="
TICK="$HERE/tick.sh"
eq "tick.sh assigns latest_review from the guarded helper (code, not a comment)" "1" \
  "$(grep -cE '^[[:space:]]*latest_review=\$\(forgejo_pr_actionable_request_changes ' "$TICK")"
# And the unguarded shape is gone: the crash was a bare `$(_fj-fed fn | jq)`
# assignment, whose pipeline status is curl's under `pipefail`. Every surviving
# forgejo_pr_non_bot_reviews call site in tick.sh must carry an `|| echo`
# fallback -- the one that didn't is what took the tick down.
eq "every forgejo_pr_non_bot_reviews call in tick.sh is || echo-guarded" \
  "$(grep -c 'forgejo_pr_non_bot_reviews' "$TICK")" \
  "$(grep 'forgejo_pr_non_bot_reviews' "$TICK" | grep -c '|| echo')"

if [ "$FAIL" -eq 0 ]; then echo "test-forgejo: all checks passed"; exit 0; fi
echo "test-forgejo: $FAIL check(s) FAILED"
exit 1
