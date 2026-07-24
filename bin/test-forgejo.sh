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

if [ "$FAIL" -eq 0 ]; then echo "test-forgejo: all checks passed"; exit 0; fi
echo "test-forgejo: $FAIL check(s) FAILED"
exit 1
