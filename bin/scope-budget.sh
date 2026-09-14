#!/usr/bin/env bash
# scope-budget.sh -- live read of the finalize-time runaway-diff guard's
# non-test line count against whatever branch is checked out right now
# (igor#608).
#
# lib/scope-gate.sh's check only ever ran at finalize, after the work was
# done -- stonks#72 built 1,477 clean, tested lines only to have the whole
# worktree discarded at that point, and a human had to split the ticket by
# hand. Run this any time mid-session (after a checkpoint, after a commit,
# whenever the issue feels big) to see the SAME numbers before they become
# a dead end. If you're at or near the limit and the issue has more scope
# left, don't keep adding to this branch -- run agent-split-ticket.sh to
# defer the rest to a follow-up issue and land what fits.
#
# Usage: bash "$AGENT_HOME/bin/scope-budget.sh"
# (Invoke via `bash <path>` -- this script isn't on the bare-name
# allowlist, but Bash(bash:*) already is.)
#
# Requires in environment (exported by tick.sh): AGENT_HOME, PR_BASE
# Must be run from within the worktree (reads the current directory's git).

set -euo pipefail

: "${AGENT_HOME:?AGENT_HOME not set -- are you being run from a tick?}"
: "${PR_BASE:?PR_BASE not set -- are you being run from a tick?}"

# shellcheck source=../lib/scope-gate.sh
. "$AGENT_HOME/lib/scope-gate.sh"
# shellcheck source=../lib/dossier.sh
. "$AGENT_HOME/lib/dossier.sh"

GENERATED_GLOBS=$(scope_gate_base_generated_globs "origin/${PR_BASE}")
SUM=$(git diff --numstat "origin/${PR_BASE}..HEAD" -- . 2>/dev/null \
  | scope_gate_sum_numstat "$GENERATED_GLOBS")
CHANGED=$(cut -f1 <<<"$SUM")
CHANGED=${CHANGED:-0}

scope_gate_format_status "$CHANGED" "$SCOPE_GATE_MAX_LINES"
echo

if [ "$CHANGED" -gt "$SCOPE_GATE_MAX_LINES" ]; then
  echo "Over budget. Landing this as-is will be blocked at finalize. Run agent-split-ticket.sh to defer the rest and land what fits."
elif [ "$CHANGED" -gt "$(( SCOPE_GATE_MAX_LINES * 80 / 100 ))" ]; then
  echo "Getting close. If the issue has more scope than what's already on this branch, consider splitting now rather than after you've written it."
fi
