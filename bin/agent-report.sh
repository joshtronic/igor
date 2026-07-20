#!/usr/bin/env bash
# agent-report.sh -- Called by the agent from within a tick when the
# work product is a report (analysis, findings, recommendations) and
# no diff is expected.
#
# Posts the supplied content as a comment on the current issue, then
# closes the issue. Future delivery targets (Discord, email) layer
# onto this -- the Forgejo comment is always written so the audit
# trail is intact.
#
# Usage: agent-report.sh "<body>"
#
# Requires in environment (exported by tick.sh):
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, AGENT_HOME

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: agent-report.sh "<body>"

Posts <body> as a comment on the current issue (ISSUE_NUMBER) and closes it.
Run from within a tick; requires ISSUE_NUMBER, FORGEJO_REPO, AGENT_HOME.
USAGE
}

# --help/-h must short-circuit BEFORE any Forgejo contact -- otherwise the
# flag is taken as the report BODY and posted as a live comment (#398).
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

BODY="${1:?usage: agent-report.sh \"<body>\"}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${AGENT_HOME:?AGENT_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"

forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BODY"

# Close the issue. (No helper for this yet -- one-liner via _fj.)
_fj PATCH "/repos/${FORGEJO_REPO}/issues/${ISSUE_NUMBER}" \
  '{"state": "closed"}' >/dev/null

echo "agent-report: issue #${ISSUE_NUMBER} reported and closed" >&2
