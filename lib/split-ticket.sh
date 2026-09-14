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

# The same record carried on the checkpoint PR's body, mirroring
# lib/checkpoint.sh's <!-- agent-checkpoints=N --> counter. The marker FILE is
# per-worktree scratch (init_igor_scratch gitignores .agent/, and a
# checkpoint -> resume carves a fresh worktree from the branch), so a run that
# splits and then hits the turn cap would lose it: the resumed run would file a
# SECOND follow-up and let pr_body_finalize_closing write "Closes #<orig>" back
# onto the PR, closing the very ticket whose remaining scope moved elsewhere.
# The PR body survives both, and is visible to a human.
SPLIT_TICKET_BODY_TAG='agent-split'

# split_ticket_body_read <pr_body> -- the follow-up issue number recorded in
# <pr_body>'s split marker, or "" when there is none.
split_ticket_body_read() {
  local n
  n=$(printf '%s' "$1" | grep -oE "${SPLIT_TICKET_BODY_TAG}=[0-9]+" | tail -1 \
    | grep -oE '[0-9]+') || n=""
  printf '%s' "$n"
}

# split_ticket_body_set <pr_body> <followup> -- <pr_body> carrying exactly one
# split marker for <followup>: any existing marker LINE is dropped and a fresh
# one appended. Line-oriented rather than a sed substitution so an arbitrary
# '/', '&', or '|' in the body can't corrupt it (checkpoint_set_count's reason).
# An empty <followup> returns the body unchanged -- nothing to record.
split_ticket_body_set() {
  local body="$1" followup="$2" stripped
  [ -n "$followup" ] || { printf '%s' "$body"; return; }
  stripped=$(printf '%s\n' "$body" \
    | grep -vE "^[[:space:]]*<!-- ${SPLIT_TICKET_BODY_TAG}=[0-9]+ -->[[:space:]]*$") || true
  printf '%s\n\n<!-- %s=%s -->\n' "$stripped" "$SPLIT_TICKET_BODY_TAG" "$followup"
}

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
#     what the agent's own PR_BODY.md happened to write. The separator
#     mirrors what Forgejo/Gitea's own close-keyword matcher accepts: an
#     OPTIONAL colon before the whitespace, so "Closes: #608" is caught too
#     (it auto-closes on merge exactly like the bare form). The keyword's
#     left edge is anchored on a non-alphanumeric so an embedded match
#     ("precloses #608") is left alone rather than rewritten mid-word.
#   - a "Part of #<original_issue>" reference is guaranteed present
#   - a note pointing at <followup_issue> is guaranteed present (skipped
#     when <followup_issue> is empty, or already referenced)
# Idempotent: re-running on already-finalized text changes nothing further.
split_ticket_finalize_body() {
  local body="$1" orig="$2" followup="$3"
  body=$(printf '%s' "$body" | sed -E \
    "s/(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):?([[:space:]]+)#${orig}([^0-9]|\$)/\1Part of #${orig}\5/gI")
  if ! printf '%s' "$body" | grep -qiE "part of[[:space:]]+#${orig}([^0-9]|\$)"; then
    body=$(printf '%s\n\nPart of #%s' "$body" "$orig")
  fi
  if [ -n "$followup" ] && ! printf '%s' "$body" | grep -qE "#${followup}([^0-9]|\$)"; then
    body=$(printf '%s\n\nRemaining scope split to #%s.' "$body" "$followup")
  fi
  printf '%s' "$body"
}
