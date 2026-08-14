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

# bin/tick.sh defines log() before sourcing this; bin/agent-*.sh and the unit
# tests may not. Same fallback shape as lib/http-reap.sh.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

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
# Bounded retry, GET/HEAD only, TRANSPORT failures only (igor#425). A read is
# safe to repeat, so a transient stall (curl exit 28, timeout) costs one retry
# instead of the whole tick -- previously an unguarded caller's
# `x=$(_fj GET ... | jq ...)` propagated curl's raw exit code fatally under
# `set -e -o pipefail` (the PR-review pickup loop's Signal 1 scan hit this
# live). POST/PATCH/DELETE are NEVER retried here: they can land server-side
# and still time out client-side, and a naive retry would double-post/
# double-act (see forgejo_comment, forgejo_assign, forgejo_request_review's
# own separate transient-retry). Hardcoded -- one operator, bake it in.
#
# The worst case this buys is 3 x FORGEJO_MAX_TIME + 2 x FORGEJO_RETRY_DELAY
# ~= 47s for a single read, and the PR-review scan does a read per PR per
# repo -- so a genuinely unreachable git.sherver.org makes a tick slow.
# Accepted rather than capped by a global deadline: it costs 3x only when the
# instance is down, in which case the tick has no work it can do anyway, and
# the price of the alternative is paid on the healthy path. Ticks are
# idempotent and systemd will not start one while the last is still running,
# so a slow tick delays the next beat instead of piling up. The two knobs that
# actually bound this are already conservative: 15s max-time (chosen in
# igor#395 to be fail-fast) and a retry budget of 2.
FORGEJO_RETRY_COUNT=2
FORGEJO_RETRY_DELAY=1
# curl exit codes worth a second look: connect failed, timed out, SSL connect
# error, empty reply, recv failure. Deliberately NOT 22 -- with `-sf` curl
# exits 22 for every HTTP >= 400, which is an ANSWER, not a hiccup: the
# Actions-API 404 is the normal response on Forgejo v15, a 403 is a
# rate-limiter that wants backing off rather than two more requests, a 401 is
# a bad token. Retrying those triples the request count and the worst-case
# wall clock (15s -> 47s per call) for a result that won't change -- turning a
# fast guarded miss on an unhealthy instance into a slow one, which is the
# failure mode this whole change exists to avoid.
FORGEJO_RETRY_CURL_CODES='7 28 35 52 56'
_fj() {
  local method="$1" path="$2" body="${3:-}"
  local attempts=1
  case "$method" in
    GET|HEAD) attempts=$((FORGEJO_RETRY_COUNT + 1)) ;;
  esac
  local -a extra=()
  if [ -n "$body" ]; then
    extra=(-H "Content-Type: application/json" -d "$body")
  fi
  # The response is buffered rather than streamed: an attempt that may be
  # retried can't emit a partial body first. `$( )` strips the trailing
  # newline, so it is re-emitted here to hand back curl's byte stream
  # unchanged -- a command-substituting caller couldn't tell either way, but
  # one that PIPES `_fj` into `read` can: at EOF with no delimiter `read`
  # returns nonzero and drops the final (often only) line. An empty body stays
  # empty so a 204 doesn't grow a phantom line.
  local attempt out rc=0
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if out=$(curl -sf --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time "$FORGEJO_MAX_TIME" -X "$method" \
        -H "Authorization: token $FORGEJO_TOKEN" \
        "${extra[@]+"${extra[@]}"}" \
        "$FORGEJO_URL/api/v1${path}"); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    else
      rc=$?
    fi
    [[ " $FORGEJO_RETRY_CURL_CODES " == *" $rc "* ]] || return "$rc"
    [ "$attempt" -lt "$attempts" ] && sleep "$FORGEJO_RETRY_DELAY"
  done
  # Every attempt burned on a retryable transport failure. Say so -- igor#424
  # was filed because a tick died `status=28` with no error line, no trace and
  # nothing to distinguish a network blip from a harness bug. Only this
  # exhausted-transport case logs: an HTTP status returned above is an ANSWER
  # (a 404 for an absent agent.json is the COMMON path) and would be pure
  # noise. To stderr, not stdout, so it can't contaminate the caller's
  # command substitution on a path where the caller may `|| true` and use the
  # captured value anyway.
  log "forgejo: ${method} ${path} failed after ${attempts} attempt(s) (curl exit ${rc})" >&2
  return "$rc"
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

# forgejo_append_issue_body <repo> <number> <heading> <text> -- appends
# <text> under a "## <heading>" section at the end of the issue's current
# body and PATCHes it back. Used by agent-block.sh (igor#434): the
# issue-work prompt (bin/tick.sh) feeds ONLY the issue body to the next
# tick's Claude invocation -- comments are never read -- so a block reason
# posted solely as a comment can never reach a re-queued run. Appending it
# to the body is what makes "remove Status/Blocked to re-queue" actually
# work. Best-effort: a fetch/PATCH failure returns 1 without touching
# anything, so the caller can still fall back to commenting alone.
#
# The fetch is validated in two steps, deliberately, because the naive
# `current=$(forgejo_get_issue ... | jq -r '.body // empty') || return 1` is
# wrong in both halves and its failure mode is DESTRUCTIVE -- it PATCHes the
# block note in as the entire issue description, erasing the very text this
# helper exists to preserve:
#   1. A pipeline's status is jq's, not the fetch's, unless the CALLER has
#      `pipefail` set -- and `jq -r '.body // empty'` on empty stdin exits 0.
#      So the fetch is captured on its own line; no shell option of the
#      caller's can change what that guard sees.
#   2. Exit status alone isn't enough anyway. `_fj`'s `curl -sf` covers the
#      HTTP >= 400 case today, but any 2xx payload that isn't an issue (an
#      error object, a proxy's interstitial) is still well-formed JSON whose
#      `.body // empty` is "" with exit 0. So require the payload to look like
#      an issue -- `has("number")` and `has("body")` -- before writing.
# Growth is accepted: each block appends another section rather than replacing
# the last, because the history of what was tried and rejected is context a
# re-queued run wants. The heading carries a timestamp (see agent-block.sh) so
# repeated blocks on one day stay distinguishable.
forgejo_append_issue_body() {
  local repo="$1" number="$2" heading="$3" text="$4"
  local raw current new
  raw=$(forgejo_get_issue "$repo" "$number") || return 1
  current=$(jq -er '
      if (type == "object") and has("number") and has("body")
      then (.body // "") else empty end
    ' <<<"$raw") || return 1
  new=$(printf '%s\n\n---\n## %s\n\n%s\n' "$current" "$heading" "$text")
  _fj PATCH "/repos/${repo}/issues/${number}" \
    "$(jq -n --arg b "$new" '{body: $b}')" >/dev/null
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
#
# jq's own stderr is suppressed HERE rather than by the callers (igor#424):
# both of them want the parse noise gone on a malformed body, but blanketing
# the whole function with `2>/dev/null` also swallows `_fj`'s give-up line,
# and a pipeline's two stages can't be separated from outside. Narrowing it to
# the stage that produces the noise leaves the transport diagnostic audible.
forgejo_pr_non_bot_reviews() {
  local repo="$1" number="$2" bot="$3"
  _fj GET "/repos/${repo}/pulls/${number}/reviews" \
    | jq -c --arg b "$bot" '
        [.[] | select(.user.login != $b)]
        | sort_by(.submitted_at)
      ' 2>/dev/null
}

# The PR-review pickup's Signal-1 check: does this PR's latest non-bot review
# amount to a live, unaddressed "request changes"? Returns that review's JSON
# on stdout if the latest one is REQUEST_CHANGES and neither stale nor
# dismissed; empty otherwise -- including on a fetch failure. Best-effort by
# construction (igor#425): every step degrades to empty rather than
# propagating a nonzero exit, so a caller scanning many PRs
# (`latest=$(forgejo_pr_actionable_request_changes ...)`) can't have one
# transient timeout abort the whole scan under `set -e -o pipefail`.
forgejo_pr_actionable_request_changes() {
  local repo="$1" number="$2" bot="$3" reviews latest state stale dismissed
  # No `2>/dev/null` on this call: the fetch failure it degrades is exactly
  # the one igor#424 asked to be able to SEE, and `_fj` logs it on stderr.
  # jq's noise is already suppressed inside the callee.
  reviews=$(forgejo_pr_non_bot_reviews "$repo" "$number" "$bot") || reviews='[]'
  latest=$(jq -c '.[-1] // empty' <<<"$reviews" 2>/dev/null) || latest=""
  [ -z "$latest" ] && { printf ''; return 0; }
  state=$(jq -r '.state // ""' <<<"$latest" 2>/dev/null || printf '')
  stale=$(jq -r '.stale // false' <<<"$latest" 2>/dev/null || printf 'false')
  dismissed=$(jq -r '.dismissed // false' <<<"$latest" 2>/dev/null || printf 'false')
  if [ "$state" = "REQUEST_CHANGES" ] && [ "$stale" = "false" ] && [ "$dismissed" = "false" ]; then
    printf '%s' "$latest"
  else
    printf ''
  fi
  return 0
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
      2*)
        # igor#439: the operator runs with Forgejo's own notifications off, so
        # a landed review request is the one event worth emailing him about --
        # it is where the loop stops and he becomes the blocker. Fired by name
        # rather than passed in, so this file stays a pure API wrapper and the
        # notifier (lib/reviewnotify.sh, which owns the dedup) is optional.
        # Best-effort: the request already landed, and a notification failure
        # must not turn a success into a failure.
        if declare -F review_notify_human >/dev/null; then
          review_notify_human "$repo" "$number" "$reviewer" || true
        fi
        return 0
        ;;
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

# Open PRs authored by the given user on this repo, as JSON array of
# {number, title, head}, OLDEST-FIRST. The PR-review and auto-merge ticks
# pick which PR to work through this helper, so sort=oldest keeps them
# consistent with the issue grind (forgejo_find_claimable, also
# oldest-first) -- nothing, issue or PR, starves at the back of a deep
# queue. Also briefs Claude on what's in flight so he doesn't duplicate
# work (order-agnostic there).
forgejo_list_open_bot_prs() {
  local repo="$1" user="$2"
  _fj GET "/repos/${repo}/pulls?state=open&sort=oldest&limit=50" \
    | jq --arg u "$user" \
        '[.[] | select(.user.login == $u)
          | {number, title, head: .head.ref}]'
}

# Page cap for forgejo_pr_files. 20 pages x 50 = 1000 changed files, far past
# any PR a human would open; it exists so a server that keeps answering with a
# full page can't spin the tick forever.
FORGEJO_PR_FILES_MAX_PAGES="${FORGEJO_PR_FILES_MAX_PAGES:-20}"

# Files changed in a PR with status (added/modified/removed/renamed) and
# per-file additions/deletions. Returns JSON array of {filename, status,
# additions, deletions}. Used by the post cooldown to detect in-flight post PRs
# before they merge to master, and by the auto-merge risk gate to bound an
# unattended merge.
#
# Pages until a page comes back EMPTY rather than short, for the same reason
# forgejo_open_prs does: `limit=50` is a request, not a promise, and an
# instance with a lower MAX_RESPONSE_ITEMS (or DEFAULT_PAGING_NUM below the
# risk gate's own file cap) would make a truncated first page look like the
# whole list -- which would undercount a big PR's lines and let it through the
# gate. Nonzero with NO output when the list can't be walked to the end (a
# failed request, an unparseable page, or the page cap), so a caller gating a
# merge reads that as "unknown", not "small".
forgejo_pr_files() {
  local repo="$1" number="$2" page=1 batch count all='[]'
  while [ "$page" -le "$FORGEJO_PR_FILES_MAX_PAGES" ]; do
    batch=$(_fj GET "/repos/${repo}/pulls/${number}/files?limit=50&page=${page}") || return 1
    count=$(jq 'length' <<<"$batch" 2>/dev/null) || return 1
    case "$count" in '' | *[!0-9]*) return 1 ;; esac
    [ "$count" -eq 0 ] && { printf '%s' "$all"; return 0; }
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s 'add') || return 1
    page=$((page + 1))
  done
  return 1
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
  local repo="$1" sha="$2" resp state
  resp=$(_fj GET "/repos/${repo}/commits/${sha}/status" 2>/dev/null) || { printf ''; return; }
  state=$(jq -r '.state // ""' <<<"$resp" 2>/dev/null || printf '')
  # v16 fold (igor#414): Forgejo v16 marks a SKIPPED Actions check as its own
  # non-success individual status, which can knock the COMBINED .state off
  # "success" even though nothing failed or is still running -- which would
  # silently stop auto-merge fleet-wide. Rescue it: if there is at least one
  # status and EVERY individual status is terminal and non-failing (none
  # pending/failure/error -- i.e. success/skipped/warning only), the head is
  # green. v15-safe: pre-v16 a green head already reports combined "success", so
  # this never rewrites an existing answer; it only catches the new skipped case.
  if [ "$state" != "success" ]; then
    jq -e '
      (.statuses // []) as $s
      | ($s | length > 0)
        and (all($s[]?; ((.status // "") | ascii_downcase) as $st
                        | $st != "pending" and $st != "failure" and $st != "error"))
    ' <<<"$resp" >/dev/null 2>&1 && state="success"
  fi
  printf '%s' "$state"
}

# --- v16 Actions job logs (igor#415) -----------------------------------------
# Feed *why* CI failed into the rework prompt. Given a PR head sha whose CI is
# RED, collect the failing Actions run's job-log tails so the rework agent can
# fix the build break, not only the review comments. These are v16-only REST
# endpoints; on v15 they 404 -> _fj/curl returns non-zero -> we degrade to an
# empty string. So the caller can invoke this UNCONDITIONALLY: it is also empty
# when CI is green (no failing run/job to report). No version probe -- same
# graceful-no-op convention as forgejo_commit_status (igor#414). The endpoint
# shapes were verified against a live Forgejo v16.0.1 instance.
FORGEJO_ACTIONS_LOG_MAX_TIME=30    # a job log is heavier than a JSON call
FORGEJO_CI_LOG_TAIL_LINES=100      # per failing job: keep the last N lines (the error sits at the tail)
FORGEJO_CI_LOG_MAX_JOBS=3          # cap total jobs injected so the rework prompt stays bounded

# Plain-text log for one Actions job id, or empty on any failure (incl. a v15
# 404). Own curl (not _fj): the endpoint returns text/plain and a job log can be
# large enough to want a longer timeout than _fj's fail-fast JSON budget.
forgejo_action_job_log() {
  local repo="$1" job_id="$2"
  [ -n "$job_id" ] || { printf ''; return; }
  curl -sf --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" --max-time "$FORGEJO_ACTIONS_LOG_MAX_TIME" \
    -H "Authorization: token $FORGEJO_TOKEN" \
    "$FORGEJO_URL/api/v1/repos/${repo}/actions/jobs/${job_id}/logs" 2>/dev/null || printf ''
}

# A markdown block of the failing CI job-log tails for <repo> <sha>, or empty if
# nothing is failing / the Actions API is unavailable (v15). Self-gating: safe to
# call on every rework -- it returns empty unless there is a genuinely FAILED job.
forgejo_failing_ci_logs() {
  local repo="$1" sha="$2" runs rids rid jobs jid jname jstat log tail_log block out="" n=0
  [ -n "$sha" ] || { printf ''; return; }
  runs=$(_fj GET "/repos/${repo}/actions/runs?head_sha=${sha}&limit=20" 2>/dev/null) || { printf ''; return; }
  # Runs for this head whose status is a real failure (not success/skipped/pending/running).
  rids=$(jq -r '(.workflow_runs // [])[]
                | select((.status // "") as $s | $s == "failure" or $s == "error")
                | .id' <<<"$runs" 2>/dev/null) || { printf ''; return; }
  [ -n "$rids" ] || { printf ''; return; }
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    [ "$n" -ge "$FORGEJO_CI_LOG_MAX_JOBS" ] && break
    jobs=$(_fj GET "/repos/${repo}/actions/runs/${rid}/jobs" 2>/dev/null) || continue
    # /jobs returns a BARE list; keep only the failed jobs.
    while IFS=$'\t' read -r jid jname jstat; do
      [ -n "$jid" ] || continue
      [ "$n" -ge "$FORGEJO_CI_LOG_MAX_JOBS" ] && break
      log=$(forgejo_action_job_log "$repo" "$jid")
      [ -n "$log" ] || continue
      tail_log=$(printf '%s' "$log" | tail -n "$FORGEJO_CI_LOG_TAIL_LINES")
      block=$(printf '\n### Job `%s` (%s) -- last %s lines of its log\n```\n%s\n```\n' \
                "$jname" "$jstat" "$FORGEJO_CI_LOG_TAIL_LINES" "$tail_log")
      out="${out}${block}"
      n=$((n + 1))
    done < <(jq -r '.[]
                    | select((.status // "") as $s | $s == "failure" or $s == "error")
                    | [(.id | tostring), (.name // "job"), (.status // "")]
                    | @tsv' <<<"$jobs" 2>/dev/null)
  done <<<"$rids"
  [ -n "$out" ] || { printf ''; return; }
  printf '\n## CI is failing on this PR head -- fix the build too\n\nThe CI checks on this PR head are RED. Below are the tails of the failing Actions job logs (the error is usually near the end). Diagnose and fix the CI failure as part of this rework, and make sure the project tests + lint pass before you exit.\n%s' "$out"
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

# Page cap for forgejo_open_prs. 20 pages x 50 = 1000 open PRs, far past any
# real repo; it exists so a server that keeps answering with a full page can't
# spin the tick forever.
FORGEJO_OPEN_PRS_MAX_PAGES="${FORGEJO_OPEN_PRS_MAX_PAGES:-20}"

# forgejo_open_prs <repo> -- every open pull request in <repo>, one JSON array.
# Nonzero with NO output when the listing couldn't be walked to the end (a
# failed request, an unparseable page, or the page cap) -- callers gating a
# destructive step must read that as "unknown", not "none".
#
# Pages until a page comes back EMPTY rather than short: `limit=50` is a
# request, not a promise, and a Forgejo with a lower MAX_RESPONSE_ITEMS would
# make a short first page look like the whole list. One extra request per repo
# per tick buys that; the callers hoist this out of their loops.
forgejo_open_prs() {
  local repo="$1" page=1 batch count all='[]'
  while [ "$page" -le "$FORGEJO_OPEN_PRS_MAX_PAGES" ]; do
    batch=$(_fj GET "/repos/${repo}/pulls?state=open&limit=50&page=${page}") || return 1
    count=$(jq 'length' <<<"$batch" 2>/dev/null) || return 1
    case "$count" in '' | *[!0-9]*) return 1 ;; esac
    [ "$count" -eq 0 ] && { printf '%s' "$all"; return 0; }
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s 'add') || return 1
    page=$((page + 1))
  done
  return 1
}

# forgejo_prs_covering_issue <open_prs_json> <issue_num> -- of the PRs in
# <open_prs_json> (forgejo_open_prs's shape), those already covering this
# issue, as [{number, title, head}]. Author-independent, unlike
# forgejo_bot_prs_for_issue. Two arms:
#
#   1. Head branch in the issue's own `agent/<n>`/`agent/<n>-*` namespace.
#      This is the load-bearing one: EVERY bot PR for an issue lives there
#      (bin/tick.sh builds BRANCH as agent/<n>[-slug] and resumes on it), so
#      it covers the whole class of PR this gate exists to protect (igor#496)
#      with no false-positive surface -- that namespace is the harness's own.
#   2. A STANDALONE closing line for <n> -- the `Closes #N` form
#      pr_body_ensure_closes appends, or a human writing `Fixes #N` on its own
#      line. Deliberately NARROWER than pr_body_ensure_closes's "already
#      satisfied" test, which accepts the keyword anywhere in the body: igor's
#      own PR bodies routinely discuss other tickets in prose ("this PR fixes
#      issue NNN by..."), and a keyword-anywhere match there makes the
#      discovery loop skip that unrelated issue on every tick, silently and
#      indefinitely, for as long as the PR stays open (igor#497 review). A
#      false negative here just costs a duplicate claim, which arm 1 and the
#      pre-worktree branch abort in bin/tick.sh both still catch.
#
# jq's regex engine anchors `^`/`$` to the whole STRING, not to each line, so
# the line boundaries are spelled out as `(\A|\n)` / `(\n|\z)`.
forgejo_prs_covering_issue() {
  jq -c --arg n "$2" '
      [.[]
       | select(
           ((.head.ref // "") | test("^agent/" + $n + "($|-)"))
           or ((.body // "") | test(
                 "(?i)(\\A|\\n)[ \\t>*+-]*(close[sd]?|fix(e[sd])?|resolve[sd]?)"
                 + "[ \\t]+#" + $n + "[ \\t]*[.;,)]?[ \\t\\r]*(\\n|\\z)"))
         )
       | {number, title: (.title // ""), head: (.head.ref // "")}]' <<<"$1"
}

# forgejo_open_pr_covers_issue <repo> <issue_num> -- forgejo_open_prs piped
# into forgejo_prs_covering_issue, for one-shot callers. Propagates the
# "listing incomplete" nonzero.
forgejo_open_pr_covers_issue() {
  local prs
  prs=$(forgejo_open_prs "$1") || return 1
  forgejo_prs_covering_issue "$prs" "$2"
}

# forgejo_prs_on_branches <covering_json> <branches> -- of the PR entries in
# <covering_json> (forgejo_prs_covering_issue's shape), those whose head ref
# is one of the newline-separated <branches>, rendered as "#N (ref), ...".
# Empty output means no open PR is built on any of those branches, i.e. they
# are leftovers from closed or merged PRs and safe to reset.
forgejo_prs_on_branches() {
  jq -r --arg b "$2" '
      ($b | split("\n")) as $branches
      | [.[] | select(.head as $h | any($branches[]; . == $h)) | "#\(.number) (\(.head))"]
      | join(", ")' <<<"$1"
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

# forgejo_repo_get_file_status <repo> <path> -- like forgejo_repo_get_file,
# but distinguishes WHY there's no content instead of collapsing every
# failure into the same nonzero. Echoes "<status>\t<content>" (content only
# set when status=found; rc is always 0 -- the status IS the answer):
#   found   -- the file exists; content (base64-decoded) follows
#   missing -- the API answered 404: the file is genuinely not there
#   error   -- anything else (403, 5xx, or no response at all) -- the API
#              could not answer, so the caller must NOT read this as
#              "absent"; treat it as "unknown this tick"
#
# Own curl, not _fj: `-f` collapses EVERY HTTP >= 400 into exit 22, so a 403
# (token/permission hiccup) or a 502 is indistinguishable there from the 404
# that means "no such file" -- and that is the entire distinction this
# function exists to make (igor#520). The HTTP status rides back on a final
# line via -w. Same timeouts as _fj, but no retry: an unanswered read here
# already has a safe answer -- `error`, on which the caller skips the repo
# and re-reads it on the next tick a minute later -- so there is nothing to
# buy by holding the tick open for 3 x FORGEJO_MAX_TIME first.
#
# Callers that need this distinction: lib/dossier.sh's dossier_get_repo_status
# (igor#520 -- a plain dossier_get_repo swallows a flaky fetch into the same
# empty value as a repo that genuinely declares nothing, which is unsafe for
# a decision as consequential as "does this repo have a live URL to watch").
forgejo_repo_get_file_status() {
  local repo="$1" path="$2" out code body
  # `|| true` so the function is errexit-safe on its own terms rather than by
  # the grace of its call sites: curl exits nonzero on a transport failure and
  # the status line it wrote is still the answer we want.
  out=$(curl -s -w '\n%{http_code}' --connect-timeout "$FORGEJO_CONNECT_TIMEOUT" \
    --max-time "$FORGEJO_MAX_TIME" \
    -H "Authorization: token $FORGEJO_TOKEN" \
    "$FORGEJO_URL/api/v1/repos/${repo}/contents/${path}" 2>/dev/null) || true
  code=${out##*$'\n'}; body=${out%$'\n'*}
  case "$code" in
    2[0-9][0-9]) printf 'found\t%s' "$(jq -r '.content // empty' <<<"$body" | base64 -d 2>/dev/null || true)" ;;
    404)         printf 'missing\t' ;;
    *)           printf 'error\t' ;;
  esac
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
