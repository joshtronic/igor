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
# That buys nothing across a PROCESS boundary, though. lib/forgejo.sh fires the
# hook only if something defined it, so an entry point that reaches a review
# request without sourcing this file sends nothing -- the same "forgot to hook
# the caller" failure, moved one level down. Three entry points can reach one:
# bin/tick.sh, bin/site-work-block.sh and bin/ideation-pipeline.sh (the latter
# two via forgejo_open_pr). bin/check-sync.sh asserts that set rather than
# trusting this comment to stay true.
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
# { "<repo>#<number>": "<head sha>" } (or an hour bucket when the head could
# not be read -- see reviewnotify_dedup_head). Regenerable -- losing it costs at
# most one duplicate email per open PR. Not pruned, for the same reason ".review"
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

# reviewnotify_dedup_head <head>
# What the dedup actually keys on: the real head sha when the PR fetch worked,
# an hour bucket when it did not.
#
# Failing open on a bad fetch is right, but the first cut failed open
# UNBOUNDED: it sent and recorded nothing, so ~10 call sites against a
# persistently broken fetch (a narrowed token, a moved endpoint) is an email
# per call per tick -- the flood the dedup exists to prevent, arriving through
# the escape hatch. The bucket degrades that to at most one an hour, and costs
# nothing once the fetch recovers, because a real sha is a key nothing has seen.
reviewnotify_dedup_head() {
  local head="${1:-}"
  if [ -n "$head" ]; then
    printf '%s' "$head"
  else
    printf 'nohead-%s' "$(( $(date +%s) / 3600 ))"
  fi
}

# reviewnotify_escape_html <text>
# The PR title comes back from the Forgejo API, so it is the one string on this
# path Igor did not write. Low stakes in a mail client, but escaping the three
# characters that can open a tag costs nothing.
reviewnotify_escape_html() {
  printf '%s' "${1:-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
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
  local why where
  case "$verdict" in
    COMMENT)         why="Igor reviewed it as COMMENT, which auto-merge will not take -- so it is your call." ;;
    APPROVE)         why="Igor approved it, but this repo is pinned to your review before merge." ;;
    REQUEST_CHANGES) why="Igor requested changes and could not converge on its own -- escalated to you." ;;
    *)               why="Igor has handed this one to you." ;;
  esac
  # A failed PR fetch still mails -- the operator is still the blocker either
  # way -- but with no title AND no link it arrives as an alert he cannot act
  # on. Say that the details are missing and where to go instead, rather than
  # trailing off into a blank line he has to interpret.
  if [ -z "$title" ] && [ -z "$url" ]; then
    where="(Forgejo did not return the PR's details -- open $repo and look for #$number.)"
  else
    where="$url"
  fi
  printf 'Igor requested your review on %s#%s:\n\n  %s\n\n%s\n\n%s\n' \
    "$repo" "$number" "${title:-untitled}" "$why" "$where"
}

# review_notify_human <repo> <number> [reviewer]
# The hook forgejo_request_review fires after a request lands. Named as a plain
# function, not wired by argument, so lib/forgejo.sh stays a pure API wrapper --
# it fires this only if something defined it.
#
# Best-effort throughout: this is a notification about work that already
# happened, so nothing here may fail the request that triggered it. Returns 0
# always.
review_notify_human() {
  local repo="$1" number="$2" reviewer="${3:-}"
  local state_file state pr head key title url verdict subject body recipients tmp

  [ -n "${SMTP2GO_API_KEY:-}" ] && [ -n "${SMTP2GO_SENDER:-}" ] || return 0

  # This mail says "you are the blocker", so it belongs only to a request FOR
  # the operator. Every call site passes FORGEJO_REVIEWER today; the check is
  # for the day one doesn't. Fails open when either side is unset -- that is a
  # misconfigured tick, not evidence of a third-party reviewer.
  if [ -n "$reviewer" ] && [ -n "${FORGEJO_REVIEWER:-}" ] && [ "$reviewer" != "$FORGEJO_REVIEWER" ]; then
    return 0
  fi

  recipients=$(recipients_with_primary "")
  [ -n "$recipients" ] || return 0

  state_file=$(_reviewnotify_state_file)
  # A fresh host has no state dir yet. Without this the create below fails,
  # every write after it fails, and dedup is off for good behind one warning.
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  [ -f "$state_file" ] || echo '{}' > "$state_file" 2>/dev/null || true
  state=$(cat "$state_file" 2>/dev/null || printf '{}')

  # One fetch for all three fields. The live head is authoritative; the copy in
  # review state is only current on the paths that just wrote it.
  pr=$(forgejo_get_pr "$repo" "$number" 2>/dev/null || printf '')
  head=$(jq -r '.head.sha // ""' <<<"$pr" 2>/dev/null || printf '')
  title=$(jq -r '.title // ""' <<<"$pr" 2>/dev/null || printf '')
  url=$(jq -r '.html_url // ""' <<<"$pr" 2>/dev/null || printf '')

  key=$(reviewnotify_dedup_head "$head")
  reviewnotify_should_send "$state" "$repo" "$number" "$key" || return 0

  verdict=$(jq -r --arg k "${repo}#${number}" '.review[$k].verdict // ""' <<<"$state" 2>/dev/null || printf '')
  subject=$(reviewnotify_subject "$repo" "$number" "$title")
  body=$(reviewnotify_body "$repo" "$number" "$title" "$verdict" "$url")

  if ! email_send "$subject" "<pre>$(reviewnotify_escape_html "$body")</pre>" "$body" "$recipients"; then
    log "warning: reviewnotify: email failed for ${repo}#${number} -- not recording, will retry on the next request"
    return 0
  fi
  # The KEY, not the head: on a failed fetch the head is empty and the line
  # read "(head )", which says nothing about why the mail went out anyway.
  log "reviewnotify: emailed ${recipients} about ${repo}#${number} (key ${key:0:13})"

  # Recorded only after a send actually lands, so a failed send retries rather
  # than marking the operator notified about mail he never got. The temp file is
  # made NEXT TO the state file, not in mktemp's default /tmp: the mv is only an
  # atomic rename within one filesystem, and a state dir on another mount would
  # silently turn it into copy-then-unlink.
  #
  # Read-modify-write AT WRITE TIME, like every other writer of this file
  # (tick.sh's slot/weekly/seo/sports/review/cascade helpers, needsyou, ceo,
  # feedback, automerge, deferred, logwatch, claude): each re-reads the file
  # inside the jq that produces its replacement. Not one snapshots it in memory
  # early and rewrites it wholesale later, so a mid-tick record here cannot be
  # clobbered by a later write -- keep it that way. mktemp's 0600 does land on
  # the state file, but that is the harness-wide status quo, not something this
  # write introduces: every mktemp+mv writer above does the same.
  tmp=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || {
    log "warning: reviewnotify: could not stage a state write for ${repo}#${number} -- a duplicate email is possible"
    return 0
  }
  if jq --arg k "${repo}#${number}" --arg s "$key" \
      '.review_notified //= {} | .review_notified[$k] = $s' "$state_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
    log "warning: reviewnotify: could not record ${repo}#${number} -- a duplicate email is possible"
  fi
  return 0
}
