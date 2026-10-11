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

echo "== pr_files: additions/deletions are COUNTED (0 would let any MR past the risk gate) =="
_gl() { cat <<'JSON'
{"changes":[
 {"old_path":"a.sh","new_path":"a.sh","new_file":false,"deleted_file":false,"renamed_file":false,
  "diff":"--- a/a.sh\n+++ b/a.sh\n@@ -1 +1,2 @@\n-old line\n+new line\n+another\n"},
 {"old_path":"b.sh","new_path":"b.sh","new_file":true,"deleted_file":false,"renamed_file":false,
  "diff":"+++ b/b.sh\n@@ -0,0 +1 @@\n+brand new\n"}
]}
JSON
}
PF=$(forgejo_pr_files acme/x 1)
eq "two files"                   "2"        "$(jq 'length' <<<"$PF")"
eq "additions counted, +++ excluded" "2"    "$(jq -r '.[0].additions' <<<"$PF")"
eq "deletions counted, --- excluded" "1"    "$(jq -r '.[0].deletions' <<<"$PF")"
eq "new_file -> added"           "added"    "$(jq -r '.[1].status' <<<"$PF")"
eq "otherwise -> modified"       "modified" "$(jq -r '.[0].status' <<<"$PF")"
has "pr_diff reassembles a git header" "$(forgejo_pr_diff acme/x 1)" "diff --git a/a.sh b/a.sh"
unset -f _gl
# A payload that isn't a changes object must be "unknown" (nonzero, no output),
# never an empty-but-successful list the gate would read as "small".
_gl() { printf '{"message":"403 Forbidden"}'; }
no "pr_files: non-changes payload is nonzero" forgejo_pr_files acme/x 1
eq "pr_files: and emits nothing" "" "$(forgejo_pr_files acme/x 1 2>/dev/null)"
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
    "GET /projects/"*"/labels"*"page=1"*) printf '[{"id":12,"name":"Kind/Bug"},{"id":34,"name":"Priority/High"},{"id":56,"name":"Other"}]' ;;
    "GET /projects/"*"/labels"*) printf '[]' ;;
    "POST /projects/"*"/issues") printf '%s' "$3" >"$POSTED"; printf '{"iid":9,"description":"","author":{"username":"igorbot"},"labels":[]}' ;;
  esac
}
_GL_UID_CACHE=()
forgejo_open_issue_assigned acme/x "t" "b" someone '[12,34]' >/dev/null
eq "label ids resolved to a name list" "Kind/Bug,Priority/High" "$(jq -r .labels "$POSTED")"
forgejo_open_issue_assigned acme/x "t" "b" someone '[]' >/dev/null
eq "empty id list omits labels entirely" "false" "$(jq 'has("labels")' "$POSTED")"
forgejo_open_issue_assigned acme/x "t" "b" someone '[999]' >/dev/null 2>/dev/null
eq "an unknown id is dropped, issue still opens" "false" "$(jq 'has("labels")' "$POSTED")"
has "an unresolved id leaves a log line" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone '[999]' 2>&1 >/dev/null)" "unresolved ids dropped"
# A caller still on the pre-cutover comma-separated-NAMES contract gets an
# unlabelled issue -- which must not be silent.
has "a non-array label argument is called out" \
  "$(forgejo_open_issue_assigned acme/x "t" "b" someone 'Kind/Bug' 2>&1 >/dev/null)" "wants a JSON array of label ids"
eq "and that issue opens unlabelled, not with junk labels" "false" "$(jq 'has("labels")' "$POSTED")"
rm -f "$POSTED"; unset -f _gl
# `unset -f _gl` removes the function outright -- bash does not stack definitions
# -- so re-source to put the real _gl back for the blocks below.
. "$HERE/../lib/gitlab.sh" 2>/dev/null

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

if [ "$FAIL" -eq 0 ]; then echo "test-gitlab: all checks passed"; exit 0
else echo "test-gitlab: $FAIL check(s) failed"; exit 1; fi
