#!/usr/bin/env bash
# agent-block.sh -- Called by the agent from within a tick when it
# cannot complete the work.
#
# Posts the supplied reason as a comment on the current issue,
# applies the Status/Blocked label, and unassigns the bot. The
# `Agent` label is left in place so the issue stays in the agent's
# domain.
#
# Usage: agent-block.sh "<reason>"
#
# Requires in environment (exported by tick.sh):
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, TICK_HOME

set -euo pipefail

REASON="${1:?usage: agent-block.sh \"<reason>\"}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${TICK_HOME:?TICK_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$TICK_HOME/lib/forgejo.sh"

forgejo_comment    "$FORGEJO_REPO" "$ISSUE_NUMBER" "$REASON"
forgejo_add_label  "$FORGEJO_REPO" "$ISSUE_NUMBER" "Status/Blocked"
forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"

echo "agent-block: issue #${ISSUE_NUMBER} marked Status/Blocked" >&2
