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

_fj() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sf -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$FORGEJO_URL/api/v1${path}"
  else
    curl -sf -X "$method" \
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

forgejo_open_pr() {
  local repo="$1" head="$2" base="$3" title="$4" body="$5" assignee="${6:-}"
  local payload
  payload=$(jq -n \
    --arg t "$title" --arg b "$body" \
    --arg h "$head"  --arg ba "$base" \
    '{title: $t, body: $b, head: $h, base: $ba}')
  if [ -n "$assignee" ]; then
    payload=$(jq --arg a "$assignee" '. + {assignees: [$a]}' <<<"$payload")
  fi
  # Print the new PR's number on stdout so callers can capture it
  # (for follow-up actions like time tracking).
  _fj POST "/repos/${repo}/pulls" "$payload" | jq -r '.number // empty'
}

# All open PRs assigned to the authenticated bot user across every
# accessible repo. The assignment-dance entry point: human reassigns a
# PR back to the bot, next tick finds it here and reopens the work.
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
forgejo_list_labels() {
  local repo="$1"
  _fj GET "/repos/${repo}/labels" 2>/dev/null \
    | jq -c '[.[]?.name]' 2>/dev/null || printf '[]'
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
# file. Empty array on miss.
forgejo_repo_list_root() {
  local repo="$1"
  _fj GET "/repos/${repo}/contents" 2>/dev/null \
    | jq -c '[.[]?.name]' 2>/dev/null || printf '[]'
}

# Prints raw file contents on stdout (base64-decoded). Empty on miss.
forgejo_repo_get_file() {
  local repo="$1" path="$2"
  local resp
  resp=$(_fj GET "/repos/${repo}/contents/${path}" 2>/dev/null) || return 0
  jq -r '.content // empty' <<<"$resp" | base64 -d 2>/dev/null || true
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
