#!/usr/bin/env bash
# test-gitlab.sh -- unit tests for lib/gitlab.sh, the GitLab port of the forge
# adapter. Covers the things that are ADAPTATIONS rather than translations and
# would fail silently if wrong: the issue/MR shims, the Agent intake gate, the
# add_labels= trap, system-note filtering, the synthesized review contract, the
# CI-state fold, and the deliberately-failing merge. Skip-safe: needs jq; exits
# 0 with a notice if absent, like the other bin/test-*.sh. Every boundary (_gl,
# curl) is stubbed -- no network, no real state.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-gitlab: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
export GITLAB_URL="https://gitlab.invalid" GITLAB_TOKEN="test-token"
# _gl persists its rate-limit counters under AGENT_STATE_DIR and reads them
# before every request. Redirected at the TOP of the file rather than beside
# the pacing section that needs it: "no real state" is a property of the whole
# suite, and any section that reaches the real `_gl` -- today or after a later
# edit -- would otherwise read production's counters and sleep off a real
# GitLab window. Exported, so child processes and subshells see it too.
RLSTATE="$(mktemp -d)"
export AGENT_STATE_DIR="$RLSTATE"
# shellcheck source=../lib/gitlab.sh
. "$HERE/../lib/gitlab.sh"
# shellcheck source=../lib/testlib.sh
. "$HERE/../lib/testlib.sh"

# Sections below stub _gl_paged wholesale. Keep a copy of the real one under
# another name so a later section can restore it rather than losing it for the
# rest of the file -- same pattern as bin/test-automerge.sh.
eval "$(declare -f _gl_paged | sed '1s/^_gl_paged/_real_gl_paged/')"
_restore_paged() { eval "$(declare -f _real_gl_paged | sed '1s/^_real_gl_paged/_gl_paged/')"; }

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }

echo "== required-and-explicit env (no optional-with-default knobs) =="
# A clean shell sourcing lib/gitlab.sh without GITLAB_TOKEN must fail fast and
# loudly rather than issue unauthenticated requests that 401 one call at a time.
ENVOUT=$(env -i HOME="$HOME" PATH="$PATH" GITLAB_URL="https://x.invalid" bash -c '
  set -uo pipefail
  . "'"$HERE"'/../lib/gitlab.sh"
' 2>&1); ENVRC=$?
if [ "$ENVRC" -ne 0 ]; then printf '  + %s\n' "unset GITLAB_TOKEN fails fast at source time"
else printf '  x %s\n' "unset GITLAB_TOKEN fails fast at source time"; FAIL=$((FAIL + 1)); fi
has "failure names the var" "$ENVOUT" "GITLAB_TOKEN"

echo "== project-path and file-path encoding =="
eq "_gl_proj encodes the slash"        "sherver%2Fdistillery" "$(_gl_proj sherver/distillery)"
eq "_gl_proj leaves a bare name alone" "distillery"           "$(_gl_proj distillery)"
eq "_gl_path encodes a nested path"    "a%2Fb%2Fc.json"       "$(_gl_path a/b/c.json)"
eq "_gl_path encodes a space"          "two%20words"          "$(_gl_path 'two words')"

echo "== issue shim: single object AND array (igor: a list-only bug would starve the grind) =="
ISSUE='{"iid":7,"id":9001,"title":"T","description":"BODY","author":{"username":"igorbot"},"labels":["Agent","Kind/Security"]}'
SH=$(printf '%s' "$ISSUE" | _gl_issue_shim)
eq "object: number <- iid"       "7"        "$(jq -r '.number' <<<"$SH")"
eq "object: body <- description" "BODY"     "$(jq -r '.body' <<<"$SH")"
eq "object: user.login <- author.username" "igorbot" "$(jq -r '.user.login' <<<"$SH")"
eq "object: labels become {name} objects"  "Agent"   "$(jq -r '.labels[0].name' <<<"$SH")"
SHA=$(printf '[%s,%s]' "$ISSUE" "$ISSUE" | _gl_issue_shim)
eq "array: both entries shimmed, not passed through" "7 7" "$(jq -r '[.[].number]|join(" ")' <<<"$SHA")"

echo "== shims populate repository.full_name (the ~9h outage of 2026-10-09) =="
# bin/tick.sh reads .repository.full_name off the CROSS-PROJECT assigned-issue
# and assigned-MR results (recovery sweep at :4020, PR-review pickup at :4130
# and :4143). GitLab returns no project path on those endpoints -- only a
# numeric project_id -- so without this the sweep saw "null#8", the follow-up
# API call 404'd, curl exited 22, and errexit killed the tick BEFORE the
# unassign that clears the orphan. Every later tick repeated it forever.
REFI='{"iid":8,"title":"t","description":"d","author":{"username":"igorbot"},"labels":[],"references":{"short":"#8","relative":"#8","full":"sherver/igor#8"}}'
eq "issue: full_name from references.full" "sherver/igor" "$(printf '%s' "$REFI" | _gl_issue_shim | jq -r '.repository.full_name')"
eq "issue: array form too"                 "sherver/igor" "$(printf '[%s]' "$REFI" | _gl_issue_shim | jq -r '.[0].repository.full_name')"
eq "issue: absent references -> empty, NOT null" "" "$(printf '%s' '{"iid":9,"description":"","author":{"username":"u"},"labels":[]}' | _gl_issue_shim | jq -r '.repository.full_name')"
REFM='{"iid":2,"state":"opened","source_branch":"agent/8-x","target_branch":"master","sha":"abc","description":"d","author":{"username":"igorbot"},"references":{"full":"sherver/igor!2"}}'
eq "MR: full_name from references.full"    "sherver/igor" "$(printf '%s' "$REFM" | _gl_mr_shim | jq -r '.repository.full_name')"
eq "MR: array form too"                    "sherver/igor" "$(printf '[%s]' "$REFM" | _gl_mr_shim | jq -r '.[0].repository.full_name')"
# A project path can itself contain no '#', but a subgroup path contains '/' --
# split on '#' only, so nested groups survive.
eq "nested group path survives" "sherver/sub/deep" "$(printf '%s' '{"iid":1,"description":"","author":{"username":"u"},"labels":[],"references":{"full":"sherver/sub/deep#1"}}' | _gl_issue_shim | jq -r '.repository.full_name')"

echo "== MR shim: GitLab's merged state folded back to Forgejo's closed+merged pair =="
mrshim() { printf '%s' "$1" | _gl_mr_shim; }
eq "opened -> open, merged false"  "open false"   "$(mrshim '{"iid":3,"state":"opened","source_branch":"agent/1","target_branch":"master","sha":"abc","description":"d","author":{"username":"igorbot"}}' | jq -r '"\(.state) \(.merged)"')"
eq "merged -> closed, merged TRUE" "closed true"  "$(mrshim '{"iid":4,"state":"merged","source_branch":"x","target_branch":"master","sha":"a","description":"","author":{"username":"u"}}'  | jq -r '"\(.state) \(.merged)"')"
eq "closed -> closed, merged false" "closed false" "$(mrshim '{"iid":5,"state":"closed","source_branch":"x","target_branch":"master","sha":"a","description":"","author":{"username":"u"}}'  | jq -r '"\(.state) \(.merged)"')"
eq "head.ref <- source_branch"     "agent/1"      "$(mrshim '{"iid":3,"state":"opened","source_branch":"agent/1","target_branch":"master","sha":"abc","description":"d","author":{"username":"igorbot"}}' | jq -r '.head.ref')"
eq "base.ref <- target_branch"     "master"       "$(mrshim '{"iid":3,"state":"opened","source_branch":"agent/1","target_branch":"master","sha":"abc","description":"d","author":{"username":"igorbot"}}' | jq -r '.base.ref')"

echo "== shim: .mergeable and .html_url (automerge gated on fields GitLab lacks) =="
# automerge_mergeable gates on `.mergeable == true`. GitLab has no such
# boolean -- it reports detailed_merge_status. Without the mapping the field was
# ABSENT, so `.mergeable == true` was false for every MR and automerge logged
# "not cleanly mergeable -- skipping" forever on MRs GitLab itself reported as
# can_be_merged. Two APPROVEd posts sat unmergeable on that.
m() { printf '%s' "$1" | _gl_mr_shim; }
eq "detailed=mergeable -> true" "true" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"detailed_merge_status":"mergeable"}' | jq -r '.mergeable')"
eq "detailed=conflict -> false" "false" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"detailed_merge_status":"conflict"}' | jq -r '.mergeable')"
# "checking" means GitLab has not finished computing it. The honest answer is
# "not yet", and the next tick re-reads -- NOT an optimistic true.
eq "detailed=checking -> false, never optimistic" "false" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"detailed_merge_status":"checking"}' | jq -r '.mergeable')"
eq "detailed=ci_still_running -> false" "false" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"detailed_merge_status":"ci_still_running"}' | jq -r '.mergeable')"
# Legacy fallback for an instance predating detailed_merge_status.
eq "no detailed, merge_status=can_be_merged -> true" "true" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"merge_status":"can_be_merged"}' | jq -r '.mergeable')"
eq "neither field -> false (unknown is not mergeable)" "false" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"}}' | jq -r '.mergeable')"
eq "html_url aliases web_url" "https://gitlab.invalid/x/-/merge_requests/1" \
  "$(m '{"iid":1,"state":"opened","source_branch":"a","target_branch":"master","sha":"s","description":"","author":{"username":"u"},"web_url":"https://gitlab.invalid/x/-/merge_requests/1"}' | jq -r '.html_url')"
eq "issue shim gets html_url too" "https://gitlab.invalid/x/-/issues/9" \
  "$(printf '%s' '{"iid":9,"description":"","author":{"username":"u"},"labels":[],"web_url":"https://gitlab.invalid/x/-/issues/9"}' | _gl_issue_shim | jq -r '.html_url')"

echo "== find_claimable: the intake gate. Must fail CLOSED. =="
# Four issues: claimable; blocked; assigned to a third party; assigned solely
# to the reviewer (still claimable); and one WITHOUT the Agent label, to prove
# the client-side re-verify holds even if the server ignored the filter.
_gl() { cat <<'JSON'
[
 {"iid":1,"title":"claimable","description":"","created_at":"2026-01-01T00:00:00Z","author":{"username":"igorbot"},"labels":["Agent"],"assignees":[]},
 {"iid":2,"title":"blocked","description":"","created_at":"2026-01-02T00:00:00Z","author":{"username":"igorbot"},"labels":["Agent","Status/Blocked"],"assignees":[]},
 {"iid":3,"title":"taken","description":"","created_at":"2026-01-03T00:00:00Z","author":{"username":"igorbot"},"labels":["Agent"],"assignees":[{"username":"someoneelse"}]},
 {"iid":4,"title":"reviewer-held","description":"","created_at":"2026-01-04T00:00:00Z","author":{"username":"igorbot"},"labels":["Agent"],"assignees":[{"username":"joshtronic"}]},
 {"iid":5,"title":"unlabeled","description":"","created_at":"2026-01-05T00:00:00Z","author":{"username":"igorbot"},"labels":[],"assignees":[]}
]
JSON
}
CL=$(forgejo_find_claimable acme/x joshtronic)
eq "picks only claimable + reviewer-held" "1 4" "$(jq -r '[.[].number]|join(" ")' <<<"$CL")"
eq "oldest first"                         "1"   "$(jq -r '.[0].number' <<<"$CL")"
eq "shim applied AFTER filtering (number is not null)" "1" "$(jq -r '.[0].number' <<<"$CL")"
eq "labels still readable as objects post-shim" "Agent" "$(jq -r '.[0].labels[0].name' <<<"$CL")"
CL2=$(forgejo_find_claimable acme/x "")
eq "no reviewer arg: reviewer-held is NOT claimable" "1" "$(jq -r '[.[].number]|join(" ")' <<<"$CL2")"
unset -f _gl

echo "== claim quiet period (pure date math, carried over verbatim) =="
. "$HERE/../lib/gitlab.sh" 2>/dev/null
eq "fresh edit -> full window remains" "900" "$(forgejo_claim_quiet_seconds_remaining "2026-01-01T00:00:00Z" "$(date -d '2026-01-01T00:00:00Z' +%s)")"
eq "exactly at the boundary -> 0 (claimable)" "0" "$(forgejo_claim_quiet_seconds_remaining "2026-01-01T00:00:00Z" "$(( $(date -d '2026-01-01T00:00:00Z' +%s) + 900 ))")"
eq "past the window -> 0"             "0"   "$(forgejo_claim_quiet_seconds_remaining "2026-01-01T00:00:00Z" "$(( $(date -d '2026-01-01T00:00:00Z' +%s) + 5000 ))")"
eq "unparseable timestamp fails OPEN" "0"   "$(forgejo_claim_quiet_seconds_remaining "not-a-date" 1 2>/dev/null)"
eq "EMPTY timestamp fails OPEN (not 'now')" "0" "$(forgejo_claim_quiet_seconds_remaining "" 1 2>/dev/null)"

echo "== issues and MRs are SEPARATE iid spaces -- comments must not cross =="
# On Forgejo a PR IS an issue and one endpoint served both. On GitLab the iid
# spaces are separate, so forgejo_comment with an MR iid either 404s or posts
# onto an UNRELATED ISSUE sharing the number. sherver/igor has both an issue #4
# and an MR !4, so a review verdict would have landed on the issue.
CAPPATH=""
_gl() { CAPPATH="$2"; printf '{}'; }
forgejo_comment acme/x 4 "body"
case "$CAPPATH" in */issues/4/notes) printf '  + %s
' "forgejo_comment targets /issues/:iid/notes" ;;
  *) printf '  x %s: got [%s]\n' "forgejo_comment should target issues" "$CAPPATH"; FAIL=$((FAIL+1)) ;; esac
forgejo_pr_comment acme/x 4 "body"
case "$CAPPATH" in */merge_requests/4/notes) printf '  + %s
' "forgejo_pr_comment targets /merge_requests/:iid/notes" ;;
  *) printf '  x %s: got [%s]\n' "forgejo_pr_comment should target merge_requests" "$CAPPATH"; FAIL=$((FAIL+1)) ;; esac
case "$CAPPATH" in */issues/*) printf '  x %s\n' "forgejo_pr_comment must NEVER touch an issue path"; FAIL=$((FAIL+1)) ;;
  *) printf '  + %s
' "forgejo_pr_comment never touches an issue path" ;; esac
# log_time has the same split; default stays issues, MR callers pass the kind.
forgejo_log_time acme/x 4 60
case "$CAPPATH" in */issues/4/add_spent_time) printf '  + %s
' "log_time defaults to issues" ;;
  *) printf '  x %s: got [%s]\n' "log_time default" "$CAPPATH"; FAIL=$((FAIL+1)) ;; esac
forgejo_log_time acme/x 4 60 merge_requests
case "$CAPPATH" in */merge_requests/4/add_spent_time) printf '  + %s
' "log_time honours an explicit merge_requests kind" ;;
  *) printf '  x %s: got [%s]\n' "log_time kind" "$CAPPATH"; FAIL=$((FAIL+1)) ;; esac
unset -f _gl
. "$HERE/../lib/gitlab.sh" 2>/dev/null

echo "== labels: add MUST use add_labels=, never labels= (silently drops the rest) =="
CAPTURED=""
_gl() { CAPTURED="$3"; printf '{}'; }
forgejo_add_label acme/x 1 Agent
has "add_label sends add_labels"        "$CAPTURED" '"add_labels"'
case "$CAPTURED" in *'"labels"'*) printf '  x %s\n' "add_label must NOT send a bare labels= (would replace the set)"; FAIL=$((FAIL+1));; *) printf '  + %s\n' "add_label does not send a bare labels=";; esac
forgejo_remove_label acme/x 1 Agent
has "remove_label sends remove_labels"  "$CAPTURED" '"remove_labels"'
unset -f _gl

echo "== pr_comments: GitLab system notes must be filtered out =="
_gl() { cat <<'JSON'
[
 {"id":1,"body":"a real comment","system":false,"author":{"username":"joshtronic"},"created_at":"2026-01-01T00:00:00Z"},
 {"id":2,"body":"added Agent label","system":true,"author":{"username":"igorbot"},"created_at":"2026-01-01T00:01:00Z"},
 {"id":3,"body":"shadow-review sha=deadbeef","system":false,"author":{"username":"igorbot"},"created_at":"2026-01-01T00:02:00Z"}
]
JSON
}
PC=$(forgejo_pr_comments acme/x 1)
eq "drops the system note"              "2"       "$(jq 'length' <<<"$PC")"
eq "keeps human + bot real comments"    "1 3"     "$(jq -r '[.[].id]|join(" ")' <<<"$PC")"
eq "user.login <- author.username"      "joshtronic" "$(jq -r '.[0].user.login' <<<"$PC")"
eq "marker-contains counts only the bot's" "1" "$(forgejo_pr_has_comment_containing acme/x 1 igorbot 'sha=deadbeef')"
eq "a system note cannot satisfy the marker scan" "0" "$(forgejo_pr_has_comment_containing acme/x 1 igorbot 'added Agent label')"
eq "prefix count matches the bot's comment" "1" "$(forgejo_count_bot_comments_matching acme/x 1 igorbot 'shadow-review')"
unset -f _gl

echo "== the synthesized review contract (the one real adaptation) =="
# Stub the three calls forgejo_pr_reviews makes, keyed on path. The fixtures
# are plain globals the stub reads, so each scenario is a two-line reassignment.
APPROVALS_FIXTURE='{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}'
DISCUSSIONS_FIXTURE='[]'
_gl() {
  case "$2" in
    */approvals)    printf '%s' "$APPROVALS_FIXTURE" ;;
    */discussions*) printf '%s' "$DISCUSSIONS_FIXTURE" ;;
    *)              printf '{"sha":"HEADSHA"}' ;;
  esac
}
_mk_reviews() { APPROVALS_FIXTURE="$1"; DISCUSSIONS_FIXTURE="$2"; }

# an unresolved, resolvable, non-bot DIFF thread on the current head
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":false,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"HEADSHA"}}]}]'
RV=$(forgejo_pr_reviews acme/x 1)
eq "unresolved non-bot thread -> REQUEST_CHANGES" "REQUEST_CHANGES" "$(jq -r '.[0].state' <<<"$RV")"
eq "  not stale (thread sha == head)"             "false"           "$(jq -r '.[0].stale' <<<"$RV")"
eq "  not dismissed"                              "false"           "$(jq -r '.[0].dismissed' <<<"$RV")"
eq "actionable: yes"  "REQUEST_CHANGES" "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot | jq -r '.state')"

# RESOLVED thread -> COMMENT + dismissed, so it must NOT be actionable
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":true,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"HEADSHA"}}]}]'
eq "resolved thread -> COMMENT"   "COMMENT" "$(forgejo_pr_reviews acme/x 1 | jq -r '.[0].state')"
eq "resolved thread -> dismissed" "true"    "$(forgejo_pr_reviews acme/x 1 | jq -r '.[0].dismissed')"
eq "actionable: no (resolved)"    ""        "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot)"

# STALE thread (made against an older sha) must not block
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":false,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"OLDSHA"}}]}]'
eq "thread on an old sha -> stale" "true" "$(forgejo_pr_reviews acme/x 1 | jq -r '.[0].stale')"
eq "actionable: no (stale)"        ""     "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot)"

# BOT-authored unresolved thread must be filtered out -- the bot must never
# trigger its own rework.
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":false,"author":{"username":"igorbot"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"HEADSHA"}}]}]'
eq "bot's own thread filtered from non_bot_reviews" "0" "$(forgejo_pr_non_bot_reviews acme/x 1 igorbot | jq 'length')"
eq "actionable: no (bot's own)"                     ""  "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot)"

# A plain (non-resolvable) conversation note is a COMMENT, never a block.
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":false,"resolved":false,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z"}]}]'
eq "plain note -> COMMENT"    "COMMENT" "$(forgejo_pr_reviews acme/x 1 | jq -r '.[0].state')"
eq "actionable: no (plain note)" ""     "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot)"

# An APPROVAL shows up as APPROVED, and a later approval supersedes an
# earlier objection (the automerge path reads the LATEST).
_mk_reviews '{"approved_by":[{"user":{"username":"joshtronic"}}],"updated_at":"2026-03-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":false,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"HEADSHA"}}]}]'
eq "approval present"                "APPROVED" "$(forgejo_pr_reviews acme/x 1 | jq -r '[.[]|select(.state=="APPROVED")][0].state')"
eq "later approval supersedes the objection" "" "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot)"

# Empty/garbage bodies must not take the whole contract down to "no reviews"
# silently -- --argjson on an empty string is a jq PARSE ERROR.
eval '_gl() { printf ""; }'
eq "empty API bodies -> empty array, no crash" "0" "$(forgejo_pr_reviews acme/x 1 | jq 'length' 2>/dev/null)"
unset -f _gl

echo "== system threads are not reviews (live sweep, 2026-10-11) =="
# A human opens a change-request thread, then retitles the MR. GitLab records
# the retitle as its own SYSTEM discussion thread, newer than the request. If
# that counts as a COMMENT review, it becomes the "latest" and buries the
# change request -- the bot never sees it was asked for changes.
# The review-contract section above unsets its _gl stub when it finishes, so
# reinstate it here; without it this block silently hits the real network.
_gl() {
  case "$2" in
    */approvals)    printf '%s' "$APPROVALS_FIXTURE" ;;
    */discussions*) printf '%s' "$DISCUSSIONS_FIXTURE" ;;
    *)              printf '{"sha":"HEADSHA"}' ;;
  esac
}
_mk_reviews '{"approved_by":[],"updated_at":"2026-01-01T00:00:00Z"}' \
  '[{"notes":[{"resolvable":true,"resolved":false,"author":{"username":"joshtronic"},"created_at":"2026-02-01T00:00:00Z","position":{"head_sha":"HEADSHA"}}]},
    {"notes":[{"system":true,"resolvable":false,"author":{"username":"joshtronic"},"created_at":"2026-02-02T00:00:00Z","body":"changed title from x to y"}]},
    {"notes":[{"system":true,"resolvable":false,"author":{"username":"joshtronic"},"created_at":"2026-02-03T00:00:00Z","body":"assigned to @igorbot"}]}]'
eq "system threads produce no review entries" "1" "$(forgejo_pr_reviews acme/x 1 | jq 'length')"
eq "a later system note does not bury the change request" "REQUEST_CHANGES" \
  "$(forgejo_pr_actionable_request_changes acme/x 1 igorbot | jq -r '.state')"
unset -f _gl

echo "== CI state fold =="
eq "success"              "success" "$(_gl_map_ci_state success)"
eq "skipped counts green" "success" "$(_gl_map_ci_state skipped)"
eq "failed"               "failure" "$(_gl_map_ci_state failed)"
eq "canceled is a failure" "failure" "$(_gl_map_ci_state canceled)"
eq "running is pending"   "pending" "$(_gl_map_ci_state running)"
eq "manual is PENDING, not green"  "pending" "$(_gl_map_ci_state manual)"
eq "empty stays empty"    ""        "$(_gl_map_ci_state '')"
eq "unknown -> error"     "error"   "$(_gl_map_ci_state wat)"

# A pipeline on the commit wins over external statuses.
_gl() { case "$2" in */statuses*) printf '[]' ;; *) printf '{"last_pipeline":{"status":"failed"}}' ;; esac; }
eq "pipeline status wins" "failure" "$(forgejo_commit_status acme/x abc)"
# No pipeline: fold the external statuses a local runner POSTed.
_gl() { case "$2" in
  */statuses*) printf '[{"status":"success"},{"status":"skipped"}]' ;;
  *) printf '{}' ;; esac; }
eq "all-terminal-non-failing folds to success" "success" "$(forgejo_commit_status acme/x abc)"
_gl() { case "$2" in
  */statuses*) printf '[{"status":"success"},{"status":"failed"}]' ;;
  *) printf '{}' ;; esac; }
eq "any failure loses" "failure" "$(forgejo_commit_status acme/x abc)"
_gl() { case "$2" in
  */statuses*) printf '[{"status":"success"},{"status":"running"}]' ;;
  *) printf '{}' ;; esac; }
eq "any running -> pending" "pending" "$(forgejo_commit_status acme/x abc)"
_gl() { case "$2" in */statuses*) printf '[]' ;; *) printf '{}' ;; esac; }
eq "no statuses at all -> empty (unknown, not green)" "" "$(forgejo_commit_status acme/x abc)"
unset -f _gl

echo "== pr_files/pr_diff: read /diffs, not /changes (igor#15 -- /changes collapses lockfiles and big diffs) =="
# /diffs is paginated (_gl_paged), so a stub must terminate page 2 with [].
_gl() { case "$2" in
  *"/diffs"*page=1*) cat <<'JSON'
[
 {"old_path":"a.sh","new_path":"a.sh","new_file":false,"deleted_file":false,"renamed_file":false,
  "too_large":false,"collapsed":false,
  "diff":"--- a/a.sh\n+++ b/a.sh\n@@ -1 +1,2 @@\n-old line\n+new line\n+another\n"},
 {"old_path":"b.sh","new_path":"b.sh","new_file":true,"deleted_file":false,"renamed_file":false,
  "too_large":false,"collapsed":false,
  "diff":"+++ b/b.sh\n@@ -0,0 +1 @@\n+brand new\n"}
]
JSON
    ;;
  *"/diffs"*) printf '[]' ;;
esac
}
PF=$(forgejo_pr_files acme/x 1)
eq "two files"                   "2"        "$(jq 'length' <<<"$PF")"
eq "additions counted, +++ excluded" "2"    "$(jq -r '.[0].additions' <<<"$PF")"
eq "deletions counted, --- excluded" "1"    "$(jq -r '.[0].deletions' <<<"$PF")"
eq "new_file -> added"           "added"    "$(jq -r '.[1].status' <<<"$PF")"
eq "otherwise -> modified"       "modified" "$(jq -r '.[0].status' <<<"$PF")"
has "pr_diff reassembles a git header" "$(forgejo_pr_diff acme/x 1)" "diff --git a/a.sh b/a.sh"
unset -f _gl
# A payload that isn't an array at all must be "unknown" (nonzero, no output),
# never an empty-but-successful list the gate would read as "small".
_gl() { printf '{"message":"403 Forbidden"}'; }
no "pr_files: non-array payload is nonzero" forgejo_pr_files acme/x 1
eq "pr_files: and emits nothing" "" "$(forgejo_pr_files acme/x 1 2>/dev/null)"
unset -f _gl

echo "== pr_files/pr_diff: fail closed on anything GitLab still withholds =="
# A generated lockfile with a NON-empty diff (the common case -- GitLab marks
# it generated_file but still ships the hunks on /diffs) must be fully counted
# and fully visible, same as any other file.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '%s' '[{"old_path":"package-lock.json","new_path":"package-lock.json","new_file":false,"deleted_file":false,"renamed_file":false,"generated_file":true,"too_large":false,"collapsed":false,"diff":"--- a/package-lock.json\n+++ b/package-lock.json\n@@ -1,2 +1,3 @@\n-old\n+new\n+added\n"}]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
PF=$(forgejo_pr_files acme/x 1)
eq "a generated lockfile with a real diff is still counted" "2" "$(jq -r '.[0].additions' <<<"$PF")"
has "and its hunk reaches the reviewer" "$(forgejo_pr_diff acme/x 1)" "+new"
unset -f _gl

# too_large:true with collapsed:false -- GitLab withheld the diff entirely.
# pr_files must refuse to answer (the risk gate reads "unknown", not "0
# lines"); pr_diff must still print the rest of the diff plus a marker line
# naming what it can't show. The flags are deliberately split across this
# fixture and the two below so each clause of the withheld predicate is pinned
# on its own: with both set true here, dropping either clause left every
# assertion green.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '%s' '[
    {"old_path":"a.sh","new_path":"a.sh","new_file":false,"deleted_file":false,"renamed_file":false,"too_large":false,"collapsed":false,"diff":"+++ b/a.sh\n@@ -0,0 +1 @@\n+hi\n"},
    {"old_path":"huge.bin","new_path":"huge.bin","new_file":false,"deleted_file":false,"renamed_file":false,"too_large":true,"collapsed":false,"diff":""}
  ]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
no "too_large entry makes pr_files refuse to answer" forgejo_pr_files acme/x 1
eq "and emits nothing" "" "$(forgejo_pr_files acme/x 1 2>/dev/null)"
has "pr_diff still prints the rest" "$(forgejo_pr_diff acme/x 1)" "+hi"
has "pr_diff flags the withheld file" "$(forgejo_pr_diff acme/x 1)" "diff withheld by GitLab (too large): huge.bin"
unset -f _gl

# collapsed:true with an EMPTY diff and too_large:false -- the shape the live
# API actually produces for an oversized file (a 115KB package-lock.json added
# in one commit reads exactly this way), so it is the clause that carries the
# weight in practice.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '%s' '[{"old_path":"package-lock.json","new_path":"package-lock.json","new_file":false,"deleted_file":false,"renamed_file":false,"generated_file":true,"too_large":false,"collapsed":true,"diff":""}]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
no "collapsed with an empty diff makes pr_files refuse to answer" forgejo_pr_files acme/x 1
has "pr_diff flags it withheld" "$(forgejo_pr_diff acme/x 1)" "diff withheld by GitLab (too large): package-lock.json"
unset -f _gl

# collapsed:true but the diff IS present -- nothing was withheld, so this must
# count normally. Failing closed here would escalate ordinary MRs to a human.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '%s' '[{"old_path":"c.sh","new_path":"c.sh","new_file":false,"deleted_file":false,"renamed_file":false,"too_large":false,"collapsed":true,"diff":"--- a/c.sh\n+++ b/c.sh\n@@ -1 +1 @@\n-old\n+new\n"}]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
ok "collapsed with a diff present does not fail closed" forgejo_pr_files acme/x 1
PF=$(forgejo_pr_files acme/x 1)
eq "and its lines are counted"   "1"        "$(jq -r '.[0].additions' <<<"$PF")"
has "and its hunk reaches the reviewer" "$(forgejo_pr_diff acme/x 1)" "+new"
unset -f _gl

# A pure rename (or mode change) with an empty diff and NEITHER too_large nor
# collapsed is legitimate -- it must count 0 lines, not fail closed.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '[{"old_path":"old.sh","new_path":"new.sh","new_file":false,"deleted_file":false,"renamed_file":true,"too_large":false,"collapsed":false,"diff":""}]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
ok "a pure rename with an empty diff does not fail closed" forgejo_pr_files acme/x 1
PF=$(forgejo_pr_files acme/x 1)
eq "and counts 0 lines"          "0"        "$(jq -r '.[0].additions' <<<"$PF")"
eq "status is renamed"           "renamed"  "$(jq -r '.[0].status' <<<"$PF")"
unset -f _gl

# A two-page /diffs response must be read to the end, not just page 1.
_gl() { case "$2" in
  *"/diffs"*page=1*) printf '%s' '[{"old_path":"f1.sh","new_path":"f1.sh","new_file":false,"deleted_file":false,"renamed_file":false,"too_large":false,"collapsed":false,"diff":"+++ b/f1.sh\n@@ -0,0 +1 @@\n+one\n"}]' ;;
  *"/diffs"*page=2*) printf '%s' '[{"old_path":"f2.sh","new_path":"f2.sh","new_file":false,"deleted_file":false,"renamed_file":false,"too_large":false,"collapsed":false,"diff":"+++ b/f2.sh\n@@ -0,0 +1 @@\n+two\n"}]' ;;
  *"/diffs"*) printf '[]' ;;
esac
}
PF=$(forgejo_pr_files acme/x 1)
eq "two-page /diffs response is fully read" "2" "$(jq 'length' <<<"$PF")"
unset -f _gl

echo "== get_commit: GitLab parent_ids shimmed to Forgejo .parents[].sha =="
# The approval walk in lib/automerge.sh reads `.parents | length`. Unshimmed,
# GitLab's bare parent_ids array meant every commit had ZERO parents.
_gl() { printf '%s' '{"id":"MERGE","parent_ids":["P1","P2"],"title":"Merge branch x"}'; }
GC=$(forgejo_get_commit acme/x MERGE)
eq "get_commit: .sha <- .id"            "MERGE"  "$(jq -r .sha <<<"$GC")"
eq "get_commit: two parents"            "2"      "$(jq '.parents|length' <<<"$GC")"
eq "get_commit: second parent sha"      "P2"     "$(jq -r '.parents[1].sha' <<<"$GC")"
unset -f _gl

echo "== open_issue_assigned: numeric label IDS, resolved to names =="
# feedback_resolve_labels hands over [ids]. GitLab issue-create takes NAMES, and
# a raw "[12, 34]" would be split on the comma and CREATED as two junk labels.
POSTED="$(mktemp)"
# The label list goes through _gl_paged, so page 1 answers and page 2 is empty --
# a stub that answered every page would spin to the page cap and resolve nothing.
_gl() {
  case "$1 $2" in
    "GET /users"*)              printf '[{"id":7}]' ;;
    "GET /projects/"*"/labels"*"page=1"*) printf '[{"id":12,"name":"Kind/Bug"},{"id":34,"name":"Priority/High"},{"id":56,"name":"Other"},{"id":78,"name":"Kind/Bug, Really"}]' ;;
    "GET /projects/"*"/labels"*) printf '[]' ;;
    "POST /projects/"*"/issues") printf '%s' "$3" >"$POSTED"; printf '{"iid":9,"description":"","author":{"username":"igorbot"},"labels":[]}' ;;
  esac
}
_GL_UID_CACHE=()
forgejo_open_issue_assigned acme/x "t" "b" someone '[12,34]' >/dev/null
eq "label ids resolved to a name list" "Kind/Bug,Priority/High" "$(jq -r .labels "$POSTED")"
# A repeated id resolves to the single name it names, so the drop check has to
# compare against the DEDUPED ids -- otherwise it warns about a label that
# resolved perfectly well.
eq "duplicate ids resolve once, with nothing logged" "" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone '[12,12]' 2>&1 >/dev/null)"
eq "and the deduped name still lands" "Kind/Bug" "$(jq -r .labels "$POSTED")"
# A name carrying a comma cannot ride a comma-separated field: GitLab would
# split it and CREATE the fragments as new labels, which is the junk-label
# failure this resolution exists to prevent. Dropped, like an unresolved id.
forgejo_open_issue_assigned acme/x "t" "b" someone '[12,78]' >/dev/null 2>/dev/null
eq "a comma in a name is dropped, the rest still land" "Kind/Bug" "$(jq -r .labels "$POSTED")"
has "and the comma drop is logged" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone '[12,78]' 2>&1 >/dev/null)" "comma-bearing"
forgejo_open_issue_assigned acme/x "t" "b" someone '[]' >/dev/null
eq "empty id list omits labels entirely" "false" "$(jq 'has("labels")' "$POSTED")"
forgejo_open_issue_assigned acme/x "t" "b" someone '[999]' >/dev/null 2>/dev/null
eq "an unknown id is dropped, issue still opens" "false" "$(jq 'has("labels")' "$POSTED")"
has "an unresolved id leaves a log line" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone '[999]' 2>&1 >/dev/null)" "ids dropped"
# A caller still on the pre-cutover comma-separated-NAMES contract gets an
# unlabelled issue -- which must not be silent.
has "a non-array label argument is called out" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone 'Kind/Bug' 2>&1 >/dev/null)" "wants a JSON array of label ids"
eq "and that issue opens unlabelled, not with junk labels" "false" "$(jq 'has("labels")' "$POSTED")"
rm -f "$POSTED"; unset -f _gl
# `unset -f _gl` removes the function outright -- bash does not stack definitions
# -- so re-source to put the real _gl back for the blocks below. Unredirected: a
# syntax break in the library must surface here, not as a baffling failure below.
. "$HERE/../lib/gitlab.sh"

echo "== bot_prs_for_issue: merged folds to closed+merged, so rejection counting stays honest =="
_gl_paged() { cat <<'JSON'
[
 {"iid":10,"state":"merged","title":"done","description":"Closes #5","author":{"username":"igorbot"}},
 {"iid":11,"state":"closed","title":"rejected","description":"Closes #5","author":{"username":"igorbot"}},
 {"iid":12,"state":"opened","title":"live","description":"Closes #5","author":{"username":"igorbot"}},
 {"iid":13,"state":"closed","title":"someone else","description":"Closes #5","author":{"username":"human"}},
 {"iid":14,"state":"closed","title":"other issue","description":"Closes #99","author":{"username":"igorbot"}}
]
JSON
}
BP=$(forgejo_bot_prs_for_issue acme/x 5 igorbot)
eq "only the bot's, only this issue"  "10 11 12" "$(jq -r '[.[].number]|join(" ")' <<<"$BP")"
eq "merged -> closed + merged true"   "closed true" "$(jq -r '[.[]|select(.number==10)][0]|"\(.state) \(.merged)"' <<<"$BP")"
eq "rejected -> closed + merged false" "closed false" "$(jq -r '[.[]|select(.number==11)][0]|"\(.state) \(.merged)"' <<<"$BP")"
eq "rejection count is 1, not 2"      "1" "$(jq '[.[]|select(.state=="closed" and .merged==false)]|length' <<<"$BP")"
_restore_paged

echo "== prs_covering_issue: vendor-neutral, operates on shimmed JSON =="
PRS='[{"number":1,"title":"t","head":{"ref":"agent/42-do-thing"},"body":""},
      {"number":2,"title":"t","head":{"ref":"other"},"body":"Closes #42\n"},
      {"number":3,"title":"t","head":{"ref":"x"},"body":"this PR fixes issue 42 by prose"},
      {"number":4,"title":"t","head":{"ref":"agent/420-other"},"body":""}]'
CV=$(forgejo_prs_covering_issue "$PRS" 42)
eq "branch namespace + standalone closing line only" "1 2" "$(jq -r '[.[].number]|join(" ")' <<<"$CV")"
eq "prose mention does NOT count"   "0" "$(jq '[.[]|select(.number==3)]|length' <<<"$CV")"
eq "agent/420 is not agent/42"      "0" "$(jq '[.[]|select(.number==4)]|length' <<<"$CV")"
eq "prs_on_branches renders matches" "#1 (agent/42-do-thing)" "$(forgejo_prs_on_branches "$CV" "agent/42-do-thing")"

echo "== list_bot_repos: Developer(30) is the floor; Reporter(20) must not appear =="
_gl_paged() { cat <<'JSON'
[
 {"path_with_namespace":"sherver/a","default_branch":"master","permissions":{"project_access":{"access_level":30},"group_access":null}},
 {"path_with_namespace":"sherver/b","default_branch":"main","permissions":{"project_access":null,"group_access":{"access_level":40}}},
 {"path_with_namespace":"sherver/c","default_branch":"master","permissions":{"project_access":{"access_level":20},"group_access":null}},
 {"path_with_namespace":"sherver/d","default_branch":"master","permissions":{"project_access":{"access_level":10},"group_access":{"access_level":30}}}
]
JSON
}
LR=$(forgejo_list_bot_repos)
eq "keeps Developer and Maintainer, drops Reporter/Guest" "sherver/a sherver/b sherver/d" "$(jq -r '[.[].full_name]|join(" ")' <<<"$LR")"
eq "takes the HIGHER of project/group access" "sherver/d" "$(jq -r '[.[]|select(.full_name=="sherver/d")][0].full_name' <<<"$LR")"
eq "default_branch preserved, not assumed"    "main"      "$(jq -r '[.[]|select(.full_name=="sherver/b")][0].default_branch' <<<"$LR")"
unset -f _gl_paged
# A listing that cannot be walked to the end must be nonzero with NO output.
_gl_paged() { return 1; }
no "unwalkable listing is nonzero" forgejo_list_bot_repos
_restore_paged

echo "== merge_pr: expected to FAIL as a Developer, and must not retry (igor#597) =="
# The counter rides in a FILE, not a variable: forgejo_merge_pr runs inside
# $( ), so an incremented variable would die with the subshell and the
# assertion would read 0 no matter what the code did -- a test that cannot fail.
CURLCOUNT="$(mktemp)"; : >"$CURLCOUNT"
curl() { printf 'x' >>"$CURLCOUNT"; printf '{"message":"403 Forbidden"}\n403'; }
OUT=$(forgejo_merge_pr acme/x 1)
eq "returns code<TAB>message"  "$(printf '403\t403 Forbidden')" "$OUT"
eq "called curl exactly once (no retry)" "1" "$(wc -c <"$CURLCOUNT" | tr -d ' ')"
rm -f "$CURLCOUNT"
unset -f curl

echo "== file reads: found / missing / error are three DIFFERENT answers (igor#520) =="
curl() { printf '%s\n%s' '{"content":"aGVsbG8="}' '200'; }
eq "found carries decoded content" "$(printf 'found\thello')" "$(forgejo_repo_get_file_status acme/x f.txt)"
curl() { printf '%s\n%s' '' '404'; }
eq "404 is 'missing', not 'error'" "$(printf 'missing\t')" "$(forgejo_repo_get_file_status acme/x f.txt)"
curl() { printf '%s\n%s' '' '403'; }
eq "403 is 'error', NOT 'missing'" "$(printf 'error\t')"   "$(forgejo_repo_get_file_status acme/x f.txt)"
curl() { printf '%s\n%s' '' '502'; }
eq "502 is 'error'"                "$(printf 'error\t')"   "$(forgejo_repo_get_file_status acme/x f.txt)"
unset -f curl

echo "== _gl_paged: pages until EMPTY, not until short =="
# Page counter in a FILE for the same reason the curl counter above is: each
# _gl call happens inside $( ), so a variable would never advance.
PAGEF="$(mktemp)"; : >"$PAGEF"
_gl() {
  printf 'x' >>"$PAGEF"
  case "$(wc -c <"$PAGEF" | tr -d ' ')" in
    1) printf '[{"iid":1},{"iid":2}]' ;;   # SHORT page -- must NOT stop here
    2) printf '[{"iid":3}]' ;;
    *) printf '[]' ;;
  esac
}
eq "a short page does not end the walk" "1 2 3" "$(_gl_paged "/x" | jq -r '[.[].iid]|join(" ")')"
rm -f "$PAGEF"
unset -f _gl
_gl() { printf 'not json'; }
no "unparseable page -> nonzero" _gl_paged "/x"
unset -f _gl

echo "== _gl: paces on RateLimit-Remaining/-Reset, retries 429 via Retry-After (igor#26) =="
# `unset -f _gl` above removed the function outright (bash doesn't stack
# definitions), so re-source to get the real _gl back -- this section tests
# it directly, doubling curl itself rather than _gl. The counters it paces off
# live in $RLSTATE, redirected at the top of the file.
. "$HERE/../lib/gitlab.sh"

SLEEPLOG="$(mktemp)"; : >"$SLEEPLOG"
sleep() { printf '%s\n' "$1" >>"$SLEEPLOG"; }
_rl_clear() { rm -f "$(_gl_rl_state_file)"; : >"$SLEEPLOG"; }

# Finds the file path passed to curl's -D flag, the same way the curl double
# in bin/test-request.sh does, so a stub can hand back rate-limit headers.
_curl_header_arg() {
  local i j
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "-D" ]; then j=$((i + 1)); printf '%s' "${!j}"; return 0; fi
  done
}

_rl_clear
curl() {
  local hdr; hdr=$(_curl_header_arg "$@")
  [ -n "$hdr" ] && printf 'RateLimit-Remaining: 80\r\nRateLimit-Reset: 9999999999\r\n' >"$hdr"
  printf '{"ok":true}\n200'
}
OUT=$(_gl GET "/high")
eq "remaining well above the floor: body returned" '{"ok":true}' "$OUT"
eq "remaining well above the floor: no sleep"      "0" "$(wc -l <"$SLEEPLOG" | tr -d ' ')"
unset -f curl

# Both calls go through a COMMAND SUBSTITUTION, because that is how every real
# caller invokes _gl -- it writes the body to stdout, so the body has to be
# captured (`batch=$(_gl GET ...)` in _gl_paged, the hot paging loop igor#26
# measured) or piped. Each of those is a subshell, which is the whole point:
# counters kept in a shell variable die with it and the next request never
# paces. Calling `_gl GET /a >/dev/null` here instead would pass against an
# implementation that is a no-op in production.
_rl_clear
RESET=$(($(date +%s) + 30))
CALLS="$(mktemp)"; : >"$CALLS"
curl() {
  printf 'x' >>"$CALLS"
  local hdr n; hdr=$(_curl_header_arg "$@"); n=$(wc -c <"$CALLS" | tr -d ' ')
  if [ "$n" -eq 1 ]; then
    [ -n "$hdr" ] && printf 'RateLimit-Remaining: 5\r\nRateLimit-Reset: %s\r\n' "$RESET" >"$hdr"
    printf '{"first":true}\n200'
  else
    [ -n "$hdr" ] && printf 'RateLimit-Remaining: 80\r\nRateLimit-Reset: 9999999999\r\n' >"$hdr"
    printf '{"second":true}\n200'
  fi
}
FIRST=$(_gl GET "/a")
SECOND=$(_gl GET "/b")
eq "captured-body calls: first body returned"  '{"first":true}'  "$FIRST"
eq "captured-body calls: second body returned" '{"second":true}' "$SECOND"
eq "remaining below the floor: exactly one pacing sleep before the next call" \
  "1" "$(wc -l <"$SLEEPLOG" | tr -d ' ')"
SLEPT=$(tail -1 "$SLEEPLOG")
case "$SLEPT" in
  2[5-9]|30) printf '  + %s\n' "remaining below the floor: slept close to the reset delta (${SLEPT}s)" ;;
  *) printf '  x %s: got %ss\n' "remaining below the floor: slept close to the reset delta" "$SLEPT"; FAIL=$((FAIL + 1)) ;;
esac
rm -f "$CALLS"
unset -f curl

# The budget is per-TOKEN, and a tick runs several bin/agent-*.sh processes
# that each source lib/gitlab.sh fresh -- the scenario igor#26 actually
# measured. A fresh process with no in-memory history must still pace off what
# the previous one saw. Run under `set -euo pipefail`, the way every real
# caller runs, so the -e hazards in the new helpers are covered here too.
_rl_clear
printf '3 %s\n' "$(($(date +%s) + 30))" >"$RLSTATE/gitlab-ratelimit"
CHILD="$(mktemp)"
cat >"$CHILD" <<'CHILDEOF'
set -euo pipefail
sleep() { printf '%s\n' "$1" >>"$SLEEPLOG"; }
curl() {
  local i j hdr=""
  for ((i = 1; i <= $#; i++)); do
    [ "${!i}" = "-D" ] && { j=$((i + 1)); hdr="${!j}"; }
  done
  [ -n "$hdr" ] && printf 'RateLimit-Remaining: 90\r\nRateLimit-Reset: 9999999999\r\n' >"$hdr"
  printf '{"child":true}\n200'
}
. "$LIBGL"
BODY=$(_gl GET "/fresh")
[ "$BODY" = '{"child":true}' ] || exit 3
CHILDEOF
SLEEPLOG="$SLEEPLOG" LIBGL="$HERE/../lib/gitlab.sh" AGENT_STATE_DIR="$RLSTATE" \
  GITLAB_URL="$GITLAB_URL" GITLAB_TOKEN="$GITLAB_TOKEN" bash "$CHILD"
eq "a fresh PROCESS paces off the persisted counters" "1" "$(wc -l <"$SLEEPLOG" | tr -d ' ')"
rm -f "$CHILD"

# A bogus or far-future reset must not wedge the tick for the lifetime of the
# universe -- the sleep is capped at the length of GitLab's own window.
_rl_clear
printf '1 9999999999\n' >"$RLSTATE/gitlab-ratelimit"
_gl_rl_pace
eq "a far-future RateLimit-Reset is capped, not slept off literally" \
  "$GITLAB_RATELIMIT_MAX_SLEEP" "$(cat "$SLEEPLOG")"

_rl_clear
CALLS="$(mktemp)"; : >"$CALLS"
curl() {
  printf 'x' >>"$CALLS"
  local hdr n; hdr=$(_curl_header_arg "$@"); n=$(wc -c <"$CALLS" | tr -d ' ')
  if [ "$n" -eq 1 ]; then
    [ -n "$hdr" ] && printf 'Retry-After: 4\r\n' >"$hdr"
    printf '\n429'
  else
    [ -n "$hdr" ] && printf 'RateLimit-Remaining: 90\r\n' >"$hdr"
    printf '{"ok":true}\n200'
  fi
}
OUT=$(_gl GET "/retried")
eq "429 with Retry-After: body from the retry"        '{"ok":true}' "$OUT"
eq "429 with Retry-After: slept exactly that, not a fixed backoff" "4" "$(cat "$SLEEPLOG")"
eq "429 with Retry-After: exactly two curl calls"     "2" "$(wc -c <"$CALLS" | tr -d ' ')"
rm -f "$CALLS"
unset -f curl

# Exhausting the attempt budget ON a 429 must FAIL. `rc` holds the last curl
# exit, which a 429 leaves at 0 (the request reached the server and got an
# answer), so the fallthrough used to `return 0` with nothing on stdout --
# which every caller reads as a successful empty response. Getting there needs
# a retryable transport blip in the middle, otherwise rc is still nonzero.
_rl_clear
CALLS="$(mktemp)"; : >"$CALLS"
curl() {
  printf 'x' >>"$CALLS"
  local n; n=$(wc -c <"$CALLS" | tr -d ' ')
  [ "$n" -eq 2 ] && return 28
  printf '\n429'
}
no "429 then a transport blip then 429: fails rather than rc0 with an empty body" \
  _gl GET "/mixed"
eq "...having spent the whole attempt budget" "3" "$(wc -c <"$CALLS" | tr -d ' ')"
rm -f "$CALLS"
unset -f curl

# Moving off `curl -sf` moved the body extraction off `$( )`, which stripped
# every trailing newline, onto `${out%$'\n'*}`, which strips only the one that
# `-w '\n%{http_code}'` added. A body that itself ends in a newline would then
# come back with one MORE line than curl sent -- a byte-stream divergence from
# the `_fj` contract this wrapper claims to share.
_rl_clear
curl() {
  local hdr; hdr=$(_curl_header_arg "$@")
  [ -n "$hdr" ] && printf 'RateLimit-Remaining: 90\r\n' >"$hdr"
  printf '{"ok":true}\n\n200'
}
eq "a body ending in a newline is handed back newline-TERMINATED, not doubled" \
  "1" "$(_gl GET "/trailing" | wc -l | tr -d ' ')"
eq "and its content survives intact" '{"ok":true}' "$(_gl GET "/trailing")"
unset -f curl

# A non-numeric status (curl answering something unexpected) must fail closed.
# `[ "$http_code" -ge 400 ]` alone exits 2 on garbage, which reads as "not an
# error" and falls through to printing the body with rc 0.
_rl_clear
curl() { printf '{"ok":true}\nnotastatus'; }
no "a non-numeric http_code fails closed" _gl GET "/garbage"
unset -f curl

rm -f "$SLEEPLOG"
rm -rf "$RLSTATE"
unset AGENT_STATE_DIR
unset -f _curl_header_arg _rl_clear sleep

if [ "$FAIL" -eq 0 ]; then echo "test-gitlab: all checks passed"; exit 0
else echo "test-gitlab: $FAIL check(s) failed"; exit 1; fi
