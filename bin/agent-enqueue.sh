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
# Two body forms:
#
#   Positional (short bodies, single-line preferred):
#     agent-enqueue.sh <owner/repo> "<title>" "<body>"
#
#   File-based (multi-line bodies):
#     agent-enqueue.sh <owner/repo> "<title>" --body-file <path>
#
#   The file form exists because Claude Code's static analysis
#   blocks command substitution like "$(cat body.md)" -- it can't
#   tell what the substituted text will be, so the permission hook
#   refuses to run it. A file path is a literal, statically-
#   analyzable argument.
#
# Example (short):
#   agent-enqueue.sh igor/website \
#     "fix: footer links wrap on narrow viewports" \
#     "On <600px the three footer links stack awkwardly..."
#
# Example (multi-line, recommended):
#   # write the body to a scratch file inside .igor/ first
#   agent-enqueue.sh igor/website \
#     "fix: footer links wrap on narrow viewports" \
#     --body-file .igor/footer-issue-body.md
#
# No throttle on filing -- issues are spec, they wait, no human
# review burden until claimed. (Distinct from PR-open throttle.)
# Dedup against existing open issues is NOT enforced here yet;
# pre-flight check on claim is the planned safety net.
#
# Requires in environment (exported by tick.sh):
#   BOT_USER, FORGEJO_URL, FORGEJO_TOKEN, IGOR_HOME

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
usage: agent-enqueue.sh <owner/repo> "<title>" "<body>"
       agent-enqueue.sh <owner/repo> "<title>" --body-file <path>
USAGE
  exit 1
}

REPO="${1:-}"
TITLE="${2:-}"
[ -z "$REPO" ] || [ -z "$TITLE" ] && usage

if [ "${3:-}" = "--body-file" ]; then
  BODY_FILE="${4:-}"
  [ -n "$BODY_FILE" ] || { echo "agent-enqueue: --body-file requires a path" >&2; usage; }
  [ -f "$BODY_FILE" ] || { echo "agent-enqueue: body file not found: $BODY_FILE" >&2; exit 1; }
  BODY=$(cat "$BODY_FILE")
else
  BODY="${3:-}"
  [ -n "$BODY" ] || usage
fi

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

# Drop a marker in .igor/ so the harness post-tick can find the
# filed-issue number and log time on it (Igor's examination time
# belongs on the issue he created, same as issue-work time belongs
# on the issue he resolved). Marker is best-effort; if .igor/
# doesn't exist (called from outside a tick), skip silently.
if [ -d .igor ]; then
  printf '%s#%s\n' "$REPO" "$NUMBER" > .igor/IGOR_FILED_ISSUE
fi

echo "agent-enqueue: filed ${REPO}#${NUMBER}" >&2
