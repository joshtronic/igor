#!/usr/bin/env bash
# reviewnotify.sh -- email the operator the moment Igor puts a PR on his desk
# (igor#439).
#
# The operator has Forgejo's own notifications turned OFF: Forgejo mails on
# everything the bot does, and the volume made the useful mail unfindable. So
# the only signal he can trust is one Igor sends deliberately, at the one moment
# that actually means something -- when Igor requests his review. That request
# IS the event: it is where the loop decides it is finished and the human is now
# the blocker.
#
# Hooked at forgejo_request_review rather than at any one caller. There are ten
# call sites (terminal verdicts, an unvalidated repo, escalation after N rework
# rounds, a rework that produced no commits) and every one of them means the
# same thing. Hooking callers would mean remembering to hook the eleventh.
#
# DEDUP IS THE WHOLE POINT. forgejo_request_review is idempotent on purpose --
# re-requesting an already-requested reviewer is a harmless 201 -- so callers
# fire it freely, including repeatedly for the same PR. Mailing on every call
# would rebuild exactly the flood the operator turned Forgejo off to escape.
#
# The key is repo#number + HEAD SHA. Same PR, same head, already mailed -> quiet.
# Head moved and Igor is asking again -> that is code he has not seen, and it
# earns a second mail.
#
# State: discretionary-state.json under ".review_notified", shaped
# { "<repo>#<number>": "<head sha>" }. Regenerable -- losing it costs at most
# one duplicate email per open PR. Not pruned, for the same reason ".review"
# next to it is not: an entry is one short string, a merged PR is never
# re-requested, and years of them are still a rounding error in a file jq
# already rewrites every tick.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

_reviewnotify_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# reviewnotify_should_send <state_json> <repo> <number> <head_sha>
# 0 (true) when this request has not already been mailed for this head.
#
# Fails OPEN, unlike cascade's starvation check: an empty head sha (the PR
# fetch failed), missing state, or an unparseable state file all mean "send".
# A duplicate email is a minor annoyance; a swallowed one leaves the operator
# unaware that the loop is blocked on him, which is the entire failure this
# exists to prevent.
reviewnotify_should_send() {
  local state="${1:-}" repo="$2" number="$3" head="${4:-}"
  local seen
  [ -n "$head" ] || return 0
  [ -n "$state" ] || return 0
  jq -e . >/dev/null 2>&1 <<<"$state" || return 0
  seen=$(jq -r --arg k "${repo}#${number}" '.review_notified[$k] // ""' <<<"$state" 2>/dev/null || printf '')
  [ "$seen" != "$head" ]
}

# reviewnotify_subject <repo> <number> <title>
# Readable on a phone lock screen without opening it: which repo, which PR,
# what it is.
reviewnotify_subject() {
  printf '[Agent] Needs you: %s#%s -- %s' "${1:-}" "${2:-}" "${3:-untitled}"
}

# reviewnotify_body <repo> <number> <title> <verdict> <url>
# Why Igor handed it over, and where to go. The verdict (read from review state,
# recorded just before the request) is the reason in nearly every case; the
# fallback covers the paths that have no verdict of their own, such as a rework
# that produced no commits.
reviewnotify_body() {
  local repo="${1:-}" number="${2:-}" title="${3:-}" verdict="${4:-}" url="${5:-}"
  local why
  case "$verdict" in
    COMMENT)         why="Igor reviewed it as COMMENT, which auto-merge will not take -- so it is your call." ;;
    APPROVE)         why="Igor approved it, but this repo is pinned to your review before merge." ;;
    REQUEST_CHANGES) why="Igor requested changes and could not converge on its own -- escalated to you." ;;
    *)               why="Igor has handed this one to you." ;;
  esac
  printf 'Igor requested your review on %s#%s:\n\n  %s\n\n%s\n\n%s\n' \
    "$repo" "$number" "${title:-untitled}" "$why" "$url"
}

# review_notify_human <repo> <number>
# The hook forgejo_request_review fires after a request lands. Named as a plain
# function, not wired by argument, so lib/forgejo.sh stays a pure API wrapper --
# it fires this only if something defined it.
#
# Best-effort throughout: this is a notification about work that already
# happened, so nothing here may fail the request that triggered it. Returns 0
# always.
review_notify_human() {
  local repo="$1" number="$2"
  local state_file state pr head title url verdict subject body recipients tmp

  [ -n "${SMTP2GO_API_KEY:-}" ] && [ -n "${SMTP2GO_SENDER:-}" ] || return 0
  recipients=$(recipients_with_primary "")
  [ -n "$recipients" ] || return 0

  state_file=$(_reviewnotify_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  state=$(cat "$state_file" 2>/dev/null || printf '{}')

  # One fetch for all three fields. The live head is authoritative; the copy in
  # review state is only current on the paths that just wrote it.
  pr=$(forgejo_get_pr "$repo" "$number" 2>/dev/null || printf '')
  head=$(jq -r '.head.sha // ""' <<<"$pr" 2>/dev/null || printf '')
  title=$(jq -r '.title // ""' <<<"$pr" 2>/dev/null || printf '')
  url=$(jq -r '.html_url // ""' <<<"$pr" 2>/dev/null || printf '')

  reviewnotify_should_send "$state" "$repo" "$number" "$head" || return 0

  verdict=$(jq -r --arg k "${repo}#${number}" '.review[$k].verdict // ""' <<<"$state" 2>/dev/null || printf '')
  subject=$(reviewnotify_subject "$repo" "$number" "$title")
  body=$(reviewnotify_body "$repo" "$number" "$title" "$verdict" "$url")

  if ! email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients"; then
    log "warning: reviewnotify: email failed for ${repo}#${number} -- not recording, will retry on the next request"
    return 0
  fi
  log "reviewnotify: emailed ${recipients} about ${repo}#${number} (head ${head:0:8})"

  # Recorded only after a send actually lands, so a failed send retries rather
  # than marking the operator notified about mail he never got. Skipped when the
  # PR fetch gave no head -- there is nothing to key on, and writing an empty
  # value would suppress the next genuine notification.
  [ -n "$head" ] || return 0
  tmp=$(mktemp)
  if jq --arg k "${repo}#${number}" --arg s "$head" \
      '.review_notified //= {} | .review_notified[$k] = $s' "$state_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
    log "warning: reviewnotify: could not record ${repo}#${number} -- a duplicate email is possible"
  fi
  return 0
}
