#!/usr/bin/env bash
# GitLab API helpers. Sourced by bin/tick.sh and bin/agent-*.sh.
#
# This is a FAITHFUL PORT of lib/forgejo.sh against GitLab's v4 API. The
# function names are deliberately kept as `forgejo_*` so the cutover is
# swapping one `source` line instead of editing ~800 call sites. The names are
# acknowledged debt; renaming is a separate job and must not ride along here.
#
# Requires in environment:
#   GITLAB_URL    -- e.g. https://gitlab.com
#   GITLAB_TOKEN  -- the service account's PAT (loaded from $AGENT_HOME/.env)
#
# Requires on PATH: curl, jq.
#
# -- How GitLab differs from Forgejo, once, here, so the bodies stay readable --
#
#  * Auth header is `PRIVATE-TOKEN`, not `Authorization: token`.
#  * Base path is /api/v4, and a project is addressed by its URL-ENCODED path
#    ("owner/name" -> "owner%2Fname"). _gl_proj does that; every caller that
#    takes <repo> in "<owner>/<name>" form still does, unchanged.
#  * Issues and MRs are addressed by `iid` (per-project), NOT `id` (global).
#    Everything here that takes a "number" takes an iid, which is what the
#    Forgejo code called a number, so callers are unaffected.
#  * Open state is `opened`, not `open`. Closed-and-merged is its own state
#    (`merged`), where Forgejo used closed + a .merged flag -- see
#    forgejo_bot_prs_for_issue, which reconstructs the Forgejo shape.
#  * Labels are added/removed with `add_labels=` / `remove_labels=` on the
#    issue PUT. A plain `labels=` write REPLACES the whole set and silently
#    drops every label it wasn't told about -- never use it to add one.
#  * Assignees are numeric `assignee_ids`, not logins, so assignment needs a
#    username->id lookup (_gl_user_id, memoized per process).
#  * REVIEWS DO NOT EXIST. GitLab Free has approvals (unenforceable, no
#    REQUEST_CHANGES state) and discussions. The Forgejo review contract is
#    synthesized from both -- see the block above forgejo_pr_reviews. This is
#    the one place the port is an adaptation rather than a translation.

: "${GITLAB_URL:?GITLAB_URL must be set}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN must be set}"

# -- Compatibility aliases -------------------------------------------------
#
# The harness refers to forge config by its FORGEJO_* names in ~200 places
# (FORGEJO_REVIEWER alone is 120). Those names are aliased to the GitLab values
# here rather than renamed at every call site, for the same reason the
# forgejo_* FUNCTION names were kept: the cutover stays a small, reviewable
# diff instead of a 200-site sed that touches every file in the repo.
#
# This is naming debt, deliberately taken, and it is the SECOND layer of it in
# this file. Renaming both layers is a follow-up, not a cutover-night change.
#
# FORGEJO_REVIEWER is NOT set here -- it comes from .env and happens to be the
# same username on both forges (joshtronic), so there is nothing to translate.
# FORGEJO_HOST is only read to derive an ssh target (bin/validate.sh) and for
# diagnostics (bin/doctor.sh); the clone URLs come from gl_clone_url below.
FORGEJO_URL="$GITLAB_URL"
FORGEJO_TOKEN="$GITLAB_TOKEN"
FORGEJO_HOST="${GITLAB_HOST:-gitlab.com}"
export FORGEJO_URL FORGEJO_TOKEN FORGEJO_HOST

# gl_clone_url <owner/repo> -- the git URL the harness clones and fetches with.
# HTTPS with the token embedded, not SSH: one credential serves both git and
# the API, there is no deploy key to manage, and it avoids the port/IPv6
# handling the Forgejo host needed. Callers must not log the result verbatim.
gl_clone_url() {
  printf 'https://oauth2:%s@%s/%s.git' "$GITLAB_TOKEN" "${GITLAB_HOST:-gitlab.com}" "$1"
}

# bin/tick.sh defines log() before sourcing this; bin/agent-*.sh and the unit
# tests may not. Same fallback shape as lib/forgejo.sh.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# Timeouts and retry policy are carried over verbatim from lib/forgejo.sh --
# they were tuned against real incidents (igor#395, igor#424, igor#425) and
# nothing about changing forge vendor changes the reasoning:
#   - a brief host blip must fail fast rather than wedge a tick
#   - GET/HEAD retry on TRANSPORT failures only; a POST that times out may
#     have landed server-side, and a naive retry would double-post
#   - HTTP >= 400 is an ANSWER, not a hiccup, so it is never retried
# Hardcoded -- one operator, bake the values in.
GITLAB_CONNECT_TIMEOUT=5
GITLAB_MAX_TIME=15
GITLAB_RETRY_COUNT=2
GITLAB_RETRY_DELAY=1
GITLAB_RETRY_CURL_CODES='7 28 35 52 56'

# igorbot shares GitLab.com's Free-plan 100-req/min-per-user budget with every
# other consumer of the same token (igor#26: a single tick burned the budget
# in 20s and every other consumer, including the stonks deploy fetch, got
# 429'd too). Pace off the RateLimit-* response headers so this process keeps
# headroom for the others instead of running the budget to zero itself.
# Hardcoded floor, no env knob -- one operator.
GITLAB_RATELIMIT_FLOOR=20
# Last-seen values, updated after every response that carries the headers
# (success or error alike) and read by _gl_rl_pace before the NEXT request.
# Empty until the first response arrives; set -u safe.
_GL_RL_REMAINING=""
_GL_RL_RESET=""

# _gl_rl_header <header-dump-file> <name> -- last matching header value,
# trimmed, or empty. Last match wins (curl -D appends on redirects/retries
# within one invocation; a later line is the newer answer). The `|| true` is
# load-bearing, not decoration: grep exits 1 on no match, and every caller of
# lib/gitlab.sh runs under `set -eo pipefail` (bin/tick.sh, bin/agent-*.sh),
# so an absent header would otherwise abort the whole script right here.
_gl_rl_header() {
  grep -i "^${2}:" "$1" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//' || true
}

# _gl_rl_update <header-dump-file> -- record RateLimit-Remaining/-Reset for
# the next call to pace against. A non-numeric or absent header leaves the
# prior value alone rather than clobbering it with garbage. Explicit `return
# 0`: this is called as a bare statement, and its last line is a `cond &&
# action` whose condition can legitimately be false (header absent) -- under
# `set -e` a bare call to a function whose last executed command failed
# aborts the caller, even though that same failure is exempted from -e
# INSIDE this function (it precedes the list's final &&).
_gl_rl_update() {
  local remaining reset
  remaining=$(_gl_rl_header "$1" "ratelimit-remaining")
  reset=$(_gl_rl_header "$1" "ratelimit-reset")
  [[ "$remaining" =~ ^[0-9]+$ ]] && _GL_RL_REMAINING="$remaining"
  [[ "$reset" =~ ^[0-9]+$ ]] && _GL_RL_RESET="$reset"
  return 0
}

# _gl_rl_sleep_until <epoch-seconds> -- sleep off the remainder of the window,
# never negative (a stale/past reset is a no-op, not a negative sleep arg).
# Explicit `return 0` at the end -- same bare-statement hazard as
# _gl_rl_update above: "nothing to sleep for" is success, not failure.
_gl_rl_sleep_until() {
  local target="$1" delta
  [[ "$target" =~ ^[0-9]+$ ]] || return 0
  delta=$((target - $(date +%s)))
  [ "$delta" -gt 0 ] && sleep "$delta"
  return 0
}

# _gl_rl_pace -- called before every request. Once the last-seen remaining
# count drops below the floor, hold off until the window resets rather than
# spending the last few requests ourselves and 429ing every other consumer of
# the same token.
_gl_rl_pace() {
  [[ "$_GL_RL_REMAINING" =~ ^[0-9]+$ ]] || return 0
  [ "$_GL_RL_REMAINING" -lt "$GITLAB_RATELIMIT_FLOOR" ] || return 0
  _gl_rl_sleep_until "$_GL_RL_RESET"
  return 0
}

# _gl_rl_retry_after <header-dump-file> -- Retry-After in seconds, or empty
# when absent/non-numeric (GitLab sends a plain integer, never an HTTP-date).
# Explicit `return 0` -- same bare-statement/command-substitution hazard as
# _gl_rl_update above.
_gl_rl_retry_after() {
  local raw
  raw=$(_gl_rl_header "$1" "retry-after")
  [[ "$raw" =~ ^[0-9]+$ ]] && printf '%s' "$raw"
  return 0
}

# _gl_proj <owner/name> -- URL-encode a project path for use as :id. Only the
# slash needs encoding for the paths this harness uses; doing it with a
# parameter expansion rather than jq keeps it usable in hot loops.
_gl_proj() {
  printf '%s' "${1//\//%2F}"
}

# _gl_path <path-segment> -- URL-encode a repo-relative FILE path. Unlike
# _gl_proj this must also escape dots are fine but slashes and spaces are not,
# and GitLab's files endpoint wants the whole path as one encoded segment.
_gl_path() {
  jq -rn --arg s "$1" '$s|@uri'
}

# _gl <METHOD> <path> [json-body] -- the request wrapper. Same contract as
# lib/forgejo.sh's _fj: buffered (so a retryable attempt can't emit a partial
# body), re-emits the trailing newline curl produced, stays empty on a 204,
# and logs ONLY the exhausted-transport/429 case (an ordinary HTTP status is
# an answer and would be pure noise -- a 404 for an absent agent.json is the
# common path). Paces on RateLimit-Remaining/-Reset before every attempt and
# retries a 429 (never a server fault -- the request was rejected before it
# reached a handler, so it is always safe to retry regardless of method)
# honouring Retry-After, falling back to RateLimit-Reset when that header is
# absent. No longer `curl -f`: that discarded headers along with the body, and
# pacing needs them even on a non-2xx.
_gl() {
  local method="$1" path="$2" body="${3:-}"
  local transport_attempts=1
  case "$method" in
    GET|HEAD) transport_attempts=$((GITLAB_RETRY_COUNT + 1)) ;;
  esac
  local rl_attempts=$((GITLAB_RETRY_COUNT + 1))
  local max_attempts=$transport_attempts
  [ "$rl_attempts" -gt "$max_attempts" ] && max_attempts=$rl_attempts

  local -a extra=()
  if [ -n "$body" ]; then
    extra=(-H "Content-Type: application/json" -d "$body")
  fi

  local header_tmp
  header_tmp=$(mktemp) || {
    log "gitlab: ${method} ${path} -- mktemp failed, cannot capture headers" >&2
    return 1
  }
  trap 'rm -f "$header_tmp"; trap - RETURN' RETURN

  local attempt=0 transport_tries=0 rl_tries=0
  local out rc http_code resp_body retry_after
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    _gl_rl_pace
    : >"$header_tmp"
    if out=$(curl -s -D "$header_tmp" -w '\n%{http_code}' \
        --connect-timeout "$GITLAB_CONNECT_TIMEOUT" --max-time "$GITLAB_MAX_TIME" -X "$method" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${extra[@]+"${extra[@]}"}" \
        "$GITLAB_URL/api/v4${path}"); then
      rc=0
    else
      rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
      transport_tries=$((transport_tries + 1))
      [[ " $GITLAB_RETRY_CURL_CODES " == *" $rc "* ]] || return "$rc"
      [ "$transport_tries" -lt "$transport_attempts" ] || break
      sleep "$GITLAB_RETRY_DELAY"
      continue
    fi

    http_code="${out##*$'\n'}"
    resp_body="${out%$'\n'*}"
    _gl_rl_update "$header_tmp"

    if [ "$http_code" = "429" ]; then
      rl_tries=$((rl_tries + 1))
      if [ "$rl_tries" -ge "$rl_attempts" ]; then
        log "gitlab: ${method} ${path} -- exhausted 429 retries" >&2
        return 22
      fi
      retry_after=$(_gl_rl_retry_after "$header_tmp")
      if [ -n "$retry_after" ]; then
        sleep "$retry_after"
      else
        _gl_rl_sleep_until "$_GL_RL_RESET"
      fi
      continue
    fi

    if [ "$http_code" -ge 400 ]; then
      return 22
    fi

    [ -n "$resp_body" ] && printf '%s\n' "$resp_body"
    return 0
  done
  log "gitlab: ${method} ${path} failed after ${attempt} attempt(s) (curl exit ${rc})" >&2
  return "$rc"
}

# _gl_user_id <username> -- numeric user id for a login, or empty. GitLab
# assignment and review-request take ids, not names, so this sits behind
# forgejo_assign / forgejo_request_review. Memoized for the life of the
# process: the harness resolves the same two or three logins (the bot and the
# reviewer) many times per tick, and each miss is a network round trip.
declare -A _GL_UID_CACHE=()
_gl_user_id() {
  local name="$1" id
  [ -n "$name" ] || { printf ''; return 0; }
  if [ -n "${_GL_UID_CACHE[$name]:-}" ]; then
    printf '%s' "${_GL_UID_CACHE[$name]}"
    return 0
  fi
  id=$(_gl GET "/users?username=$(_gl_path "$name")" 2>/dev/null \
       | jq -r 'if type=="array" then (.[0].id // empty) else empty end' 2>/dev/null) || id=""
  [ -n "$id" ] && _GL_UID_CACHE[$name]="$id"
  printf '%s' "$id"
}

# _gl_paged <path-without-page> -- walk every page of a list endpoint into one
# JSON array. Pages until a page comes back EMPTY rather than short, for the
# same reason the Forgejo helpers did: `per_page=50` is a request, not a
# promise, and an instance answering with fewer would make a truncated first
# page look like the whole list. Nonzero with NO output when the listing
# cannot be walked to the end, so a caller gating a destructive step reads
# that as "unknown", not "none".
#
# <path> must already carry its query string; this appends per_page/page with
# the right separator.
GITLAB_PAGED_MAX_PAGES="${GITLAB_PAGED_MAX_PAGES:-20}"
_gl_paged() {
  local path="$1" page=1 batch count all='[]' sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  while [ "$page" -le "$GITLAB_PAGED_MAX_PAGES" ]; do
    batch=$(_gl GET "${path}${sep}per_page=50&page=${page}") || return 1
    count=$(jq 'length' <<<"$batch" 2>/dev/null) || return 1
    case "$count" in '' | *[!0-9]*) return 1 ;; esac
    [ "$count" -eq 0 ] && { printf '%s' "$all"; return 0; }
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s 'add') || return 1
    page=$((page + 1))
  done
  return 1
}

# All open issues with label:Agent, no Status/Blocked, and no blocking
# assignee, sorted oldest-first. Caller iterates and applies additional
# filtering (in-flight MR check, rejected-MR strike count) to pick the first
# issue that's actually workable.
#
# $1  repo         -- <owner>/<name>
# $2  reviewer     -- optional reviewer login. When set, an issue assigned
#                     SOLELY to the reviewer is still claimable (it means the
#                     bot blocked it and the reviewer was notified, but the
#                     issue is the bot's to claim once Status/Blocked is
#                     removed). When empty, falls back to zero-assignees only.
#
# The client-side label re-verify is kept from the Forgejo version even though
# the bug that motivated it is Forgejo-specific (Forgejo IGNORES a filter
# naming a label the repo doesn't define, returning ALL open issues instead of
# none -- which made the greenlight gate fail OPEN on a freshly-onboarded
# repo). GitLab filters correctly. It stays anyway: it costs one jq pass, and
# a gate that fails CLOSED regardless of what the server does with an unknown
# label is worth more than the cycles.
forgejo_find_claimable() {
  local repo="$1" reviewer="${2:-}"
  # Filter on the RAW payload, then shim. Order matters: GitLab returns labels
  # as bare strings and this filter indexes them as such, but _gl_issue_shim
  # rewrites them into Forgejo's [{name}] objects -- shimming first would make
  # every index("Agent") miss and the gate would fail OPEN.
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=opened&labels=Agent&order_by=created_at&sort=asc&per_page=50" \
    | jq -c --arg reviewer "$reviewer" '
        [.[] | select(
          (
            ((.assignees // []) | length) == 0
            or (
              $reviewer != ""
              and ((.assignees // []) | length) == 1
              and (.assignees[0].username == $reviewer)
            )
          )
          and ((.labels // []) | index("Agent")) != null
          and ((.labels // []) | index("Status/Blocked")) == null
        )] | sort_by(.created_at)
      ' \
    | _gl_issue_shim
}

# Quiet period on the INITIAL claim only (igor#591): a label change bumps
# `updated_at` the same as a body edit, so gating on it covers both "just
# labeled" and "just edited" without a second signal. Hardcoded.
FORGEJO_CLAIM_QUIET_PERIOD_SECS=900

# Seconds still left in the quiet period for an issue last updated at
# <updated_at_iso>; 0 once elapsed. Pure date arithmetic -- no API surface, so
# this is a verbatim carry-over from lib/forgejo.sh including the fail-OPEN
# behavior on an unparseable timestamp (failing closed on a date the harness
# can't read would starve the grind fleet-wide off one bad field).
forgejo_claim_quiet_seconds_remaining() {
  local updated_at="$1" now="${2:-}"
  [ -n "$now" ] || now=$(date +%s)
  local updated_epoch=""
  if [ -n "$updated_at" ]; then
    updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || updated_epoch=""
  fi
  if [ -z "$updated_epoch" ]; then
    log "warning: unusable issue updated_at [${updated_at}] -- claim quiet period not applied" >&2
    echo 0
    return
  fi
  local age=$(( now - updated_epoch ))
  local remaining=$(( FORGEJO_CLAIM_QUIET_PERIOD_SECS - age ))
  [ "$remaining" -lt 0 ] && remaining=0
  echo "$remaining"
}

# One issue by iid. GitLab calls the body `description`; the whole harness
# reads `.body`, so it is aliased here rather than at 200 call sites. Same for
# `.user.login` (GitLab: `.author.username`) and `.labels` (GitLab returns
# bare strings, Forgejo returns objects with .name).
_gl_issue_shim() {
  jq -c '
    def one:
      if type == "object" and has("iid") then
        . + {
          number: .iid,
          body: (.description // ""),
          user: { login: (.author.username // "") },
          labels: [ (.labels // [])[] | {name: .} ],
          repository: {
            full_name: ((.references.full // "") | sub("[#!].*$"; ""))
          },
          html_url: (.web_url // "")
        }
      else . end;
    if type == "array" then [ .[] | one ] else one end'
}

forgejo_get_issue() {
  local repo="$1" number="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/issues/${number}" | _gl_issue_shim
}

# Appends <text> under a "## <heading>" section at the end of the issue's
# current body and writes it back. Used by agent-block.sh (igor#434): the
# issue-work prompt feeds ONLY the issue body to the next tick's Claude
# invocation -- comments are never read -- so a block reason posted solely as
# a comment can never reach a re-queued run.
#
# The two-step validation is kept verbatim from the Forgejo version because
# its failure mode is DESTRUCTIVE: a naive one-liner writes the block note in
# as the entire description, erasing the text this helper exists to preserve.
# Both halves of the naive form are wrong -- a pipeline's status is jq's, not
# the fetch's, and `jq -r '.body // empty'` on empty stdin exits 0; and exit
# status alone isn't enough anyway, since any 2xx payload that isn't an issue
# is still well-formed JSON whose .body is "" with exit 0.
forgejo_append_issue_body() {
  local repo="$1" number="$2" heading="$3" text="$4"
  local raw current new
  raw=$(forgejo_get_issue "$repo" "$number") || return 1
  current=$(jq -er '
      if (type == "object") and has("number") and has("body")
      then (.body // "") else empty end
    ' <<<"$raw") || return 1
  new=$(printf '%s\n\n---\n## %s\n\n%s\n' "$current" "$heading" "$text")
  forgejo_set_issue_body "$repo" "$number" "$new"
}

# Full replace of an issue's body. The caller is responsible for having read
# the current body first if it needs to preserve any of it.
forgejo_set_issue_body() {
  local repo="$1" number="$2" body="$3"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" \
    "$(jq -n --arg b "$body" '{description: $b}')" >/dev/null
}

forgejo_assign() {
  local repo="$1" number="$2" user="$3" uid
  uid=$(_gl_user_id "$user")
  [ -n "$uid" ] || { log "gitlab: cannot resolve user [$user] to assign" >&2; return 1; }
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" \
    "$(jq -n --argjson u "$uid" '{assignee_ids: [$u]}')" >/dev/null
}

forgejo_unassign_all() {
  local repo="$1" number="$2"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" '{"assignee_ids": []}' >/dev/null
}

# forgejo_pr_assign / forgejo_pr_unassign_all -- assignee writes on a MERGE
# REQUEST.
#
# Third instance of the same root cause as forgejo_pr_comment: Forgejo made a
# PR literally an issue and one endpoint served both, GitLab keeps them in
# SEPARATE iid spaces, and these target /issues/:iid.
#
# This one did real damage before it was caught. review_route_into_rework
# assigns the bot to the MR it is reworking; with the issues endpoint that
# assigned ISSUE #6 ("pour from a verified Distillery tag") instead of MR !6.
# The recovery sweep then correctly saw an issue assigned to the bot with no
# work in flight, declared it orphaned, commented "Previous tick was
# interrupted" on it and unassigned it -- once per rework round. The issue was
# never being worked at all.
#
# Any caller holding a PR/MR number must use these.
forgejo_pr_assign() {
  local repo="$1" number="$2" user="$3" uid
  uid=$(_gl_user_id "$user")
  [ -n "$uid" ] || { log "gitlab: cannot resolve user [$user] to assign" >&2; return 1; }
  _gl PUT "/projects/$(_gl_proj "$repo")/merge_requests/${number}" \
    "$(jq -n --argjson u "$uid" '{assignee_ids: [$u]}')" >/dev/null
}

forgejo_pr_unassign_all() {
  local repo="$1" number="$2"
  _gl PUT "/projects/$(_gl_proj "$repo")/merge_requests/${number}" '{"assignee_ids": []}' >/dev/null
}

forgejo_comment() {
  local repo="$1" number="$2" body="$3"
  _gl POST "/projects/$(_gl_proj "$repo")/issues/${number}/notes" \
    "$(jq -n --arg b "$body" '{body: $b}')" >/dev/null
}

# forgejo_pr_comment <repo> <mr_iid> <body> -- comment on a MERGE REQUEST.
#
# This exists because GitLab keeps issues and merge requests in SEPARATE iid
# spaces, where Forgejo made a PR literally an issue and one endpoint served
# both. forgejo_comment targets /issues/:iid/notes; calling it with an MR iid
# either 404s (no issue with that number) or -- far worse -- posts the comment
# onto an UNRELATED ISSUE that happens to share the number. sherver/igor has
# both an issue #4 and an MR !4, so a review verdict for the MR would have
# landed on the issue.
#
# Callers that hold a PR/MR number must use this. See the sweep in the commit
# that introduced it for the 14 sites that did.
forgejo_pr_comment() {
  local repo="$1" number="$2" body="$3"
  _gl POST "/projects/$(_gl_proj "$repo")/merge_requests/${number}/notes" \
    "$(jq -n --arg b "$body" '{body: $b}')" >/dev/null
}

# Log time spent on an issue/MR. GitLab has a real endpoint for this (unlike
# the `/spend` quick-action-in-a-note workaround), and it takes a HUMAN
# duration string, not seconds -- so the caller's seconds are rendered as
# "<n>s", which GitLab parses. Best-effort: warns and returns non-zero if the
# API rejects, but never aborts the caller. Skips entirely if seconds <= 0.
#
# NOTE: on GitLab, issues and MRs do NOT share an iid space (unlike Forgejo,
# where a PR IS an issue). The Forgejo version relied on that; here the caller
# must say which. Defaults to issues, which is every current call site.
forgejo_log_time() {
  local repo="$1" number="$2" seconds="$3" kind="${4:-issues}"
  [ -z "$seconds" ] || [ "$seconds" -le 0 ] 2>/dev/null && return 0
  _gl POST "/projects/$(_gl_proj "$repo")/${kind}/${number}/add_spent_time" \
    "$(jq -n --arg d "${seconds}s" '{duration: $d}')" >/dev/null 2>&1 \
    || return 1
}

# -- Merge requests -------------------------------------------------------
#
# Shim an MR into the Forgejo PR shape the harness reads. Aliased rather than
# fixed at the call sites so this file stays the only thing that knows the
# vendor:
#   .number    <- .iid
#   .body      <- .description
#   .user.login<- .author.username
#   .repository.full_name <- .references.full, with the trailing ref stripped
#     ("sherver/igor#8" -> "sherver/igor"). Note GitLab numbers ISSUES with '#'
#     and MERGE REQUESTS with '!', so both separators are stripped -- splitting
#     on '#' alone silently leaves "sherver/igor!2" for every MR. GitLab's CROSS-PROJECT endpoints
#     (/issues, /merge_requests with scope=assigned_to_me) return no project
#     path at all -- only a numeric project_id -- where Forgejo's search
#     endpoint carried a whole .repository object. Three call sites read
#     .repository.full_name off those results (bin/tick.sh:4020 recovery sweep,
#     :4130 and :4143 PR-review pickup) and got null, which took the harness
#     down for ~9h: the sweep logged "null#8 orphaned", then
#     forgejo_comment null 8 404'd, curl exited 22, and errexit killed the tick
#     BEFORE the unassign that would have cleared the orphan -- so every
#     subsequent tick repeated it. Populating it in the shim fixes all three
#     readers at once; fixing tick.sh would have left the other two.
#   .head.ref  <- .source_branch        .head.sha <- .sha
#   .base.ref  <- .target_branch
#   .merged    <- (.state == "merged")  -- GitLab makes merged its own state,
#                 where Forgejo used state=closed plus a .merged flag. Callers
#                 that switch on BOTH (forgejo_bot_prs_for_issue) get the
#                 Forgejo pair back: state "closed" and merged true/false.
_gl_mr_shim() {
  jq -c '
    def one:
      . + {
        number: .iid,
        body: (.description // ""),
        user: { login: (.author.username // "") },
        head: { ref: (.source_branch // ""), sha: (.sha // "") },
        base: { ref: (.target_branch // "") },
        merged: (.state == "merged"),
        state: (if .state == "opened" then "open"
                elif .state == "merged" then "closed"
                else (.state // "") end),
        repository: {
          full_name: ((.references.full // "") | sub("[#!].*$"; ""))
        },
        # automerge_mergeable (lib/automerge.sh) gates on `.mergeable == true`.
        # GitLab has no such boolean -- it reports detailed_merge_status, which
        # is "mergeable" only when the MR is genuinely ready and otherwise names
        # the reason ("checking", "ci_still_running", "conflict", ...). Mapping
        # it here is what makes the gate work: without this the field was simply
        # ABSENT, `.mergeable == true` was false for every MR, and automerge
        # logged "not cleanly mergeable -- skipping" forever on MRs GitLab
        # itself reported as can_be_merged.
        #
        # "checking" deliberately maps to false: GitLab has not finished
        # computing it, so the honest answer is "not known yet" and the next
        # tick re-reads. merge_status is the legacy fallback for an instance
        # that predates detailed_merge_status.
        mergeable: (
          if (.detailed_merge_status // "") != "" then
            (.detailed_merge_status == "mergeable")
          else
            ((.merge_status // "") == "can_be_merged")
          end
        ),
        # GitLab calls it web_url; two callers read .html_url for a link.
        html_url: (.web_url // "")
      };
    if type == "array" then [ .[] | one ] else one end'
}

forgejo_get_pr() {
  local repo="$1" number="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests/${number}" | _gl_mr_shim
}

# The tip commit of a branch. Shimmed to the Forgejo shape (.commit.id).
forgejo_get_branch() {
  local repo="$1" branch="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/repository/branches/$(_gl_path "$branch")" \
    | jq -c 'if type=="object" then . + {commit: {id: (.commit.id // "")}} else . end'
}

# Shimmed to the Forgejo shape: `.sha` and `.parents[].sha`. GitLab returns
# `.id` and a bare `parent_ids` array instead. The one caller (lib/automerge.sh,
# the walk that decides whether an approval still covers a head that moved only
# by merging the base in) reads `.parents | length` and `.parents[1:][].sha`;
# unshimmed, every commit read as having ZERO parents, so the walk always
# concluded "new content" and an approval never survived a base merge.
forgejo_get_commit() {
  local repo="$1" sha="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/repository/commits/${sha}" \
    | jq -c 'if type == "object" and has("id") then
               . + { sha: .id, parents: [ (.parent_ids // [])[] | {sha: .} ] }
             else . end'
}

# Compare two refs: commits <to> has that <from> doesn't. GitLab's compare
# takes from/to as query params rather than a "<from>...<to>" path segment,
# but the semantics (and therefore the caller's choice of order) match.
forgejo_compare() {
  local repo="$1" from="$2" to="$3"
  _gl GET "/projects/$(_gl_proj "$repo")/repository/compare?from=$(_gl_path "$from")&to=$(_gl_path "$to")"
}

# Issue-level comments on an MR (the "Conversation" tab).
#
# TRAP: GitLab's notes endpoint returns SYSTEM notes alongside human ones --
# "added label X", "assigned to Y", "marked as draft". Forgejo keeps those out
# of its comments list entirely. They are filtered here, because every caller
# treats this list as "things people said": the noop-loop guard counts bot
# comments matching a prefix, and the shadow reviewer's dedup scans for its own
# per-sha marker. A system note that happened to contain a matching substring
# would corrupt both. Shimmed to the Forgejo shape (.user.login).
forgejo_pr_comments() {
  local repo="$1" number="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests/${number}/notes?per_page=100&sort=asc&order_by=created_at" \
    | jq -c '[ .[] | select((.system // false) == false)
               | . + { user: { login: (.author.username // "") } } ]'
}

# Inline review comments (tied to a file path and line).
#
# On Forgejo these lived under each review; on GitLab they are the notes of a
# DIFF discussion -- a discussion whose notes carry a `.position`. Flattened to
# the same shape the callers read: path, original_line, body, user, created_at.
forgejo_pr_review_comments() {
  local repo="$1" number="$2" discussions
  discussions=$(_gl GET "/projects/$(_gl_proj "$repo")/merge_requests/${number}/discussions?per_page=100" 2>/dev/null) \
    || { printf '[]'; return; }
  jq -c '[ .[] | (.notes // [])[]
           | select(.position != null)
           | {
               path: (.position.new_path // .position.old_path // ""),
               original_line: (.position.new_line // .position.old_line // null),
               body: (.body // ""),
               user: { login: (.author.username // "") },
               created_at: (.created_at // "")
             } ]' <<<"$discussions" 2>/dev/null || printf '[]'
}

# -- The review contract --------------------------------------------------
#
# THIS IS THE ONE PLACE THE PORT IS AN ADAPTATION, NOT A TRANSLATION. Read
# this before changing anything below it.
#
# Forgejo has first-class pull-request reviews: a review is an object with a
# `state` of APPROVED / REQUEST_CHANGES / COMMENT, a `commit_id` it was made
# against, and `stale` / `dismissed` flags. The harness's whole review loop
# keys on that: lib/automerge.sh reads APPROVED as the human's go-ahead, and
# the rework pickup reads a live REQUEST_CHANGES as "the human rejected the
# current state, reopen the work".
#
# GitLab Free has NO equivalent. It has:
#   * approvals -- real, but unenforceable on Free (approval RULES are
#     Premium), and carrying no state beyond "user U approved".
#   * discussions -- threads of notes, each thread resolvable and resolved
#     or not.
#
# The mapping chosen, and why:
#
#   APPROVED        <- an entry in `approvals.approved_by[]`.
#   REQUEST_CHANGES <- an UNRESOLVED, RESOLVABLE discussion thread opened by a
#                      non-bot user. This is the closest honest analogue: it is
#                      a human saying something about this MR that they have
#                      not marked as settled. Resolving the thread is the
#                      GitLab-native way to say "addressed", which is exactly
#                      the signal `dismissed` carried on Forgejo.
#   COMMENT         <- a resolved thread, or an unresolvable one (a plain
#                      conversation note).
#
#   stale     <- for a DIFF thread, its `position.head_sha` differs from the
#                MR's current head. A review of code that has since been
#                rewritten should not block. Plain (non-diff) threads have no
#                sha to compare, so they are never stale -- a general objection
#                stays live until someone resolves it, which is the safer
#                default for a gate.
#   dismissed <- the thread is resolved.
#
# Consequence worth stating plainly: because approvals are unenforceable on
# Free, an APPROVED here is advisory. The thing that actually stops the bot
# merging is the protected branch (master allows push+merge at Maintainer, the
# bot is a Developer). Do not add logic that treats an approval as permission.

# All "reviews" on an MR, unfiltered. Synthesized per the block above.
forgejo_pr_reviews() {
  local repo="$1" number="$2" proj head approvals discussions
  proj=$(_gl_proj "$repo")
  head=$(_gl GET "/projects/${proj}/merge_requests/${number}" 2>/dev/null \
         | jq -r '.sha // ""' 2>/dev/null) || head=""
  approvals=$(_gl GET "/projects/${proj}/merge_requests/${number}/approvals" 2>/dev/null) || approvals=""
  discussions=$(_gl GET "/projects/${proj}/merge_requests/${number}/discussions?per_page=100" 2>/dev/null) || discussions=""
  # An empty body is as likely as a failed call (a 204, or an instance that
  # answers the approvals endpoint with nothing on Free). Both have to become
  # valid JSON before jq sees them -- `--argjson` on an empty string is a jq
  # PARSE ERROR, not an empty object, and would take the whole review contract
  # down to "no reviews" silently.
  jq -e . >/dev/null 2>&1 <<<"$approvals"   || approvals='{}'
  jq -e . >/dev/null 2>&1 <<<"$discussions" || discussions='[]'
  jq -c -n --argjson a "$approvals" --argjson d "$discussions" --arg head "$head" '
      [ ($a.approved_by // [])[]
        | { state: "APPROVED",
            user: { login: (.user.username // "") },
            commit_id: $head,
            submitted_at: ($a.updated_at // ""),
            stale: false, dismissed: false } ]
      +
      [ ($d // [])[]
        | . as $t
        | ($t.notes // []) as $notes
        | ($notes[0] // {}) as $first
        | select(($notes | length) > 0)
        # SYSTEM threads are not reviews. GitLab records every state change on
        # an MR -- "changed the description", "requested review from @x",
        # "added 1m of time spent", "assigned to @y" -- as its own discussion
        # thread, author = whoever acted. Left in, each one synthesizes a COMMENT
        # review, and because the actionable check reads the LATEST non-bot
        # review, a human retitling or reassigning the MR silently buried their
        # own earlier unresolved change request.
        | select(($first.system // false) == false)
        | ($first.resolvable // false) as $resolvable
        | ([ $notes[] | select((.resolvable // false) and (.resolved // false)) ] | length > 0) as $resolved
        | ($first.position.head_sha // "") as $tsha
        | { state: (if ($resolvable and ($resolved | not)) then "REQUEST_CHANGES" else "COMMENT" end),
            user: { login: ($first.author.username // "") },
            commit_id: (if $tsha != "" then $tsha else $head end),
            submitted_at: ($first.created_at // ""),
            stale: (if $tsha != "" and $head != "" and $tsha != $head then true else false end),
            dismissed: $resolved } ]
      | sort_by(.submitted_at)
    ' 2>/dev/null || printf '[]'
}

# All non-bot reviews on an MR, sorted oldest-to-newest. Filters the bot's own
# so they can't drown out real reviewer signal. jq's stderr is suppressed HERE
# rather than by the callers (igor#424): both want the parse noise gone on a
# malformed body, but blanketing the function also swallows _gl's give-up line.
forgejo_pr_non_bot_reviews() {
  local repo="$1" number="$2" bot="$3"
  forgejo_pr_reviews "$repo" "$number" \
    | jq -c --arg b "$bot" '[.[] | select(.user.login != $b)] | sort_by(.submitted_at)' 2>/dev/null
}

# The review pickup's Signal-1 check: does this MR's latest non-bot review
# amount to a live, unaddressed "request changes"? Returns that review's JSON
# if so, empty otherwise -- including on a fetch failure. Best-effort by
# construction (igor#425): every step degrades to empty rather than
# propagating a nonzero exit, so a caller scanning many MRs can't have one
# transient timeout abort the whole scan under `set -e -o pipefail`.
forgejo_pr_actionable_request_changes() {
  local repo="$1" number="$2" bot="$3" reviews latest state stale dismissed
  reviews=$(forgejo_pr_non_bot_reviews "$repo" "$number" "$bot") || reviews='[]'
  # Of the synthesized set, only REQUEST_CHANGES entries can be actionable, and
  # the Forgejo original looked at the LATEST review overall. Keep that: taking
  # the latest of all of them means a later APPROVED or a resolved thread
  # supersedes an earlier objection, which is the behaviour automerge expects.
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

# Request review from a user on an MR. GitLab takes numeric reviewer_ids on
# the MR PUT -- there is no separate requested_reviewers endpoint.
#
# Idempotent: re-setting the same reviewer is a no-op. Retries ONCE on a
# transient code, then on persistent failure emits the HTTP status + body on
# stderr and returns non-zero, so the caller logs WHY instead of a bare
# ambiguous warning. rc 0 iff the request actually landed (2xx).
#
# NOTE: unlike Forgejo, GitLab does NOT reject naming the MR's own author as a
# reviewer. The bot still must not review its own MRs -- that rule now lives
# in the caller rather than being enforced by the API, so do not remove the
# bot-vs-human checks elsewhere on the assumption the forge will catch it.
_gl_put_reviewers() {
  local url="$1" payload="$2"
  curl -s -w $'\n%{http_code}' --connect-timeout "$GITLAB_CONNECT_TIMEOUT" --max-time "$GITLAB_MAX_TIME" -X PUT \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" "$url"
}

forgejo_request_review() {
  local repo="$1" number="$2" reviewer="$3" uid
  uid=$(_gl_user_id "$reviewer")
  [ -n "$uid" ] || { printf 'cannot resolve reviewer [%s]' "$reviewer" >&2; return 1; }
  local url
  url="$GITLAB_URL/api/v4/projects/$(_gl_proj "$repo")/merge_requests/${number}"
  local payload resp code body attempt
  payload=$(jq -n --argjson r "$uid" '{reviewer_ids: [$r]}')
  for attempt in 1 2; do
    resp=$(_gl_put_reviewers "$url" "$payload")
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    case "$code" in
      2*)
        # igor#439: the operator runs with forge notifications off, so a landed
        # review request is the one event worth emailing about -- it is where
        # the loop stops and he becomes the blocker. Fired by name so this file
        # stays a pure API wrapper and the notifier is optional. Best-effort:
        # the request already landed.
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

# Open an MR and hand it to the human as a REVIEW request, not an assignment.
# An open bot MR is left UNASSIGNED on purpose: on an MR, unassigned means
# "the human's to review", assigned-to-the-bot means "the bot's to act on"
# (the forgejo_my_assigned_prs re-engagement signal). The 6th arg is the
# reviewer; review-request is a second call and is best-effort -- the MR is
# already open if it fails. Prints the new MR's iid on stdout (empty on create
# failure) so callers can capture it.
forgejo_open_pr() {
  local repo="$1" head="$2" base="$3" title="$4" body="$5" reviewer="${6:-}"
  local payload number
  payload=$(jq -n \
    --arg t "$title" --arg b "$body" \
    --arg h "$head"  --arg ba "$base" \
    '{title: $t, description: $b, source_branch: $h, target_branch: $ba}')
  number=$(_gl POST "/projects/$(_gl_proj "$repo")/merge_requests" "$payload" | jq -r '.iid // empty')
  [ -z "$number" ] && return 1
  if [ -n "$reviewer" ]; then
    forgejo_request_review "$repo" "$number" "$reviewer" 2>/dev/null \
      || printf 'forgejo_open_pr: review request for %s on %s#%s failed (MR is open)\n' \
           "$reviewer" "$repo" "$number" >&2
  fi
  printf '%s\n' "$number"
}

# Patch an MR's title and/or body. No-op payload if no flags given.
#
# NOTE: on Forgejo a PR IS an issue, so the issues PATCH endpoint edited both
# and forgejo_edit_pr pointed at /issues. On GitLab they are separate
# resources with separate iid spaces -- this MUST target merge_requests, and
# passing an issue iid here would edit a DIFFERENT object.
forgejo_edit_pr() {
  local repo="$1" number="$2"; shift 2
  local payload='{}'
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) payload=$(jq --arg v "$2" '.title = $v' <<<"$payload"); shift 2 ;;
      --body)  payload=$(jq --arg v "$2" '.description = $v' <<<"$payload"); shift 2 ;;
      *) shift ;;
    esac
  done
  _gl PUT "/projects/$(_gl_proj "$repo")/merge_requests/${number}" "$payload" >/dev/null
}

# POST the merge, echoing "<http_code>\t<message>".
#
# EXPECTED TO FAIL, BY DESIGN. The bot is a Developer and master is protected
# at Maintainer, so this returns 401/403 every time. That is the merge gate
# working, not an error: the human merges (see the review-contract block
# above). Kept for contract parity with lib/forgejo.sh, and because the
# automerge path still calls it to discover that it cannot merge.
#
# Do NOT add a retry, do NOT escalate, and do NOT alert on the 401 -- an
# earlier incident (igor#597) had automerge reporting a CI=failure 674 times
# without rework because a predictable negative was treated as a transient
# fault. Bypasses _gl deliberately: `curl -f` discards the response body on a
# non-2xx, but that body carries the REASON, which the caller wants to log.
# should_remove_source_branch is baked in: an API merge must opt in explicitly.
forgejo_merge_pr() {
  local repo="$1" pr="$2" out code body
  out=$(curl -s -w '\n%{http_code}' --max-time 30 -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
    -d '{"should_remove_source_branch":true}' \
    "${GITLAB_URL}/api/v4/projects/$(_gl_proj "$repo")/merge_requests/${pr}/merge" 2>/dev/null)
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  printf '%s\t%s' "$code" "$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null | head -1)"
}

# Merge the target branch into the MR head so a behind MR satisfies
# require-up-to-date. GitLab's equivalent of Forgejo's "update branch" is a
# rebase. rc 0 on success.
forgejo_pr_update_branch() {
  local repo="$1" pr="$2"
  _gl PUT "/projects/$(_gl_proj "$repo")/merge_requests/${pr}/rebase" >/dev/null 2>&1
}

# Upload one image and echo its public URL (empty on failure). GitLab's uploads
# endpoint is multipart, so it can't ride _gl (JSON-only), and it is
# PROJECT-scoped rather than attached to an issue -- the returned markdown is
# what ties it to a comment. Size-guarded: the reverse proxy caps the request
# body, so an oversized capture would 413 -- skip it (warn to stderr) rather
# than fail. The agent is told to keep screenshots small; this is the backstop.
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
  # .url is repo-relative ("/uploads/<hash>/<name>"); absolutize it so the
  # markdown the caller builds works from anywhere, matching what the Forgejo
  # browser_download_url gave.
  local rel
  rel=$(curl -sf --connect-timeout "$GITLAB_CONNECT_TIMEOUT" --max-time 60 -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -F "file=@${file};filename=${name}" \
    "$GITLAB_URL/api/v4/projects/$(_gl_proj "$repo")/uploads" \
    | jq -r '.url // empty') || return 1
  [ -n "$rel" ] || return 1
  printf '%s/%s%s\n' "${GITLAB_URL%/}" "$repo" "$rel"
}

# Attach every image in <dir> to an MR and append an embedded "## Screenshots"
# section to its body (once -- guarded by an HTML-comment marker). Echoes the
# count attached. No-op (echo 0) if the dir is absent/empty.
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
  body=$(_gl GET "/projects/$(_gl_proj "$repo")/merge_requests/${number}" | jq -r '.description // ""')
  case "$body" in *"<!-- screenshots -->"*) echo "$count"; return 0 ;; esac
  newbody="${body}"$'\n\n<!-- screenshots -->\n## Screenshots\n\n'"${md}"
  _gl PUT "/projects/$(_gl_proj "$repo")/merge_requests/${number}" \
    "$(jq -n --arg b "$newbody" '{description: $b}')" >/dev/null
  echo "$count"
}

# All open MRs assigned to the authenticated bot across every accessible
# project. The human->bot re-engagement signal: the human assigns an MR back
# to the bot, next tick finds it here and reopens the work.
forgejo_my_assigned_prs() {
  _gl GET "/merge_requests?scope=assigned_to_me&state=opened&per_page=50" | _gl_mr_shim
}

# All open issues currently assigned to the authenticated user across every
# accessible project. Used by the recovery sweep -- one call replaces N
# per-repo calls.
forgejo_my_assigned() {
  _gl GET "/issues?scope=assigned_to_me&state=opened&per_page=50" | _gl_issue_shim
}

# Open MRs authored by the given user, as JSON array of {number, title, head},
# OLDEST-FIRST. sort=asc keeps this consistent with the issue grind
# (forgejo_find_claimable, also oldest-first) so nothing starves at the back
# of a deep queue.
forgejo_list_open_bot_prs() {
  local repo="$1" user="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests?state=opened&order_by=created_at&sort=asc&per_page=50" \
    | jq --arg u "$user" \
        '[.[] | select(.author.username == $u)
          | {number: .iid, title, head: (.source_branch // "")}]'
}

forgejo_open_pulls_oldest() {
  local repo="$1" n="${2:-30}"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests?state=opened&order_by=created_at&sort=asc&per_page=${n}" | _gl_mr_shim
}

# Closed MRs, most-recently-updated first. Used to find recently merged MRs
# (the caller filters on .merged_at itself). "Closed" must include GitLab's
# `merged` state, which is separate from `closed` -- asking for state=closed
# alone would return only REJECTED MRs and the caller would see zero merges.
forgejo_closed_pulls_recent() {
  local repo="$1" n="${2:-30}"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests?state=all&order_by=updated_at&sort=desc&per_page=${n}" \
    | jq -c '[ .[] | select(.state == "merged" or .state == "closed") ]' | _gl_mr_shim
}

# Every closed MR (merged or rejected), oldest first, one JSON array. Walks
# every page rather than taking a single capped limit, for a corpus
# (bin/review-scorecard.sh) that can run past what one page holds.
#
# Same contract as forgejo_open_prs: nonzero with NO output when the listing
# couldn't be walked to the end, so a caller can't mistake a truncated read
# for "that's everything". Exit 1 for an unfetchable/unparseable page, 2 for
# hitting the page cap -- a report aggregating over this would otherwise show
# a repo dropping out of the totals as "network/token?" when the real answer
# is "this project is past the cap".
forgejo_closed_pulls_all() {
  local repo="$1" out
  out=$(_gl_paged "/projects/$(_gl_proj "$repo")/merge_requests?state=all&order_by=created_at&sort=asc")
  case "$?" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  jq -c '[ .[] | select(.state == "merged" or .state == "closed") ]' <<<"$out" | _gl_mr_shim
}

# Every open MR in <repo>, one JSON array. Nonzero with NO output when the
# listing couldn't be walked to the end -- callers gating a destructive step
# must read that as "unknown", not "none".
forgejo_open_prs() {
  local repo="$1" out
  out=$(_gl_paged "/projects/$(_gl_proj "$repo")/merge_requests?state=opened") || return 1
  printf '%s' "$out" | _gl_mr_shim
}

# Files changed in an MR with status and per-file additions/deletions, as
# JSON array of {filename, status, additions, deletions}. Used by the post
# cooldown and by the auto-merge risk gate to bound an unattended merge.
#
# Reads /diffs, not /changes (igor#15): /changes COLLAPSES some files --
# generated_file (lockfiles) plus anything over GitLab's size/collapse limits
# -- and returns them with an empty `diff`, which this function would then
# count as 0 lines. /diffs is paginated, hence _gl_paged.
#
# GitLab reports diffs as a list of hunks with new_file/deleted_file/
# renamed_file booleans and no line counts -- so status is reconstructed from
# the flags, and additions/deletions are COUNTED off the diff text. That
# counting is load-bearing: the risk gate sizes a merge by changed lines, and
# returning 0 would let an arbitrarily large MR through. Nonzero with NO
# output when the list can't be read OR GitLab withheld any entry's diff
# (too_large, or collapsed with no diff) -- a 0 for a withheld file is exactly
# the undercount this function exists to prevent, so the gate has to read
# "unknown" instead. A legitimately empty diff (a pure rename or mode change,
# neither too_large nor collapsed) stays a real 0.
#
# Both flags are really there: a live /diffs entry carries `too_large` and
# `collapsed` as populated booleans (checked on gitlab.com, 2026-10-16), so the
# `// false` defaults are belt, not the actual source of the value -- and a
# genuinely withheld file does set one. A 115KB package-lock.json added in a
# single commit reads `collapsed:true` with an empty `diff` and
# `too_large:false`, which is why the clause is `collapsed AND empty` rather
# than either flag alone.
forgejo_pr_files() {
  local repo="$1" number="$2" resp
  resp=$(_gl_paged "/projects/$(_gl_proj "$repo")/merge_requests/${number}/diffs") || return 1
  jq -ce '
      if type != "array" then error("not-an-array") else
      if any(.[]; (.too_large // false) or ((.collapsed // false) and ((.diff // "") == ""))) then
        error("diff withheld by GitLab")
      else
        [ .[]
          | (.diff // "") as $d
          | {
              filename: (.new_path // .old_path // ""),
              status: (if (.new_file // false) then "added"
                       elif (.deleted_file // false) then "removed"
                       elif (.renamed_file // false) then "renamed"
                       else "modified" end),
              additions: ([ $d | split("\n")[] | select(startswith("+") and (startswith("+++") | not)) ] | length),
              deletions: ([ $d | split("\n")[] | select(startswith("-") and (startswith("---") | not)) ] | length)
            } ]
      end end' <<<"$resp" 2>/dev/null || return 1
}

# Raw unified diff for an MR, as text (NOT JSON -- the caller feeds it
# straight to a model). GitLab has no `.diff` API route equivalent to
# Forgejo's, so it is reassembled from the per-file hunks the paginated
# /diffs endpoint returns (igor#15 -- not /changes, which collapses some
# files), with the `--- / +++` headers git would have emitted. An entry
# GitLab withheld (too_large, or collapsed with no diff) is reported as a
# marker line instead of silently vanishing, so the reviewer reading this
# text knows it is not seeing everything. Big diffs are otherwise the
# caller's problem to cap (the shadow reviewer head -c's it).
forgejo_pr_diff() {
  local repo="$1" number="$2" resp
  resp=$(_gl_paged "/projects/$(_gl_proj "$repo")/merge_requests/${number}/diffs") || return 1
  jq -r '
      .[]
      | if (.too_large // false) or ((.collapsed // false) and ((.diff // "") == ""))
        then "# diff withheld by GitLab (too large): \(.new_path // .old_path)"
        else
          "diff --git a/\(.old_path // .new_path) b/\(.new_path // .old_path)\n"
          + "--- a/\(.old_path // .new_path)\n"
          + "+++ b/\(.new_path // .old_path)\n"
          + (.diff // "")
        end' <<<"$resp" 2>/dev/null
}

# iid of the open MR with the given source branch, or empty if none. Used to
# make MR-open idempotent across harness crashes.
forgejo_find_pr_by_head() {
  local repo="$1" head="$2"
  _gl GET "/projects/$(_gl_proj "$repo")/merge_requests?state=opened&source_branch=$(_gl_path "$head")&per_page=50" \
    | jq -r 'first | .iid // empty'
}

# Count of comments on this MR by <user> whose body STARTS WITH <prefix>.
# Used by the noop-loop guard: a prior "no work produced" comment from the bot
# means we've already retried.
forgejo_count_bot_comments_matching() {
  local repo="$1" number="$2" user="$3" prefix="$4"
  forgejo_pr_comments "$repo" "$number" \
    | jq --arg u "$user" --arg p "$prefix" \
        '[.[] | select(.user.login == $u and ((.body // "") | startswith($p)))] | length'
}

# Count of comments by <user> whose body CONTAINS <needle>. The shadow
# reviewer's dedup net: its per-sha marker rides at the END of the comment, so
# startswith can't find it. Crash-safety belt -- the primary dedup is the
# local .review state sha; this catches a crash between posting and recording.
forgejo_pr_has_comment_containing() {
  local repo="$1" number="$2" user="$3" needle="$4"
  forgejo_pr_comments "$repo" "$number" \
    | jq --arg u "$user" --arg n "$needle" \
        '[.[] | select(.user.login == $u and ((.body // "") | contains($n)))] | length'
}

# -- Labels ---------------------------------------------------------------
#
# GitLab labels are strings on the issue, not ids, so there is no name->id
# resolution step. The CRITICAL difference: adding one must use `add_labels=`.
# A plain `labels=` write REPLACES the entire set, silently dropping every
# label it wasn't told about -- which on this harness would wipe Agent,
# Status/Blocked and the Kind/* taxonomy in one call.
forgejo_add_label() {
  local repo="$1" number="$2" name="$3"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" \
    "$(jq -n --arg n "$name" '{add_labels: $n}')" >/dev/null
}

forgejo_remove_label() {
  local repo="$1" number="$2" name="$3"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" \
    "$(jq -n --arg n "$name" '{remove_labels: $n}')" >/dev/null
}

# Does the project DEFINE a label of this name? Distinct exit codes so a
# caller can tell "absent" from "couldn't check":
#   0 -- present
#   1 -- absent (the list was read and holds no such name)
#   2 -- indeterminate (the API read itself failed: network/token)
forgejo_repo_has_label() {
  local repo="$1" name="$2" labels
  labels=$(_gl GET "/projects/$(_gl_proj "$repo")/labels?per_page=100") || return 2
  jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$labels" >/dev/null 2>&1
}

forgejo_list_labels() {
  local repo="$1"
  _gl GET "/projects/$(_gl_proj "$repo")/labels?per_page=100"
}

# Bot-authored MRs on this project that reference this issue via "Closes #N"
# (case-insensitive). Each entry: {number, state, title, merged}. Empty array
# if none.
#
# Used by discovery to gate claimable issues:
#   - any OPEN, non-WIP entry -> issue is in flight, skip
#   - an OPEN, WIP entry (turn-cap checkpoint draft) -> RESUME, don't skip
#   - 2+ state="closed", merged=false -> 2 rejected attempts, block instead
#     of re-trying
#
# state/merged are mapped back to the Forgejo pair the callers switch on:
# GitLab's `merged` state becomes state="closed" + merged=true, so the
# two-rejected-attempts count keeps meaning rejections and not merges.
forgejo_bot_prs_for_issue() {
  local repo="$1" issue_num="$2" user="$3"
  _gl_paged "/projects/$(_gl_proj "$repo")/merge_requests?state=all" \
    | jq -c --arg u "$user" --arg n "$issue_num" '
        [.[]
         | select(.author.username == $u)
         | select(.description != null and (.description | test("(?i)closes\\s+#" + $n + "\\b")))
         | {number: .iid,
            state: (if .state == "opened" then "open" else "closed" end),
            title: (.title // ""),
            merged: (.state == "merged")}]'
}

# Of the MRs in <open_prs_json> (forgejo_open_prs's shape), those already
# covering this issue, as [{number, title, head}]. Author-independent.
#
# Verbatim from lib/forgejo.sh -- it operates on already-shimmed JSON, so it
# is vendor-neutral. Two arms:
#   1. Head branch in the issue's own `agent/<n>`/`agent/<n>-*` namespace. The
#      load-bearing one: EVERY bot MR for an issue lives there, so it covers
#      the whole class with no false-positive surface (igor#496).
#   2. A STANDALONE closing line for <n>. Deliberately NARROWER than
#      pr_body_ensure_closes's "already satisfied" test: igor's own MR bodies
#      routinely discuss other tickets in prose, and a keyword-anywhere match
#      makes the discovery loop skip that unrelated issue on every tick,
#      silently and indefinitely (igor#497 review).
#
# jq's regex engine anchors ^/$ to the whole STRING, not each line, so the
# line boundaries are spelled out as (\A|\n) / (\n|\z).
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

forgejo_open_pr_covers_issue() {
  local prs
  prs=$(forgejo_open_prs "$1") || return 1
  forgejo_prs_covering_issue "$prs" "$2"
}

forgejo_prs_on_branches() {
  jq -r --arg b "$2" '
      ($b | split("\n")) as $branches
      | [.[] | select(.head as $h | any($branches[]; . == $h)) | "#\(.number) (\(.head))"]
      | join(", ")' <<<"$1"
}

# -- CI status ------------------------------------------------------------
#
# Combined CI status for a commit sha: one of success|pending|failure|error, or
# empty when the project reports nothing for the sha (no CI wired, or checks
# haven't started). Empty/unknown on API failure (NON-fatal: the caller treats
# it as "unknown").
#
# TWO SOURCES, deliberately, because this harness may read either:
#   1. the commit's `last_pipeline.status` -- a real GitLab pipeline, whether
#      run by a hosted or a self-hosted runner.
#   2. external commit statuses POSTed by something outside GitLab. Validation
#      may run on the NUC and report in that way rather than as a pipeline,
#      in which case there IS no pipeline and only this exists.
# A pipeline wins when present; otherwise the external statuses are folded.
#
# The fold mirrors the Forgejo v16 rescue (igor#414): if there is at least one
# status and EVERY status is terminal and non-failing (success/skipped only),
# the head is green. Without it a SKIPPED check knocks the combined state off
# success even though nothing failed or is still running, which would silently
# stop auto-merge fleet-wide. `manual` is treated as PENDING, not green: it is
# not terminal, it is waiting on a human, and calling it green would let an
# unattended merge past a gate someone deliberately put there.
_gl_map_ci_state() {
  case "${1:-}" in
    success|skipped)                                 printf 'success' ;;
    failed|canceled)                                 printf 'failure' ;;
    created|waiting_for_resource|preparing|pending|running|manual|scheduled)
                                                     printf 'pending' ;;
    '')                                              printf '' ;;
    *)                                               printf 'error' ;;
  esac
}

forgejo_commit_status() {
  local repo="$1" sha="$2" proj commit pipeline statuses state
  [ -n "$sha" ] || { printf ''; return; }
  proj=$(_gl_proj "$repo")
  commit=$(_gl GET "/projects/${proj}/repository/commits/${sha}" 2>/dev/null) || { printf ''; return; }
  pipeline=$(jq -r '.last_pipeline.status // ""' <<<"$commit" 2>/dev/null || printf '')
  if [ -n "$pipeline" ]; then
    _gl_map_ci_state "$pipeline"
    return
  fi
  statuses=$(_gl GET "/projects/${proj}/repository/commits/${sha}/statuses?per_page=100" 2>/dev/null) || { printf ''; return; }
  local n
  n=$(jq 'length' <<<"$statuses" 2>/dev/null || printf 0)
  case "$n" in '' | *[!0-9]*) printf ''; return ;; esac
  [ "$n" -eq 0 ] && { printf ''; return; }
  # Any failure anywhere loses; any still-running makes it pending; otherwise
  # all-terminal-non-failing is green.
  if jq -e 'any(.[]?; ((.status // "") | ascii_downcase) as $s
                      | $s == "failed" or $s == "canceled")' <<<"$statuses" >/dev/null 2>&1; then
    printf 'failure'; return
  fi
  if jq -e 'any(.[]?; ((.status // "") | ascii_downcase) as $s
                      | $s == "pending" or $s == "running" or $s == "created" or $s == "manual")' <<<"$statuses" >/dev/null 2>&1; then
    printf 'pending'; return
  fi
  if jq -e 'all(.[]?; ((.status // "") | ascii_downcase) as $s
                      | $s == "success" or $s == "skipped")' <<<"$statuses" >/dev/null 2>&1; then
    printf 'success'; return
  fi
  state=$(jq -r '.[0].status // ""' <<<"$statuses" 2>/dev/null || printf '')
  _gl_map_ci_state "$state"
}

# -- CI job logs ----------------------------------------------------------
# Feed *why* CI failed into the rework prompt. Given an MR head sha whose CI
# is RED, collect the failing pipeline's job-log tails so the rework agent can
# fix the build break, not only the review comments. Degrades to an empty
# string on any failure, so the caller can invoke it UNCONDITIONALLY -- it is
# also empty when CI is green (no failing job to report) and when there is no
# pipeline at all (validation running off-platform).
GITLAB_JOB_LOG_MAX_TIME=30    # a job log is heavier than a JSON call
FORGEJO_CI_LOG_TAIL_LINES=100 # per failing job: keep the last N lines
FORGEJO_CI_LOG_MAX_JOBS=3     # cap total jobs injected so the prompt stays bounded

# Plain-text trace for one job id, or empty on any failure. Own curl (not
# _gl): the endpoint returns text/plain and a trace can be large enough to
# want a longer timeout than _gl's fail-fast JSON budget.
forgejo_action_job_log() {
  local repo="$1" job_id="$2"
  [ -n "$job_id" ] || { printf ''; return; }
  curl -sf --connect-timeout "$GITLAB_CONNECT_TIMEOUT" --max-time "$GITLAB_JOB_LOG_MAX_TIME" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_URL/api/v4/projects/$(_gl_proj "$repo")/jobs/${job_id}/trace" 2>/dev/null || printf ''
}

forgejo_failing_ci_logs() {
  local repo="$1" sha="$2" proj pipes pid jobs jid jname jstat log tail_log block out="" n=0
  [ -n "$sha" ] || { printf ''; return; }
  proj=$(_gl_proj "$repo")
  pipes=$(_gl GET "/projects/${proj}/pipelines?sha=${sha}&per_page=20" 2>/dev/null) || { printf ''; return; }
  local pids
  pids=$(jq -r '(. // [])[]
                | select((.status // "") as $s | $s == "failed" or $s == "canceled")
                | .id' <<<"$pipes" 2>/dev/null) || { printf ''; return; }
  [ -n "$pids" ] || { printf ''; return; }
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$n" -ge "$FORGEJO_CI_LOG_MAX_JOBS" ] && break
    jobs=$(_gl GET "/projects/${proj}/pipelines/${pid}/jobs?per_page=50" 2>/dev/null) || continue
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
    done < <(jq -r '(. // [])[]
                    | select((.status // "") as $s | $s == "failed")
                    | [(.id | tostring), (.name // "job"), (.status // "")]
                    | @tsv' <<<"$jobs" 2>/dev/null)
  done <<<"$pids"
  [ -n "$out" ] || { printf ''; return; }
  printf '\n## CI is failing on this MR head -- fix the build too\n\nThe CI checks on this MR head are RED. Below are the tails of the failing job logs (the error is usually near the end). Diagnose and fix the CI failure as part of this rework, and make sure the project tests + lint pass before you exit.\n%s' "$out"
}

# -- Identity -------------------------------------------------------------

# The authenticated user's login (the bot's username). Empty on failure.
forgejo_whoami() {
  _gl GET "/user" | jq -r '.username // empty'
}

# Resolve the bot's login, retrying a transient /user failure with backoff
# (igor#383). Bot-identity resolution gates the ENTIRE tick, so a one-off API
# hiccup must not hard-abort the unit. Only a PERSISTENT failure (a sustained
# outage or a revoked token) returns empty, which the caller escalates to a
# visible exit. The assignment stays guarded because the curl|jq pipeline can
# surface curl's raw exit code under pipefail (igor#346).
forgejo_resolve_bot_user() {
  local attempt bot=""
  for attempt in 1 2 3; do
    bot=$(forgejo_whoami) || bot=""
    [ -n "$bot" ] && { printf '%s\n' "$bot"; return 0; }
    if [ "$attempt" -lt 3 ]; then sleep "$attempt"; fi
  done
  return 1
}

# Every project the bot can push to, as JSON array of {full_name,
# default_branch}.
#
# "Push access" on GitLab is an access LEVEL, not a boolean: Developer (30) is
# the first role that can push a branch. The level can arrive via either
# project membership or inherited group membership, and only one of the two is
# populated -- so both are checked and the higher taken. A project where the
# bot is only a Reporter (20) must NOT appear here: the grind would claim
# tickets it cannot open an MR for.
forgejo_list_bot_repos() {
  local all
  all=$(_gl_paged "/projects?membership=true&simple=false") || return 1
  jq '[ .[]
        | ((.permissions.project_access.access_level // 0) as $p
           | (.permissions.group_access.access_level // 0) as $g
           | (if $p > $g then $p else $g end)) as $lvl
        | select($lvl >= 30)
        | {full_name: .path_with_namespace, default_branch: (.default_branch // "master")} ]' <<<"$all"
}

# Returns 0 if the project exists and the bot can access it, 1 otherwise.
forgejo_repo_exists() {
  _gl GET "/projects/$(_gl_proj "$1")" >/dev/null 2>&1
}

# -- File reads (no clone) ------------------------------------------------
#
# Read a project's files/dirs over the API without cloning it (used for the
# per-repo agent.json config and logwatch's systemd/ discovery). All take
# <repo> = "<owner>/<name>".
#
# GitLab needs a `ref` on every file read -- there is no implicit default --
# and the file path is one URL-encoded segment, so a/b/c.json becomes
# a%2Fb%2Fc.json. Both are handled here; callers pass a plain path as before.
GITLAB_FILE_REF="${GITLAB_FILE_REF:-HEAD}"

# Prints raw file contents on stdout (base64-decoded). NON-ZERO when the API
# call fails (incl. 404) -- callers gate on the file existing first, so a
# failure here means the read itself broke, not that the file is absent.
forgejo_repo_get_file() {
  local repo="$1" path="$2" ref="${3:-$GITLAB_FILE_REF}"
  local resp
  resp=$(_gl GET "/projects/$(_gl_proj "$repo")/repository/files/$(_gl_path "$path")?ref=$(_gl_path "$ref")" 2>/dev/null) || return 1
  jq -r '.content // empty' <<<"$resp" | base64 -d 2>/dev/null || true
}

# Like forgejo_repo_get_file, but distinguishes WHY there's no content instead
# of collapsing every failure into the same nonzero. Echoes "<status>\t<content>"
# (content only set when status=found; rc is always 0 -- the status IS the
# answer):
#   found   -- the file exists; content (base64-decoded) follows
#   missing -- the API answered 404: the file is genuinely not there
#   error   -- anything else (403, 5xx, no response) -- the API could not
#              answer, so the caller must NOT read this as "absent"; treat it
#              as "unknown this tick"
#
# Own curl, not _gl: `-f` collapses EVERY HTTP >= 400 into exit 22, so a 403
# or a 502 is indistinguishable there from the 404 that means "no such file" --
# and that is the entire distinction this function exists to make (igor#520).
# No retry: an unanswered read already has a safe answer (`error`, on which
# the caller skips the repo and re-reads next tick), so there is nothing to
# buy by holding the tick open for 3 x GITLAB_MAX_TIME first.
forgejo_repo_get_file_status() {
  local repo="$1" path="$2" ref="${3:-$GITLAB_FILE_REF}" out code body
  out=$(curl -s -w '\n%{http_code}' --connect-timeout "$GITLAB_CONNECT_TIMEOUT" \
    --max-time "$GITLAB_MAX_TIME" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_URL/api/v4/projects/$(_gl_proj "$repo")/repository/files/$(_gl_path "$path")?ref=$(_gl_path "$ref")" 2>/dev/null) || true
  code=${out##*$'\n'}; body=${out%$'\n'*}
  case "$code" in
    2[0-9][0-9]) printf 'found\t%s' "$(jq -r '.content // empty' <<<"$body" 2>/dev/null | base64 -d 2>/dev/null || true)" ;;
    404)         printf 'missing\t' ;;
    *)           printf 'error\t' ;;
  esac
}

# Names of the entries in a project directory, one per line. Non-zero when the
# API call fails OR the directory doesn't exist -- callers treat both as
# "nothing to list".
forgejo_repo_list_dir() {
  local repo="$1" dir="$2" ref="${3:-$GITLAB_FILE_REF}" resp
  resp=$(_gl GET "/projects/$(_gl_proj "$repo")/repository/tree?path=$(_gl_path "$dir")&ref=$(_gl_path "$ref")&per_page=100" 2>/dev/null) || return 1
  jq -r '.[]?.name // empty' <<<"$resp" 2>/dev/null
}

# Returns 0 if the given dir contains at least one entry matching the regex.
forgejo_repo_dir_has_match() {
  local repo="$1" dir="$2" name_re="$3" ref="${4:-$GITLAB_FILE_REF}"
  local contents
  contents=$(_gl GET "/projects/$(_gl_proj "$repo")/repository/tree?path=$(_gl_path "$dir")&ref=$(_gl_path "$ref")&per_page=100" 2>/dev/null) || return 1
  jq -e --arg re "$name_re" 'any(.[]; .name | test($re))' <<<"$contents" >/dev/null 2>&1
}

# Subjects (first lines) of the N most recent commits on the default branch,
# one per line. Best-effort: empty on API failure -- this is a dedup signal,
# not a gate.
forgejo_recent_commit_subjects() {
  local repo="$1" n="${2:-20}" resp
  resp=$(_gl GET "/projects/$(_gl_proj "$repo")/repository/commits?per_page=${n}" 2>/dev/null) || return 0
  jq -r '.[]? | .message // empty | split("\n")[0]' <<<"$resp" 2>/dev/null || true
}

# The N most recent commits on the default branch, raw JSON. Shimmed so
# `.commit.message` resolves the way the Forgejo payload did -- GitLab returns
# the message at the top level.
forgejo_recent_commits_raw() {
  local repo="$1" n="${2:-30}"
  _gl GET "/projects/$(_gl_proj "$repo")/repository/commits?per_page=${n}" \
    | jq -c '[ .[] | . + {commit: {message: (.message // ""), author: {name: (.author_name // "")}}} ]'
}

# -- Issue lifecycle ------------------------------------------------------

# All open issue titles in a project (issues only -- GitLab keeps MRs in a
# separate resource, so unlike Forgejo there is no type= filter to pass), one
# per line. Used by the logwatch pass as a dedup signal.
forgejo_list_open_issue_titles() {
  local repo="$1"
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=opened&per_page=50" | jq -r '.[].title'
}

forgejo_list_open_issues() {
  local repo="$1"
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=opened&per_page=50" | _gl_issue_shim
}

# Open issues carrying the Status/Blocked label. Used by the deferred-gate and
# block-probe sweeps to find tickets they might requeue.
forgejo_list_blocked_issues() {
  local repo="$1"
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=opened&labels=Status%2FBlocked&per_page=50" | _gl_issue_shim
}

# Closed issues, most-recently-updated first. A dedup signal for "was this
# already worked?" checks.
forgejo_recent_closed_issues() {
  local repo="$1" n="${2:-40}"
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=closed&per_page=${n}&order_by=updated_at&sort=desc" | _gl_issue_shim
}

# Closed issues matching a search query. <query> must already be URL-encoded
# by the caller (e.g. via `jq -rn --arg s "$s" '$s|@uri'`), same contract as
# the Forgejo version.
forgejo_search_closed_issues() {
  local repo="$1" query="$2" n="${3:-15}"
  _gl GET "/projects/$(_gl_proj "$repo")/issues?state=closed&search=${query}&per_page=${n}" | _gl_issue_shim
}

# Open a new issue. Prints the new issue iid to stdout. Labels are applied
# separately via forgejo_add_label so a missing label degrades gracefully
# instead of failing the whole call.
forgejo_open_issue() {
  local repo="$1" title="$2" body="$3"
  _gl POST "/projects/$(_gl_proj "$repo")/issues" \
    "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, description: $b}')" \
    | jq -r '.iid'
}

# Open an issue with an assignee and (optionally) labels set at creation, in
# one POST. <label_ids_json> is a JSON array of numeric label IDs -- the same
# contract as lib/forgejo.sh, which is what the caller (lib/feedback.sh's
# feedback_resolve_labels) actually produces. An empty array omits labels.
#
# GitLab's issue-create takes label NAMES, not ids, so the ids are resolved
# against the project's label list first. Handing GitLab the raw array would
# post the literal string "[123, 456]", which it splits on the comma and CREATES
# as two junk labels named "[123" and "456]".
#
# An id that does not resolve is dropped rather than failing the whole call: the
# issue still opens, just without that label. So is a name carrying a comma --
# it cannot ride a comma-separated field, and sending it anyway would split it
# into fragments GitLab CREATES as labels, the same junk-label failure. Both
# drops, and a caller still on the pre-cutover name-string contract, leave a log
# line, since each one otherwise produces a silently (or wrongly) labelled issue.
forgejo_open_issue_assigned() {
  local repo="$1" title="$2" body="$3" assignee="$4" label_ids="${5:-[]}" payload uid all picked names=""
  uid=$(_gl_user_id "$assignee")
  if jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$label_ids"; then
    all=$(_gl_paged "/projects/$(_gl_proj "$repo")/labels" 2>/dev/null) || all='[]'
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$all" || all='[]'
    picked=$(jq -c --argjson want "$label_ids" \
      '[ .[] | select(.id as $i | $want | index($i)) | .name | select(index(",") | not) ]' \
      <<<"$all" 2>/dev/null) || picked='[]'
    names=$(jq -r 'join(",")' <<<"$picked")
    # Against the DEDUPED ids: a repeated id resolves to one name, so comparing
    # the raw length would report a drop that never happened.
    [ "$(jq 'length' <<<"$picked")" = "$(jq 'unique | length' <<<"$label_ids")" ] \
      || log "gitlab: ${repo} label ids ${label_ids} resolved to ${picked} -- unresolved or comma-bearing ids dropped"
  elif ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$label_ids"; then
    log "gitlab: open_issue_assigned wants a JSON array of label ids, got [${label_ids}] -- issue opens unlabelled"
  fi
  payload=$(jq -n --arg t "$title" --arg b "$body" --arg l "$names" --arg u "${uid:-}" '
    {title:$t, description:$b}
    + (if $u != "" then {assignee_ids: [($u | tonumber)]} else {} end)
    + (if $l != "" then {labels: $l} else {} end)')
  _gl POST "/projects/$(_gl_proj "$repo")/issues" "$payload" | _gl_issue_shim
}

forgejo_reopen_issue() {
  local repo="$1" number="$2"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" '{"state_event": "reopen"}' >/dev/null
}

forgejo_close_issue() {
  local repo="$1" number="$2"
  _gl PUT "/projects/$(_gl_proj "$repo")/issues/${number}" '{"state_event": "close"}' >/dev/null
}

# Find the most recent bot-authored issue whose body contains the given
# HTML-comment marker. Returns the issue JSON (open or closed) or empty if
# none. Used to dedupe auto-filed onboarding tickets across ticks.
#
# The _gl call is kept on its own line so a curl timeout (exit 28) returns
# exit 1 here rather than propagating the raw curl exit code through pipefail
# to the caller.
forgejo_find_marked_issue() {
  local repo="$1" bot="$2" marker="$3"
  local issues
  issues=$(_gl GET "/projects/$(_gl_proj "$repo")/issues?state=all&per_page=50" 2>/dev/null) || return 1
  jq -c --arg b "$bot" --arg m "$marker" '
      [.[] | select(.author.username == $b and ((.description // "") | contains($m)))]
      | sort_by(.created_at) | reverse | first // empty
    ' <<<"$issues" | _gl_issue_shim
}
