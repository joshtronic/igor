#!/usr/bin/env bash
# split-ticket.sh -- pure string logic for the agent's self-split escape
# hatch on an oversized ticket (igor#608).
#
# lib/scope-gate.sh's finalize check is a backstop the agent can't see
# until the branch is already finished -- stonks#72 built 1,477 clean,
# tested lines only to have the whole worktree discarded at that point. The
# fix has two halves: bin/scope-budget.sh gives the agent a live read of
# the same numbers *during* the run, and bin/agent-split-ticket.sh lets it
# fork instead of dead-ending -- file a follow-up issue for the deferred
# scope, then land the part that fits. This file holds only the string
# logic both of those (and bin/tick.sh's finalize step) need, so it
# unit-tests without a worktree or network access (bin/test-split-ticket.sh),
# matching lib/checkpoint.sh's split.
#
# A split PR must never SILENTLY close the ticket whose remaining scope
# moved to a follow-up (the same rule the maintenance pass's slicing
# follows) -- split_ticket_finalize_body is what enforces that on the
# harness side, regardless of what the agent's own PR_BODY.md says.

# Relative to the worktree root, alongside .agent/PR_BODY.md -- written by
# bin/agent-split-ticket.sh, read by bin/tick.sh's finalize step.
# shellcheck disable=SC2034  # read by bin/agent-split-ticket.sh and bin/tick.sh, which source this
SPLIT_TICKET_MARKER_FILE=".agent/SPLIT_TICKET"

# split_ticket_read_followup <marker-file-content> -- the follow-up issue
# number recorded in the marker file, or "" if unparseable.
split_ticket_read_followup() {
  printf '%s' "$1" | grep -oE '[0-9]+' | head -1
}

# split_ticket_followup_body <original_issue> <deferred_scope> -- the body
# for the follow-up issue: the deferred scope as written by the agent, plus
# a back-reference so a reader lands on the ticket this was split from.
split_ticket_followup_body() {
  local orig="$1" deferred="$2"
  printf '%s\n\nSplit from #%s (scope-gate self-split -- the original ticket did not fit the runaway-diff guard in one PR).' "$deferred" "$orig"
}

# split_ticket_parent_comment <followup_issue> -- the comment posted on the
# original issue when it's split. The original issue is left OPEN and
# still assigned to the bot (so discovery does not reclaim it and redo the
# same work the follow-up now covers) -- a human can close it once the
# follow-up lands, or reopen the split if it disagrees.
split_ticket_parent_comment() {
  printf 'Split at the scope gate: this ticket does not fit in one PR under the runaway-diff guard. The remaining scope moved to #%s; a PR covering the part that fits is landing here. Left open (still assigned) rather than auto-closed -- close it once #%s covers everything, or reopen the split if that was the wrong call.' "$1" "$1"
}

# split_ticket_finalize_body <body> <original_issue> <followup_issue> --
# <body> made safe to land as a split PR:
#   - any auto-close keyword (close[s/d], fix[es/ed], resolve[s/d]) that
#     targets <original_issue> is neutralized to a plain "Part of
#     #<original_issue>" reference, so merging this PR can never silently
#     close a ticket whose remaining scope lives elsewhere -- regardless of
#     what the agent's own PR_BODY.md happened to write
#   - a "Part of #<original_issue>" reference is guaranteed present
#   - a note pointing at <followup_issue> is guaranteed present (skipped
#     when <followup_issue> is empty, or already referenced)
# Idempotent: re-running on already-finalized text changes nothing further.
split_ticket_finalize_body() {
  local body="$1" orig="$2" followup="$3"
  body=$(printf '%s' "$body" | sed -E \
    "s/(close[sd]?|fix(e[sd])?|resolve[sd]?)([[:space:]]+)#${orig}([^0-9]|\$)/Part of #${orig}\4/gI")
  if ! printf '%s' "$body" | grep -qiE "part of[[:space:]]+#${orig}([^0-9]|\$)"; then
    body=$(printf '%s\n\nPart of #%s' "$body" "$orig")
  fi
  if [ -n "$followup" ] && ! printf '%s' "$body" | grep -qE "#${followup}([^0-9]|\$)"; then
    body=$(printf '%s\n\nRemaining scope split to #%s.' "$body" "$followup")
  fi
  printf '%s' "$body"
}
