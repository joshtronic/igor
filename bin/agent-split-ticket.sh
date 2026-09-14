#!/usr/bin/env bash
# agent-split-ticket.sh -- File a follow-up issue for scope that won't fit
# under the finalize-time runaway-diff guard (lib/scope-gate.sh), so an
# oversized ticket can fork instead of dead-ending (igor#608).
#
# Call this once bin/scope-budget.sh (or your own read of the diff) says
# the full issue will not fit this branch's budget. Then finish only the
# part that fits and describe it in .agent/PR_BODY.md as usual -- reference
# "Part of #<original-issue>" rather than "Closes #<original-issue>". The
# harness enforces that regardless (lib/split-ticket.sh neutralizes an
# auto-close keyword on a split PR before it's pushed), but writing it
# yourself keeps the PR honest for a human reader.
#
# Usage: bash "$AGENT_HOME/bin/agent-split-ticket.sh" "<follow-up title>" "<follow-up body>"
# (Invoke via `bash <path>` -- this script isn't on the bare-name
# allowlist, but Bash(bash:*) already is.)
#
# Files <FORGEJO_REPO>#<new>, Agent-labeled and unassigned so the normal
# claimable grind can pick it up next tick -- the same "the label is the
# greenlight" precedent the maintenance pass's auto-filed tickets use.
# Comments on the CURRENT issue (ISSUE_NUMBER) linking the follow-up, and
# writes .agent/SPLIT_TICKET in the current directory so bin/tick.sh's
# finalize step can find it and land the part that fits without
# auto-closing the original.
#
# One split per issue per run: a second call refuses (exit 2) and points
# at the already-filed follow-up, rather than filing a duplicate every time
# the agent re-checks its budget.
#
# Requires in environment (exported by tick.sh):
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, AGENT_HOME

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: agent-split-ticket.sh "<follow-up title>" "<follow-up body>"

Files a follow-up issue on the current repo for scope that won't fit this
ticket's remaining budget, links it back to the current issue, and marks
the worktree so the harness lands the part that fits without auto-closing
the original. Run from within a tick; requires ISSUE_NUMBER, FORGEJO_REPO,
AGENT_HOME.
USAGE
}

# --help/-h must short-circuit BEFORE any Forgejo contact -- see
# agent-block.sh/agent-ask.sh for the same guard and why it exists.
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

TITLE="${1:?usage: agent-split-ticket.sh \"<title>\" \"<body>\"}"
BODY="${2:?usage: agent-split-ticket.sh \"<title>\" \"<body>\"}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${AGENT_HOME:?AGENT_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/split-ticket.sh
. "$AGENT_HOME/lib/split-ticket.sh"

if [ -f "$SPLIT_TICKET_MARKER_FILE" ]; then
  EXISTING=$(split_ticket_read_followup "$(cat "$SPLIT_TICKET_MARKER_FILE")")
  echo "agent-split-ticket: declined" >&2
  echo "  This issue was already split to ${FORGEJO_REPO}#${EXISTING} this run." >&2
  echo "  Land what fits and reference that issue -- don't split twice." >&2
  exit 2
fi

FOLLOWUP_BODY=$(split_ticket_followup_body "$ISSUE_NUMBER" "$BODY")
NUMBER=$(forgejo_open_issue "$FORGEJO_REPO" "$TITLE" "$FOLLOWUP_BODY")

forgejo_add_label "$FORGEJO_REPO" "$NUMBER" "Agent" 2>/dev/null \
  || echo "agent-split-ticket: warning: Agent label not available on $FORGEJO_REPO; follow-up filed unlabeled" >&2

forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
  "$(split_ticket_parent_comment "$NUMBER")" 2>/dev/null \
  || echo "agent-split-ticket: warning: could not comment on ${FORGEJO_REPO}#${ISSUE_NUMBER}" >&2

mkdir -p "$(dirname "$SPLIT_TICKET_MARKER_FILE")"
printf '%s\n' "$NUMBER" > "$SPLIT_TICKET_MARKER_FILE"

echo "agent-split-ticket: filed ${FORGEJO_REPO}#${NUMBER}, linked from #${ISSUE_NUMBER}" >&2
echo "$NUMBER"
