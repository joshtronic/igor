#!/usr/bin/env bash
# Forgejo API helpers. Sourced by bin/tick.sh and bin/agent-*.sh.
#
# Requires in environment:
#   FORGEJO_URL    -- e.g., https://git.sherver.org
#   FORGEJO_TOKEN  -- bot's API token (loaded from $AGENT_HOME/.env)
#
# Requires on PATH: curl, jq.

: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"

# Fail-fast timeouts so a brief git.sherver.org blip can't wedge a tick.
# --connect-timeout bounds the connect phase: a few-second server hiccup
# either rides through or fails fast, instead of stalling. --max-time bounds
# a connected-but-unresponsive server. Tightened from a bare --max-time 30
# after a ~few-second blip hung a tick ~30s (curl exit 28), aborting it under
# errexit and tripping the task-fail healthcheck (igor#395). An untimed curl
# once sat ~2.5 min mid-validation before failing; these are the fail-fast
# successors. Hardcoded -- one operator, bake the value in.
FORGEJO_CONNECT_TIMEOUT=5
FORGEJO_MAX_TIME=15
_fj() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sf --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time "$FORGEJO_MAX_TIME" -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$FORGEJO_URL/api/v1${path}"
  else
    curl -sf --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time "$FORGEJO_MAX_TIME" -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      "$FORGEJO_URL/api/v1${path}"
  fi
}

# All open issues with label:Agent, no Status/Blocked, and no
# blocking assignee, sorted oldest-first. Caller iterates and applies
# additional filtering (in-flight PR check, rejected-PR strike count)
# to pick the first issue that's actually workable.
#
# $1  repo         -- <owner>/<name>
# $2  reviewer     -- optional FORGEJO_REVIEWER login. When set, an
#                     issue assigned solely to the reviewer is still
#                     claimable (it means the bot blocked it and the
#                     reviewer was notified, but the issue is the
#                     bot's to claim once Status/Blocked is removed).
#                     When empty, falls back to zero-assignees only.
#
# An issue is NOT claimable if it is assigned to the bot (in flight)
# or to any user other than the reviewer.
#
# Returns a JSON array. Empty array if no candidates.
forgejo_find_claimable() {
  local repo="$1" reviewer="${2:-}"
  # The API `labels=Agent` filter is an OPTIMIZATION, not the gate: Forgejo
  # IGNORES a label filter that names a label the repo doesn't have -- it
  # returns ALL open issues instead of none. A repo missing the `Agent` label
  # (e.g. a freshly-onboarded one) would otherwise make the greenlight gate
  # fail OPEN and the grind would claim every unlabeled ticket. Re-verify the
  # `Agent` label client-side so the gate fails CLOSED regardless of the repo's
  # label set.
  _fj GET "/repos/${repo}/issues?state=open&labels=Agent&type=issues&sort=oldest&limit=50" \
    | jq -c --arg reviewer "$reviewer" '
        [.[] | select(
          (
            ((.assignees // []) | length) == 0
            or (
              $reviewer != ""
              and ((.assignees // []) | length) == 1
              and (.assignees[0].login == $reviewer)
            )
          )
          and (([.labels[].name] | index("Agent")) != null)
          and (([.labels[].name] | index("Status/Blocked")) == null)
        )] | sort_by(.created_at)
      '
}

forgejo_get_issue() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/issues/${number}"
}

# All non-bot reviews on a PR, sorted oldest-to-newest. Used to
# detect "request changes" pickup signal -- if the latest non-bot
# review on the CURRENT head is REQUEST_CHANGES, the reviewer has
# rejected the current state and the agent should reopen the PR for
# revision.
#
# Returns a JSON array of review objects (state, commit_id,
# submitted_at, user, etc.). Filters out the bot's own reviews so
# they don't drown out real reviewer signal.
forgejo_pr_non_bot_reviews() {
  local repo="$1" number="$2" bot="$3"
  _fj GET "/repos/${repo}/pulls/${number}/reviews" \
    | jq -c --arg b "$bot" '
        [.[] | select(.user.login != $b)]
        | sort_by(.submitted_at)
      '
}

forgejo_assign() {
  local repo="$1" number="$2" user="$3"
  _fj PATCH "/repos/${repo}/issues/${number}" \
    "$(jq -n --arg u "$user" '{assignees: [$u]}')" >/dev/null
}

forgejo_unassign_all() {
  local repo="$1" number="$2"
  _fj PATCH "/repos/${repo}/issues/${number}" '{"assignees": []}' >/dev/null
}

# The HTTP POST behind forgejo_request_review, split out as a seam tests can
# stub. Echoes "<body>\n<http_code>" (curl -w appends the code last) and never
# uses -f, so a non-2xx body survives for the caller to classify.
_forgejo_post_reviewers() {
  local url="$1" payload="$2"
  curl -s -w $'\n%{http_code}' --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time "$FORGEJO_MAX_TIME" -X POST \
    -H "Authorization: token $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" "$url"
}

# Request review from a user on a PR. A separate endpoint from PR-create,
# which can't set reviewers. PRs ONLY (issues have no reviewers). Note: Forgejo
# rejects requesting review from a PR's own author -- that's why the bot can't
# review its own PRs and the human->bot re-engagement stays assignment-based
# (forgejo_my_assigned_prs).
#
# Idempotent + fault-tolerant (#377): re-requesting an already-requested
# reviewer is a harmless no-op (verified: HTTP 201, empty body), so the only
# real failures are transient (5xx / timeout, curl code 000) or a genuine
# client error. Retry ONCE on a transient code, then on persistent failure
# emit the HTTP status + body on stderr and return non-zero -- so the caller
# logs WHY it failed instead of the old bare, ambiguous warning. rc 0 iff the
# request actually landed (2xx).
forgejo_request_review() {
  local repo="$1" number="$2" reviewer="$3"
  local url="$FORGEJO_URL/api/v1/repos/${repo}/pulls/${number}/requested_reviewers"
  local payload resp code body attempt
  payload=$(jq -n --arg r "$reviewer" '{reviewers: [$r]}')
  for attempt in 1 2; do
    resp=$(_forgejo_post_reviewers "$url" "$payload")
    code="${resp##*$'\n'}"   # last line: the http_code
    body="${resp%$'\n'*}"    # everything before it: the response body
    case "$code" in
      2*) return 0 ;;
      5*|000) [ "$attempt" -eq 1 ] && { sleep 1; continue; } ;;
    esac
    break
  done
  printf 'HTTP %s: %s' "${code:-000}" "$(printf '%s' "$body" | tr '\n' ' ' | head -c 200)" >&2
  return 1
}

forgejo_comment() {
  local repo="$1" number="$2" body="$3"
  _fj POST "/repos/${repo}/issues/${number}/comments" \
    "$(jq -n --arg b "$body" '{body: $b}')" >/dev/null
}

# Log time spent on an issue/PR (Forgejo's built-in time tracking).
# Number works for both issues and PRs -- they share the number space.
# Best-effort: warns and returns non-zero if the repo has time tracking
# disabled or the API rejects, but never aborts the caller. Skips
# entirely if seconds <= 0.
forgejo_log_time() {
  local repo="$1" number="$2" seconds="$3"
  [ -z "$seconds" ] || [ "$seconds" -le 0 ] 2>/dev/null && return 0
  _fj POST "/repos/${repo}/issues/${number}/times" \
    "$(jq -n --argjson s "$seconds" '{time: $s}')" >/dev/null 2>&1 \
    || return 1
}

# Open a PR and hand it to the human as a REVIEW request, not an assignment.
# An open bot PR is left UNASSIGNED on purpose: on a PR, unassigned means
# "the human's to review", assigned-to-the-bot means "the bot's to act on"
# (that's the forgejo_my_assigned_prs re-engagement signal). The 6th arg is
# the reviewer; review-request is a second call (PR-create can't set it) and
# is best-effort -- the PR is already open if it fails. Prints the new PR's
# number on stdout (empty on create failure) so callers can capture it.
forgejo_open_pr() {
  local repo="$1" head="$2" base="$3" title="$4" body="$5" reviewer="${6:-}"
  local payload number
  payload=$(jq -n \
    --arg t "$title" --arg b "$body" \
    --arg h "$head"  --arg ba "$base" \
    '{title: $t, body: $b, head: $h, base: $ba}')
  number=$(_fj POST "/repos/${repo}/pulls" "$payload" | jq -r '.number // empty')
  [ -z "$number" ] && return 1
  if [ -n "$reviewer" ]; then
    forgejo_request_review "$repo" "$number" "$reviewer" 2>/dev/null \
      || printf 'forgejo_open_pr: review request for %s on %s#%s failed (PR is open)\n' \
           "$reviewer" "$repo" "$number" >&2
  fi
  printf '%s\n' "$number"
}

# Upload one image as an attachment on an issue/PR; echo its public URL (empty
# on failure). The Forgejo assets endpoint is multipart, so it can't ride _fj
# (JSON-only). Size-guarded: the reverse proxy caps the request body, so an
# oversized capture would 413 -- skip it (warn to stderr) rather than fail. The
# agent is told to keep screenshots small; this is the backstop.
FORGEJO_ATTACH_MAX_BYTES="${FORGEJO_ATTACH_MAX_BYTES:-900000}"
forgejo_attach_image() {
  local repo="$1" number="$2" file="$3" size
  local name="${4:-$(basename "$file")}"
  [ -f "$file" ] || { printf 'forgejo_attach_image: no such file: %s\n' "$file" >&2; return 1; }
  size=$(wc -c < "$file")
  if [ "$size" -gt "$FORGEJO_ATTACH_MAX_BYTES" ]; then
    printf 'forgejo_attach_image: skip %s (%s bytes > %s cap)\n' "$name" "$size" "$FORGEJO_ATTACH_MAX_BYTES" >&2
    return 1
  fi
  curl -sf --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time 60 -X POST \
    -H "Authorization: token $FORGEJO_TOKEN" \
    -F "attachment=@${file};filename=${name}" \
    "$FORGEJO_URL/api/v1/repos/${repo}/issues/${number}/assets?name=${name}" \
    | jq -r '.browser_download_url // empty'
}

# Attach every image in <dir> to a PR and append an embedded "## Screenshots"
# section to its body (once -- guarded by an HTML-comment marker). Echoes the
# count attached. No-op (echo 0) if the dir is absent/empty. Lets a UI-work PR
# carry the visual proof the agent captured, instead of just referencing it in
# text. $1 repo  $2 PR number  $3 dir
forgejo_attach_pr_screenshots() {
  local repo="$1" number="$2" dir="$3" md="" url f count=0
  [ -d "$dir" ] || { echo 0; return 0; }
  for f in "$dir"/*.png "$dir"/*.PNG "$dir"/*.jpg "$dir"/*.jpeg; do
    [ -f "$f" ] || continue
    url=$(forgejo_attach_image "$repo" "$number" "$f") || continue
    [ -n "$url" ] || continue
    md+="![$(basename "$f")](${url})"$'\n\n'
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { echo 0; return 0; }
  local body newbody
  body=$(_fj GET "/repos/${repo}/issues/${number}" | jq -r '.body // ""')
  case "$body" in *"<!-- screenshots -->"*) echo "$count"; return 0 ;; esac
  newbody="${body}"$'\n\n<!-- screenshots -->\n## Screenshots\n\n'"${md}"
  _fj PATCH "/repos/${repo}/issues/${number}" "$(jq -n --arg b "$newbody" '{body: $b}')" >/dev/null
  echo "$count"
}

# All open PRs assigned to the authenticated bot user across every accessible
# repo. The human->bot re-engagement signal: the human assigns a PR back to
# the bot, next tick finds it here and reopens the work. (Outbound, the bot
# hands PRs back via review-request + unassigned, never by assigning the
# human -- see forgejo_open_pr / forgejo_request_review.)
forgejo_my_assigned_prs() {
  _fj GET "/repos/issues/search?type=pulls&state=open&assigned=true&limit=50"
}

# Full PR object including head/base branch info. The search endpoint
# returns issue-shaped records that don't include branch refs; this
# fetch fills in what we need to check out the PR's branch.
forgejo_get_pr() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/pulls/${number}"
}

# Issue-level comments on a PR (the "Conversation" tab). Distinct from
# inline review comments tied to a specific file/line.
forgejo_pr_comments() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/issues/${number}/comments"
}

# Inline review comments (tied to a file path and line).
#
# Forgejo's inline review comments live UNDER each review, not at a
# top-level pull endpoint. We have to iterate every review on the PR
# and aggregate their .comments[] arrays. The reviews list endpoint
# returns embedded .comments per review object on most recent Forgejo
# versions; older versions require a separate fetch per review id.
# We try the embedded path first and fall back to per-review fetches
# if it's empty but reviews exist.
#
# Returns a flat JSON array of inline comment objects (each with
# path, original_line, body, user, created_at, etc.).
forgejo_pr_review_comments() {
  local repo="$1" number="$2"
  local reviews
  reviews=$(_fj GET "/repos/${repo}/pulls/${number}/reviews" 2>/dev/null || echo '[]')

  # Path 1: comments embedded in each review object
  local embedded
  embedded=$(jq -c '[.[] | (.comments // [])[]]' <<<"$reviews" 2>/dev/null || echo '[]')
  if [ "$(jq 'length' <<<"$embedded" 2>/dev/null || echo 0)" -gt 0 ]; then
    printf '%s' "$embedded"
    return
  fi

  # Path 2: fetch each review's comments individually
  local all='[]'
  while read -r rid; do
    [ -z "$rid" ] && continue
    local rc
    rc=$(_fj GET "/repos/${repo}/pulls/${number}/reviews/${rid}/comments" 2>/dev/null || echo '[]')
    all=$(jq -c --argjson c "$rc" '. + $c' <<<"$all" 2>/dev/null || echo "$all")
  done < <(jq -r '.[].id' <<<"$reviews" 2>/dev/null)
  printf '%s' "$all"
}

# Open PRs authored by the given user on this repo, as JSON
# array of {number, title, head}. Used to brief Claude on
# what's in flight so he doesn't duplicate work.
forgejo_list_open_bot_prs() {
  local repo="$1" user="$2"
  _fj GET "/repos/${repo}/pulls?state=open&limit=50" \
    | jq --arg u "$user" \
        '[.[] | select(.user.login == $u)
          | {number, title, head: .head.ref}]'
}

# Files changed in a PR with status (added/modified/removed/renamed).
# Returns JSON array of {filename, status}. Used by the post cooldown
# to detect in-flight post PRs before they merge to master.
forgejo_pr_files() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/pulls/${number}/files"
}

# Raw unified diff for a PR, as text/plain (NOT JSON -- the caller
# feeds it straight to a model). Forgejo serves it off the `.diff`
# suffix under the same pulls path. Big diffs are the caller's problem
# to cap (the shadow reviewer head -c's it); a wedged fetch fails fast
# via _fj's --max-time like every other call.
forgejo_pr_diff() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/pulls/${number}.diff"
}

# Combined CI status for a commit sha: one of success|pending|failure|
# error, or empty when the repo reports no statuses for the sha (no CI
# wired, or checks haven't started). Mirrors what branch protection's
# "required status checks" gate reads -- so a shadow verdict can record
# the same CI signal the eventual auto-merge gate will key on. Empty/
# unknown on API failure (NON-fatal: the caller treats it as "unknown").
forgejo_commit_status() {
  local repo="$1" sha="$2" resp
  resp=$(_fj GET "/repos/${repo}/commits/${sha}/status" 2>/dev/null) || { printf ''; return; }
  jq -r '.state // ""' <<<"$resp" 2>/dev/null || printf ''
}

# Number on the open PR with the given head branch, or empty if none.
# Used to make PR-open idempotent across harness crashes: if a previous
# tick pushed but died before opening, we find the orphan branch already
# has no PR -- but if it does have one (e.g. re-running by hand) we
# don't duplicate.
forgejo_find_pr_by_head() {
  local repo="$1" head="$2"
  _fj GET "/repos/${repo}/pulls?state=open&limit=50" \
    | jq -r --arg h "$head" 'map(select(.head.ref == $h)) | first | .number // empty'
}

# Count of comments on this issue authored by the given user whose body
# starts with the given prefix. Used by the noop-loop guard: a prior
# "no work produced" comment from the bot means we've already retried.
forgejo_count_bot_comments_matching() {
  local repo="$1" number="$2" user="$3" prefix="$4"
  _fj GET "/repos/${repo}/issues/${number}/comments" \
    | jq --arg u "$user" --arg p "$prefix" \
        '[.[] | select(.user.login == $u and (.body | startswith($p)))] | length'
}

# Count of comments by the given user whose body CONTAINS the substring
# (vs startswith above). The shadow reviewer's dedup net: its per-sha
# marker rides at the END of the comment, so startswith can't find it.
# Crash-safety belt -- the primary dedup is the local .review state sha;
# this catches the rare crash between posting the comment and recording
# the state.
forgejo_pr_has_comment_containing() {
  local repo="$1" number="$2" user="$3" needle="$4"
  _fj GET "/repos/${repo}/issues/${number}/comments" \
    | jq --arg u "$user" --arg n "$needle" \
        '[.[] | select(.user.login == $u and (.body | contains($n)))] | length'
}

# Add a label by name. Forgejo's API takes label IDs, so this resolves
# name -> id with a single API call.
forgejo_add_label() {
  local repo="$1" number="$2" name="$3"
  local id
  id=$(_fj GET "/repos/${repo}/labels" \
       | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' \
       | head -1)
  [ -n "$id" ] || { echo "label not found: $name" >&2; return 1; }
  _fj POST "/repos/${repo}/issues/${number}/labels" \
    "$(jq -n --argjson id "$id" '{labels: [$id]}')" >/dev/null
}

# forgejo_remove_label <repo> <number> <name> -- mirror of forgejo_add_label:
# resolve the label name -> id, then DELETE it off the issue. rc=1 if the label
# name does not resolve in the repo (caller decides whether that's fatal).
forgejo_remove_label() {
  local repo="$1" number="$2" name="$3"
  local id
  id=$(_fj GET "/repos/${repo}/labels" \
       | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' \
       | head -1)
  [ -n "$id" ] || { echo "label not found: $name" >&2; return 1; }
  _fj DELETE "/repos/${repo}/issues/${number}/labels/${id}" >/dev/null
}

# forgejo_repo_has_label <repo> <name> -- does the repo DEFINE a label of this
# name? (Repo-level metadata, not on any issue.) The greenlight gate matches
# issues by the `Agent` label, but Forgejo can only match a label the repo
# actually defines -- so onboarding wants to confirm it exists. Distinct exit
# codes so a caller can tell "absent" from "couldn't check":
#   0 -- present
#   1 -- absent (the labels list was read and holds no such name)
#   2 -- indeterminate (the API read itself failed: network/token)
forgejo_repo_has_label() {
  local repo="$1" name="$2" labels
  labels=$(_fj GET "/repos/${repo}/labels") || return 2
  jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$labels" >/dev/null 2>&1
}

# Bot-authored PRs on this repo that reference this issue via
# "Closes #N" (case-insensitive). Each entry: {number, state,
# merged}. Empty array if none.
#
# Used by discovery to gate claimable issues:
#   - any OPEN, non-WIP entry -> issue is in flight, skip
#   - an OPEN, WIP entry (turn-cap checkpoint draft) -> RESUME, don't skip
#     (the title carries checkpoint.sh's CHECKPOINT_WIP_PREFIX)
#   - 2+ state="closed", merged=false  -> 2 rejected attempts,
#     block with Status/Blocked instead of re-trying
# The `title` is returned so callers can tell a WIP checkpoint from a real PR.
forgejo_bot_prs_for_issue() {
  local repo="$1" issue_num="$2" user="$3"
  _fj GET "/repos/${repo}/pulls?state=all&limit=100" \
    | jq -c --arg u "$user" --arg n "$issue_num" '
        [.[]
         | select(.user.login == $u)
         | select(.body != null and (.body | test("(?i)closes\\s+#" + $n + "\\b")))
         | {number, state, title: (.title // ""), merged: (.merged // false)}]'
}

# forgejo_edit_pr <repo> <number> [--title T] [--body B] -- patch a PR's title
# and/or body. A PR IS an issue in Forgejo, so the issues PATCH endpoint edits
# both. Used by the checkpoint flow to bump the counter in a draft's body and to
# drop the WIP prefix from its title on finalize. No-op payload if no flags given.
forgejo_edit_pr() {
  local repo="$1" number="$2"; shift 2
  local payload='{}'
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) payload=$(jq --arg v "$2" '.title = $v' <<<"$payload"); shift 2 ;;
      --body)  payload=$(jq --arg v "$2" '.body = $v'  <<<"$payload"); shift 2 ;;
      *) shift ;;
    esac
  done
  _fj PATCH "/repos/${repo}/issues/${number}" "$payload" >/dev/null
}

# Returns the authenticated user's login (the bot's username). Empty
# on failure.
forgejo_whoami() {
  _fj GET "/user" | jq -r '.login // empty'
}

# Resolve the bot's login, retrying a transient /api/v1/user failure with
# backoff (igor#383). Bot-identity resolution gates the ENTIRE tick, so a
# one-off API hiccup must not hard-abort the unit: a few quick retries ride
# through the common momentary blip. Only a PERSISTENT failure (retries
# exhausted -- a sustained outage or a revoked token) returns empty, which the
# caller escalates to a visible exit. Echoes the login on success, empty on
# persistent failure; returns 0 iff resolved. The assignment stays guarded
# because forgejo_whoami's curl|jq pipeline can surface curl's raw exit code
# under pipefail (igor#346). Kept out of forgejo_whoami itself so the fast-fail
# diagnostic callers (doctor.sh, validate.sh) don't inherit the backoff.
forgejo_resolve_bot_user() {
  local attempt bot=""
  for attempt in 1 2 3; do
    bot=$(forgejo_whoami) || bot=""
    [ -n "$bot" ] && { printf '%s\n' "$bot"; return 0; }
    if [ "$attempt" -lt 3 ]; then sleep "$attempt"; fi
  done
  return 1
}

# Lists every repo the bot has push access to. Returns a JSON array of
# {full_name, default_branch}. Paginated (50/page).
forgejo_list_bot_repos() {
  local page=1 batch count all='[]'
  while batch=$(_fj GET "/user/repos?limit=50&page=${page}"); do
    count=$(jq 'length' <<<"$batch")
    [ "$count" -eq 0 ] && break
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s 'add')
    [ "$count" -lt 50 ] && break
    page=$((page + 1))
  done
  jq '[.[] | select(.permissions.push == true)
        | {full_name, default_branch}]' <<<"$all"
}

# All open issues currently assigned to the authenticated user across
# every accessible repo. Returns a JSON array. Used by the recovery
# sweep -- one call replaces N per-repo calls.
forgejo_my_assigned() {
  _fj GET "/repos/issues/search?state=open&type=issues&assigned=true&limit=50"
}

# Returns 0 if the repo exists and the bot can access it, 1 otherwise.
# Used by the bootstrap step to verify WEBSITE_REPO (when set) is
# accessible before the website-side ticks try to clone it.
forgejo_repo_exists() {
  _fj GET "/repos/$1" >/dev/null 2>&1
}

# -- File reads (no clone) --------------------------------------
#
# Read a repo's files/dirs over the API without cloning it (used for the
# per-repo agent.json config and logwatch's systemd/ discovery). All take
# <repo> = "<owner>/<name>".

# Prints raw file contents on stdout (base64-decoded). NON-ZERO when
# the API call fails (incl. 404) -- callers gate on the file existing
# first, so a failure here means the read itself broke, not the file
# is absent.
forgejo_repo_get_file() {
  local repo="$1" path="$2"
  local resp
  resp=$(_fj GET "/repos/${repo}/contents/${path}" 2>/dev/null) || return 1
  jq -r '.content // empty' <<<"$resp" | base64 -d 2>/dev/null || true
}

# Names of the entries in a repo directory, one per line. Non-zero
# when the API call fails OR the directory doesn't exist -- callers
# (logwatch service discovery) treat both as "nothing to list".
forgejo_repo_list_dir() {
  local repo="$1" dir="$2" resp
  resp=$(_fj GET "/repos/${repo}/contents/${dir}" 2>/dev/null) || return 1
  jq -r '.[]?.name // empty' <<<"$resp" 2>/dev/null
}

# Subjects (first lines) of the N most recent commits on the default
# branch, one per line. Best-effort: empty on API failure -- this is
# a dedup signal, not a gate.
forgejo_recent_commit_subjects() {
  local repo="$1" n="${2:-20}" resp
  resp=$(_fj GET "/repos/${repo}/commits?limit=${n}&stat=false&verification=false&files=false" 2>/dev/null) || return 0
  jq -r '.[]? | .commit.message // empty | split("\n")[0]' <<<"$resp" 2>/dev/null || true
}

# Returns 0 if the given dir in the repo contains at least one file
# matching the given regex. Useful for "does .forgejo/workflows have a
# .yml file?" without enumerating each candidate path.
forgejo_repo_dir_has_match() {
  local repo="$1" dir="$2" name_re="$3"
  local contents
  contents=$(_fj GET "/repos/${repo}/contents/${dir}" 2>/dev/null) || return 1
  jq -e --arg re "$name_re" 'any(.[]; .name | test($re))' <<<"$contents" >/dev/null 2>&1
}

# -- Issue lifecycle (open / reopen) ----------------------------

# Open a new issue. Prints the new issue number to stdout. Labels are
# applied separately via forgejo_add_label so missing labels degrade
# gracefully instead of failing the whole call.
# All open issue titles in a repo (issues only, not PRs), one per
# line. Used by the logwatch pass as a dedup signal -- the reviewer
# is told not to refile anything already covered by an open ticket.
forgejo_list_open_issue_titles() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" \
    | jq -r '.[].title'
}

forgejo_open_issue() {
  local repo="$1" title="$2" body="$3"
  _fj POST "/repos/${repo}/issues" \
    "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}')" \
    | jq -r '.number'
}

forgejo_reopen_issue() {
  local repo="$1" number="$2"
  _fj PATCH "/repos/${repo}/issues/${number}" \
    '{"state": "open"}' >/dev/null
}

# Find the most recent bot-authored issue in this repo whose body
# contains the given HTML-comment marker. Returns the issue JSON
# (open or closed) or empty if none found. Used to dedupe auto-filed
# onboarding tickets across ticks.
forgejo_find_marked_issue() {
  local repo="$1" bot="$2" marker="$3"
  local issues
  # Separate the _fj call so a curl timeout (exit 28) or other API
  # failure returns exit 1 here rather than propagating the raw curl
  # exit code through pipefail to the caller.
  issues=$(_fj GET "/repos/${repo}/issues?state=all&type=issues&limit=50" 2>/dev/null) || return 1
  jq -c --arg b "$bot" --arg m "$marker" '
      [.[] | select(.user.login == $b and ((.body // "") | contains($m)))]
      | sort_by(.created_at) | reverse | first // empty
    ' <<<"$issues"
}
