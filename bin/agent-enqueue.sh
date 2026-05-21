#!/usr/bin/env bash
# agent-enqueue.sh -- File an Agent-labeled work issue on a repo.
#
# Use this to queue up site work I noticed during a discretionary
# tick. The harness's normal issue-work flow picks it up on a
# future tick, just like a human-filed Agent issue. Lets the issue
# queue be the canonical source of "what needs doing" -- self-
# directed site work goes through the same pipeline as
# ticket-driven work.
#
# Usage: agent-enqueue.sh <owner/repo> "<title>" "<body>"
#
# Example:
#   agent-enqueue.sh igor/website \
#     "fix: footer links wrap on narrow viewports" \
#     "On <600px the three footer links stack awkwardly..."
#
# No throttle on filing -- issues are spec, they wait, no human
# review burden until claimed. (Distinct from PR-open throttle.)
# Dedup against existing open issues is NOT enforced here yet;
# pre-flight check on claim is the planned safety net.
#
# Requires in environment (exported by tick.sh):
#   BOT_USER, FORGEJO_URL, FORGEJO_TOKEN, IGOR_HOME

set -euo pipefail

REPO="${1:?usage: agent-enqueue.sh <owner/repo> \"<title>\" \"<body>\"}"
TITLE="${2:?usage: agent-enqueue.sh <owner/repo> \"<title>\" \"<body>\"}"
BODY="${3:?usage: agent-enqueue.sh <owner/repo> \"<title>\" \"<body>\"}"

: "${IGOR_HOME:?IGOR_HOME not set -- are you being run from a tick?}"
: "${BOT_USER:?BOT_USER not set -- are you being run from a tick?}"

# shellcheck source=../lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"

ENQUEUE_MARKER='<!-- igor:enqueue -->'

BODY_WITH_MARKER="${ENQUEUE_MARKER}

${BODY}"

NUMBER=$(forgejo_open_issue "$REPO" "$TITLE" "$BODY_WITH_MARKER")

# Apply Agent label so the harness's discovery sweep picks this up
# on a future tick. Mirrors the human-filed pattern: Agent = ready
# for the bot to claim.
forgejo_add_label "$REPO" "$NUMBER" "Agent" 2>/dev/null \
  || echo "agent-enqueue: warning: Agent label not available on $REPO; issue filed without it" >&2

echo "agent-enqueue: filed ${REPO}#${NUMBER}" >&2
