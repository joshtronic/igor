#!/usr/bin/env bash
# adjudication.sh -- let the rework agent DISAGREE with a review finding
# instead of only complying with it.
#
# The loop this fixes: the reviewer is blind (diff only, no tools, deliberately
# -- see igor#241) and therefore raises everything it cannot rule out. The
# rework agent has the working tree and can actually go check. But its prompt
# only ever said "address the requested changes," so a finding the agent knows
# to be wrong or trivial had exactly two outcomes: comply with it anyway, or
# exit with no commits and escalate the whole PR to the operator.
#
# That is why 63% of verdicts (COMMENT, measured 2026-07-24..29) land on the
# operator's desk. A reviewer that surfaces everything is CORRECT -- it is the
# missing adjudicator that makes it expensive.
#
# The agent now writes dismissals to .agent/dismissed.md in its worktree. That
# directory already carries a `*` .gitignore, written by init_igor_scratch in
# bin/tick.sh -- which the PR-rework flow calls on PR_WORKTREE before the run --
# so a dismissal can never leak into the diff under `git add -A`.
#
# Three post-run outcomes, and the middle one is new:
#
#   commits                -> push, re-review (dismissals posted alongside)
#   no commits + dismissals-> CONVERGED. Hand to the operator with the
#                             reasoning attached. This is the terminal state
#                             the operator described: "1-2 nits dismissed
#                             without a code change."
#   no commits + none      -> STUCK. Escalate, exactly as before.
#
# Without the middle case, an agent that correctly dismissed every finding
# would be indistinguishable from one that crashed.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# The file the agent writes. Named in the prompt; keep the two in sync.
ADJUDICATION_FILE=".agent/dismissed.md"

# adjudication_path <worktree> -- absolute path to the dismissals file.
adjudication_path() { printf '%s/%s' "${1:-.}" "$ADJUDICATION_FILE"; }

# adjudication_read <worktree>
# Echo the dismissal text, or nothing. Whitespace-only counts as nothing: an
# agent that touches the file without writing to it has not dismissed
# anything, and treating that as "converged" would hand the operator an empty
# rationale and call it done.
adjudication_read() {
  local f content
  f=$(adjudication_path "${1:-}")
  [ -f "$f" ] || return 1
  content=$(cat "$f" 2>/dev/null) || return 1
  printf '%s' "$content" | grep -q '[^[:space:]]' || return 1
  printf '%s' "$content"
}

# adjudication_has <worktree> -- 0 when the agent dismissed something.
adjudication_has() { adjudication_read "${1:-}" >/dev/null 2>&1; }

# adjudication_comment <dismissals> <converged>
# The PR comment body. <converged> is "true" when NO commits were made, which
# changes what the operator is being asked for: on a converged PR they are the
# next actor, on a partial one the loop continues and this is context for the
# re-review.
#
# The header says the agent DISAGREED, in those words. An operator skimming a
# notification needs to tell "I fixed everything" from "I refused some of it"
# without opening the thread.
adjudication_comment() {
  local body="${1:-}" converged="${2:-false}" head tail_
  head="### 🧑‍⚖️ Rework — findings dismissed _(automated)_"
  if [ "$converged" = "true" ]; then
    tail_="No code changes: the agent judged every remaining finding not to require one. That makes this the end of the automated loop, so it is yours -- either the reasoning holds and you merge, or it does not and you say so."
  else
    tail_="The rest of the findings were addressed in the commits on this branch. The reviewer will re-review the new head."
  fi
  printf '%s\n\n%s\n\n---\n\n%s\n' "$head" "$body" "$tail_"
}

# adjudication_log_line <repo> <number> <converged>
# One line for the journal, phrased so a reader can tell the converged case
# from the stuck case without cross-referencing the code.
adjudication_log_line() {
  if [ "${3:-false}" = "true" ]; then
    printf 'PR-review: %s#%s adjudicated -- no commits, findings dismissed with reasons (converged, handing to the human)' "${1:-}" "${2:-}"
  else
    printf 'PR-review: %s#%s adjudicated -- some findings dismissed, others fixed in commits' "${1:-}" "${2:-}"
  fi
}
