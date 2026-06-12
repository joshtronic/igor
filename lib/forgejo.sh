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

# --max-time: a wedged Forgejo must fail fast, not stall the tick --
# an untimed curl once sat ~2.5 minutes mid-validation before failing.
# 30s is generous for small JSON calls on the same network.
_fj() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sf --max-time 30 -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$FORGEJO_URL/api/v1${path}"
  else
    curl -sf --max-time 30 -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      "$FORGEJO_URL/api/v1${path}"
  fi
}

# All open issues with label:Agent, no assignee, no Status/Blocked,
# sorted oldest-first. Caller iterates and applies additional
# filtering (in-flight PR check, rejected-PR strike count) to pick
# the first issue that's actually workable.
#
# Returns a JSON array. Empty array if no candidates.
forgejo_find_claimable() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&labels=Agent&type=issues&sort=oldest&limit=50" \
    | jq -c '
        [.[] | select(
          ((.assignees // []) | length) == 0
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

# Request review from a user on a PR. A separate endpoint from PR-create,
# which can't set reviewers. Idempotent: re-requesting an already-requested
# reviewer is a harmless no-op, so it's crash-safe to call again. PRs ONLY
# (issues have no reviewers). Note: Forgejo rejects requesting review from a
# PR's own author -- that's why the bot can't review its own PRs and the
# human->bot re-engagement stays assignment-based (forgejo_my_assigned_prs).
forgejo_request_review() {
  local repo="$1" number="$2" reviewer="$3"
  _fj POST "/repos/${repo}/pulls/${number}/requested_reviewers" \
    "$(jq -n --arg r "$reviewer" '{reviewers: [$r]}')" >/dev/null
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

# All label names defined on the repo, as a JSON array of strings. One
# call answers every "does label X exist?" check the validator makes,
# instead of a GET /labels per name. Empty array on miss.
# NON-ZERO on API failure, same contract (and reason) as
# forgejo_repo_list_root above.
forgejo_list_labels() {
  local repo="$1" resp
  resp=$(_fj GET "/repos/${repo}/labels" 2>/dev/null) || return 1
  jq -c '[.[]?.name]' <<<"$resp" 2>/dev/null || printf '[]'
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

# Bot-authored PRs on this repo that reference this issue via
# "Closes #N" (case-insensitive). Each entry: {number, state,
# merged}. Empty array if none.
#
# Used by discovery to gate claimable issues:
#   - any state="open" entry  -> issue is in flight, skip
#   - 2+ state="closed", merged=false  -> 2 rejected attempts,
#     block with Status/Blocked instead of re-trying
forgejo_bot_prs_for_issue() {
  local repo="$1" issue_num="$2" user="$3"
  _fj GET "/repos/${repo}/pulls?state=all&limit=100" \
    | jq -c --arg u "$user" --arg n "$issue_num" '
        [.[]
         | select(.user.login == $u)
         | select(.body != null and (.body | test("(?i)closes\\s+#" + $n + "\\b")))
         | {number, state, merged: (.merged // false)}]'
}

# Returns the authenticated user's login (the bot's username). Empty
# on failure.
forgejo_whoami() {
  _fj GET "/user" | jq -r '.login // empty'
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
# These let onboarding validation inspect a repo without cloning it.
# All take <repo> = "<owner>/<name>".

# Lists the names of entries at the repo root (files + dirs) as a JSON
# array of strings. One call answers every root-level existence probe
# the validator makes, instead of a GET /contents/<path> per candidate
# file. Empty array for a genuinely empty repo; NON-ZERO when the API
# call itself fails -- "couldn't read the repo" must stay
# distinguishable from "the repo has no files", or one network hiccup
# fails every existence check at once (and files a bogus onboarding
# ticket; see rc_cache_init).
forgejo_repo_list_root() {
  local repo="$1" resp
  resp=$(_fj GET "/repos/${repo}/contents" 2>/dev/null) || return 1
  jq -c '[.[]?.name]' <<<"$resp" 2>/dev/null || printf '[]'
}

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
  _fj GET "/repos/${repo}/issues?state=all&type=issues&limit=50" \
    | jq -c --arg b "$bot" --arg m "$marker" '
        [.[] | select(.user.login == $b and ((.body // "") | contains($m)))]
        | sort_by(.created_at) | reverse | first // empty
      '
}
