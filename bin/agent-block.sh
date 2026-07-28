#!/usr/bin/env bash
# agent-block.sh -- Called by the agent from within a tick when it
# cannot complete the work.
#
# Appends the reason to the issue BODY (see igor#434: the issue-work
# prompt is built from ISSUE_BODY alone, so a reason posted only as a
# comment never reaches a re-queued run), posts it as a comment too,
# applies the Status/Blocked label, and unassigns the bot. The `Agent`
# label is left in place so the issue stays in the agent's domain.
#
# Usage: agent-block.sh "<reason>"
#
# Requires in environment (exported by tick.sh):
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, AGENT_HOME

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: agent-block.sh "<reason>"

Blocks the CURRENT issue (ISSUE_NUMBER): appends <reason> to the issue body,
comments it, applies Status/Blocked and unassigns the bot.
Run from within a tick; requires ISSUE_NUMBER, FORGEJO_REPO, AGENT_HOME.
USAGE
}

# --help/-h must short-circuit BEFORE any Forgejo contact -- otherwise the
# flag is taken as a positional argument and performs the real action
# (igor#398 fixed this on agent-report.sh; the same hole was left here).
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

REASON="${1:?usage: agent-block.sh \"<reason>\"}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${AGENT_HOME:?AGENT_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"

# Best-effort: a fetch/PATCH failure here must not stop the comment + label
# + unassign below -- those are what actually mark the issue blocked. Only
# claim the mechanism worked (via NOTE) when it actually did.
#
# Heading carries the time, not just the date: a ticket can block twice in a
# day (re-queued, blocked again), and two identical `## Blocked (2026-07-27)`
# headings read as a formatting bug rather than as two separate attempts.
NOTE=""
if forgejo_append_issue_body "$FORGEJO_REPO" "$ISSUE_NUMBER" "Blocked ($(date -u '+%Y-%m-%d %H:%MZ'))" "$REASON"; then
  NOTE=$'\n\n_(Appended to the issue description above -- removing `Status/Blocked` re-queues the ticket with this context already in hand.)_'
else
  echo "agent-block: warning: could not append findings to the issue body" >&2
fi

forgejo_comment    "$FORGEJO_REPO" "$ISSUE_NUMBER" "${REASON}${NOTE}"
forgejo_add_label  "$FORGEJO_REPO" "$ISSUE_NUMBER" "Status/Blocked"
forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"

# Notify the reviewer (typically the operator) by assigning the
# issue to them. Without this, the block lands silently and the
# operator has to spot the Status/Blocked label by checking.
# Assignment fires a Forgejo notification. Skipped if
# FORGEJO_REVIEWER isn't configured.
if [ -n "${FORGEJO_REVIEWER:-}" ]; then
  forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" "$FORGEJO_REVIEWER" \
    || echo "agent-block: warning: could not assign to $FORGEJO_REVIEWER" >&2
fi

echo "agent-block: issue #${ISSUE_NUMBER} marked Status/Blocked" >&2
