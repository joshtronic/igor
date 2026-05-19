#!/usr/bin/env bash
# agent-ask.sh -- File an asynchronous question issue on a repo.
#
# Use this for proactive design questions or thoughts that need
# the Doctor's input but aren't blocking my current work. Distinct
# from agent-block.sh, which blocks the CURRENT issue when I can't
# proceed.
#
# Usage: agent-ask.sh <owner/repo> "<title>" "<body>"
#
# Examples:
#   agent-ask.sh igor/brain "should i be reading more often?" "right now ~30% of ticks are reading. is that the right ratio? open to a different cadence."
#   agent-ask.sh igor/website "fold /now into about, or keep separate?" "the /now page is short. could be a section on about. but separation lets it update without touching the bio. preferences?"
#
# Throttle: one open bot-authored question per repo at a time. If
# the bot already has an open question on this repo (marker in
# body, no Agent label yet), this call refuses with exit 2 and a
# message telling Claude to comment on the existing thread or
# save the thought to journal/blog-ideas instead.
#
# Requires in environment (exported by tick.sh):
#   BOT_USER, FORGEJO_URL, FORGEJO_TOKEN, IGOR_HOME
# Optional:
#   IGOR_REVIEWER  -- if set, the issue is assigned to this user
#                     for Forgejo notification

set -euo pipefail

REPO="${1:?usage: agent-ask.sh <owner/repo> \"<title>\" \"<body>\"}"
TITLE="${2:?usage: agent-ask.sh <owner/repo> \"<title>\" \"<body>\"}"
BODY="${3:?usage: agent-ask.sh <owner/repo> \"<title>\" \"<body>\"}"

: "${IGOR_HOME:?IGOR_HOME not set -- are you being run from a tick?}"
: "${BOT_USER:?BOT_USER not set -- are you being run from a tick?}"

# shellcheck source=../lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"

QUESTION_MARKER='<!-- igor:question -->'

# Throttle: refuse if an open bot question exists on this repo.
# Marker + Agent-label absence distinguishes pending question from
# promoted-to-work issue.
EXISTING=$(_fj GET "/repos/${REPO}/issues?state=open&type=issues&limit=50" 2>/dev/null \
  | jq -c --arg u "$BOT_USER" --arg m "$QUESTION_MARKER" '
      [.[]
       | select(.user.login == $u)
       | select(.body != null and (.body | contains($m)))
       | select(([.labels[].name] | index("Agent")) == null)]
      | first // empty')

if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ] && [ "$EXISTING" != "empty" ]; then
  EXISTING_NUM=$(jq -r .number <<<"$EXISTING")
  EXISTING_TITLE=$(jq -r .title <<<"$EXISTING")
  echo "agent-ask: declined" >&2
  echo "  ${REPO}#${EXISTING_NUM} (\"${EXISTING_TITLE}\") is an open question awaiting human response." >&2
  echo "  Comment on the existing thread instead, or save the thought to journal/blog-ideas." >&2
  echo "  Only one pending question per repo at a time." >&2
  exit 2
fi

BODY_WITH_MARKER="${QUESTION_MARKER}

${BODY}"

NUMBER=$(forgejo_open_issue "$REPO" "$TITLE" "$BODY_WITH_MARKER")

# Apply Status/Needs More Info -- the Forgejo default for "bot is
# asking, human input needed." Same label maintenance findings use
# (also "bot wants human input"). The body marker distinguishes
# questions from maintenance findings when we need to tell them
# apart (e.g., the throttle above).
forgejo_add_label "$REPO" "$NUMBER" "Status/Needs More Info" 2>/dev/null \
  || echo "agent-ask: warning: Status/Needs More Info label not available on $REPO; issue filed without it" >&2

# Notify the reviewer if configured.
if [ -n "${IGOR_REVIEWER:-}" ]; then
  forgejo_assign "$REPO" "$NUMBER" "$IGOR_REVIEWER" 2>/dev/null \
    || echo "agent-ask: warning: could not assign to $IGOR_REVIEWER" >&2
fi

echo "agent-ask: filed ${REPO}#${NUMBER}" >&2
