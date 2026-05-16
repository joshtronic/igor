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
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, IGOR_HOME

set -euo pipefail

BODY="${1:?usage: agent-report.sh \"<body>\"}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${IGOR_HOME:?IGOR_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"

forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BODY"

# Close the issue. (No helper for this yet -- one-liner via _fj.)
_fj PATCH "/repos/${FORGEJO_REPO}/issues/${ISSUE_NUMBER}" \
  '{"state": "closed"}' >/dev/null

echo "agent-report: issue #${ISSUE_NUMBER} reported and closed" >&2
