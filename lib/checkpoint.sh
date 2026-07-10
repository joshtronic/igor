#!/usr/bin/env bash
# checkpoint.sh -- turn-cap checkpoint-and-resume for tier-1 issue ticks.
#
# The problem: `claude --max-turns 100` bounds a tick's runtime so no single
# issue can run for hours and starve the loop (a runaway task blocking every
# other repo). But when a genuinely large task hits that cap, the ship-safety
# gate (bin/tick.sh) discarded the ENTIRE worktree on the nonzero exit -- throwing
# away real, commit-worthy work and re-running it from zero next tick, only to
# hit the cap again (igor#351, #329, #334). The cap was meant to bound runtime,
# not to forbid work from ever completing.
#
# This module lets a max-turns cut-off CHECKPOINT instead of discard: commit the
# work-in-progress to the branch, publish it as a draft ("WIP:") PR the review
# and merge loops ignore, keep the issue claimable, and RESUME from that branch
# on the next claim. Natural completion (exit 0) finalizes: drop the "WIP:"
# prefix, marking the PR ready -> shadow review picks it up. A real crash still
# discards, unchanged. A resume budget caps how many times one issue may
# checkpoint before it's escalated to a human -- so a too-big task can't
# monopolize the loop forever (the loop-and-starve failure mode).
#
# Everything here is pure string logic (no network, no git) so it unit-tests
# cleanly; bin/tick.sh owns the git/forgejo side effects and calls these to
# decide. Tests: bin/test-checkpoint.sh.

# A checkpoint PR is a draft the review/merge loops must skip and the claim loop
# must resume. Two markers carry that state on the PR itself -- no extra state
# file, so it survives a state reset and is visible to a human on the PR:
#   - a "WIP: " title prefix (also recognized by Forgejo/Gitea as a draft, which
#     blocks its merge button as a bonus), and
#   - a checkpoint counter in the body: <!-- agent-checkpoints=N -->
CHECKPOINT_WIP_PREFIX='WIP: '
CHECKPOINT_COUNT_TAG='agent-checkpoints'
# After this many checkpoints without finishing, stop resuming and escalate: the
# task is too big for the loop and needs a human to split it. Guards the loop
# against an issue that never converges. A strong default, not a knob to tune.
CHECKPOINT_MAX=8

# checkpoint_terminal_reason <stream_jsonl> -- the terminal_reason of claude's
# last result event ("max_turns" when the turn cap was hit), else "". The result
# event is the single line carrying .terminal_reason; take the last if several.
checkpoint_terminal_reason() {
  local stream="$1"
  [ -f "$stream" ] || { printf ''; return; }
  grep -E '"type":"result"' "$stream" 2>/dev/null | tail -1 \
    | jq -r '.terminal_reason // ""' 2>/dev/null || printf ''
}

# checkpoint_hit_turn_cap <stream_jsonl> -- rc 0 iff claude's last result event
# says the run stopped by hitting the turn cap. Accepts either independent signal
# (terminal_reason or subtype) so a field rename upstream doesn't silently turn
# every checkpoint back into a discard.
checkpoint_hit_turn_cap() {
  local stream="$1" ev
  [ -f "$stream" ] || return 1
  ev=$(grep -E '"type":"result"' "$stream" 2>/dev/null | tail -1) || return 1
  [ -n "$ev" ] || return 1
  printf '%s' "$ev" \
    | jq -e '(.terminal_reason == "max_turns") or (.subtype == "error_max_turns")' \
      >/dev/null 2>&1
}

# checkpoint_decision <claude_exit> <hit_turn_cap:0|1> <has_unrestored_stash:0|1>
# -- the disposition of a tier-1 worktree after the claude run:
#   commit     exit 0: work is done -> commit + finalize the PR (ready to review)
#   checkpoint nonzero, hit the turn cap, no stash: snapshot the WIP + resume
#   discard    anything else -- a real crash; or a turn-cap cut-off left with an
#              unrestored `git stash` we can't safely commit over -> the existing
#              ship-safety discard.
# The stash guard preserves the porksicle#114 invariant: never auto-commit over
# an unrestored `git stash` (committing -A would silently drop its contents).
checkpoint_decision() {
  local exit_code="$1" hit_cap="$2" has_stash="$3"
  if [ "$exit_code" -eq 0 ]; then printf 'commit'; return; fi
  if [ "$hit_cap" = "1" ] && [ "$has_stash" != "1" ]; then
    printf 'checkpoint'; return
  fi
  printf 'discard'
}

# checkpoint_is_wip <pr_title> -- rc 0 if the title marks a live checkpoint the
# review/merge loops must skip and the claim loop must resume.
checkpoint_is_wip() {
  case "$1" in "$CHECKPOINT_WIP_PREFIX"*) return 0 ;; *) return 1 ;; esac
}

# checkpoint_strip_wip <pr_title> -- the title with the WIP prefix removed
# (idempotent: a title without the prefix is returned unchanged).
checkpoint_strip_wip() {
  printf '%s' "${1#"$CHECKPOINT_WIP_PREFIX"}"
}

# checkpoint_wip_title <pr_title> -- the title carrying the WIP prefix exactly
# once (safe to call on an already-WIP title).
checkpoint_wip_title() {
  if checkpoint_is_wip "$1"; then printf '%s' "$1"
  else printf '%s%s' "$CHECKPOINT_WIP_PREFIX" "$1"; fi
}

# checkpoint_read_count <pr_body> -- the checkpoint counter parsed from the body
# marker, or 0 if absent/garbled.
checkpoint_read_count() {
  local n
  n=$(printf '%s' "$1" | grep -oE "${CHECKPOINT_COUNT_TAG}=[0-9]+" | tail -1 | grep -oE '[0-9]+')
  printf '%s' "${n:-0}"
}

# checkpoint_set_count <pr_body> <n> -- the body with the checkpoint counter
# marker set to n: any existing marker LINE is dropped and a fresh one appended.
# Line-oriented (not sed-substitution) so an arbitrary '|', '&', or '/' in the
# body can't corrupt it.
checkpoint_set_count() {
  local body="$1" n="$2" stripped
  stripped=$(printf '%s\n' "$body" \
    | grep -vE "^[[:space:]]*<!-- ${CHECKPOINT_COUNT_TAG}=[0-9]+ -->[[:space:]]*$")
  printf '%s\n\n<!-- %s=%s -->\n' "$stripped" "$CHECKPOINT_COUNT_TAG" "$n"
}

# pr_body_ensure_closes <pr_body> <issue_number> -- the body with a
# "Closes #<issue>" line guaranteed present, so a merge auto-closes the issue
# (#372). Idempotent + no-dup: returns the body unchanged when <issue> is empty
# OR the body already carries a closing keyword (close/fix/resolve, any
# inflection) for that EXACT issue -- so it never doubles a keyword Claude
# already wrote, and "#369" won't be considered satisfied by a "#3690". Pure
# string logic; bin/tick.sh owns the git/forgejo side effects.
pr_body_ensure_closes() {
  local body="$1" issue="$2"
  [ -n "$issue" ] || { printf '%s' "$body"; return; }
  if printf '%s' "$body" \
      | grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#${issue}([^0-9]|$)"; then
    printf '%s' "$body"
  else
    printf '%s\n\nCloses #%s' "$body" "$issue"
  fi
}

# checkpoint_budget_exhausted <count> -- rc 0 when an issue has checkpointed
# CHECKPOINT_MAX or more times without finishing and must be escalated to a human
# instead of resumed again.
checkpoint_budget_exhausted() {
  [ "${1:-0}" -ge "$CHECKPOINT_MAX" ]
}
