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
# An optional PROBE recorded alongside the reason (igor#546) is what lets
# lib/blockprobe.sh's cadence sweep tell whether a block still holds instead
# of the label sitting as unchecked prose forever:
#   issue-open <owner/repo#N>  -- holds while that issue/PR is open
#   pr-behind  <owner/repo#N>  -- holds while that PR is behind its base
#   operator                   -- a human decision, not a mechanical
#                                  condition; never auto-requeued (no ref)
#   transient                  -- no external condition to check; presumed
#                                  resolved by the next look, so it always
#                                  clears (bounded by the repeat-block guard,
#                                  on reason text and episode count, no ref)
# Omit both to leave the block UNPROBED -- the sweep reports that honestly
# rather than guessing, but never clears it.
#
# Usage: agent-block.sh "<reason>" [<probe-kind> [<probe-ref>]]
#
# Requires in environment (exported by tick.sh):
#   ISSUE_NUMBER, FORGEJO_REPO, FORGEJO_URL, FORGEJO_TOKEN, AGENT_HOME

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: agent-block.sh "<reason>" [<probe-kind> [<probe-ref>]]

Blocks the CURRENT issue (ISSUE_NUMBER): appends <reason> to the issue body,
comments it, applies Status/Blocked and unassigns the bot.
Run from within a tick; requires ISSUE_NUMBER, FORGEJO_REPO, AGENT_HOME.

Optional probe-kind records a machine-checkable condition alongside the
reason, so a later sweep (lib/blockprobe.sh) can clear the block once the
cause resolves instead of it sitting blocked forever:
  issue-open <owner/repo#N>   block holds while that issue/PR is open
  pr-behind  <owner/repo#N>   block holds while that PR is behind its base
  operator                    a human decision -- never auto-requeued
  transient                   no condition to check -- always clears, bounded
                               by the repeat-block guard (reason + episodes)
Omit both probe args to leave the block UNPROBED (reported, never cleared).
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

REASON="${1:?usage: agent-block.sh \"<reason>\" [<probe-kind> [<probe-ref>]]}"
PROBE_KIND="${2:-}"
PROBE_REF="${3:-}"

: "${ISSUE_NUMBER:?ISSUE_NUMBER not set -- are you being run from a tick?}"
: "${FORGEJO_REPO:?FORGEJO_REPO not set}"
: "${AGENT_HOME:?AGENT_HOME not set}"

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/blockprobe.sh
. "$AGENT_HOME/lib/blockprobe.sh"

# Build the optional probe block. Best-effort validation only -- an
# unrecognized kind or a mechanical kind missing its ref just drops the
# probe (warn + fall through to UNPROBED) rather than aborting the block
# itself; the block must land either way.
PROBE_TEXT=""
if [ -n "$PROBE_KIND" ]; then
  case " $BLOCKPROBE_KINDS " in
    *" $PROBE_KIND "*)
      if [ "$PROBE_KIND" = "operator" ] || [ "$PROBE_KIND" = "transient" ]; then
        PROBE_TEXT=$'\n\n<!-- probe\nkind: '"${PROBE_KIND}"$'\n-->'
      elif [ -n "$PROBE_REF" ]; then
        PROBE_TEXT=$'\n\n<!-- probe\nkind: '"${PROBE_KIND}"$'\nref: '"${PROBE_REF}"$'\n-->'
      else
        echo "agent-block: warning: probe kind '${PROBE_KIND}' needs a ref -- recording no probe (will show as UNPROBED)" >&2
      fi
      ;;
    *)
      echo "agent-block: warning: unrecognized probe kind '${PROBE_KIND}' -- recording no probe (will show as UNPROBED)" >&2
      ;;
  esac
fi

# Best-effort: a fetch/PATCH failure here must not stop the comment + label
# + unassign below -- those are what actually mark the issue blocked. Only
# claim the mechanism worked (via NOTE) when it actually did.
#
# Heading carries the time, not just the date: a ticket can block twice in a
# day (re-queued, blocked again), and two identical `## Blocked (2026-07-27)`
# headings read as a formatting bug rather than as two separate attempts.
NOTE=""
if forgejo_append_issue_body "$FORGEJO_REPO" "$ISSUE_NUMBER" "Blocked ($(date -u '+%Y-%m-%d %H:%MZ'))" "${REASON}${PROBE_TEXT}"; then
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
