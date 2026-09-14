#!/usr/bin/env bash
# pr-body-correction.sh -- let the rework agent correct the PR *description*
# it cannot otherwise touch.
#
# igor#607: a reviewer can raise a blocking finding against the PR body
# itself (a checked box that no longer matches the diff). The rework agent
# has no remote write access and, in review mode, is explicitly told not to
# write .agent/PR_BODY.md (that file only seeds a NEW PR's description at
# open time -- it does nothing on a reopened one). Before this, the fix had
# to land as a human applying the agent's suggested text by hand.
#
# The agent instead writes the corrected FULL body to
# .agent/pr_body_correction.md. The harness -- which owns the PR body -- reads
# it after the run and PATCHes the description via forgejo_edit_pr, then
# posts a confirmation comment. This applies even when the round produced no
# commits at all: "the description was wrong" is a complete, valid outcome on
# its own (igor#607's stonks#81/#104/#121 pattern).
#
# Same file-based shape as lib/adjudication.sh's .agent/dismissed.md, and for
# the same reason: .agent/ already carries the `*` .gitignore that
# init_igor_scratch writes before the agent runs, so this can never leak into
# the diff under `git add -A`.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# The file the agent writes. Named in the prompt; keep the two in sync.
PR_BODY_CORRECTION_FILE=".agent/pr_body_correction.md"

# pr_body_correction_path <worktree> -- absolute path to the correction file.
pr_body_correction_path() { printf '%s/%s' "${1:-.}" "$PR_BODY_CORRECTION_FILE"; }

# pr_body_correction_reset <worktree>
# Clear any correction file before handing the worktree to the agent, so a
# non-empty file afterwards means THIS run wrote it -- same rationale as
# adjudication_reset: a worktree path reused across rounds must not let a
# stale file from a prior round get applied again as if it were fresh.
pr_body_correction_reset() { rm -f "$(pr_body_correction_path "${1:-}")" 2>/dev/null || true; }

# pr_body_correction_read <worktree>
# Echo the corrected body, or nothing. Whitespace-only counts as nothing --
# an agent that touches the file without writing real content has not
# corrected anything, and applying it would blank out the PR description.
pr_body_correction_read() {
  local f content
  f=$(pr_body_correction_path "${1:-}")
  [ -f "$f" ] || return 1
  content=$(cat "$f" 2>/dev/null) || return 1
  printf '%s' "$content" | grep -q '[^[:space:]]' || return 1
  printf '%s' "$content"
}

# pr_body_correction_comment -- the PR comment posted after the description
# is patched, so the thread records that it happened and why, without
# quoting the (possibly long) new body back into the conversation.
pr_body_correction_comment() {
  printf '### ✏️ PR description corrected _(automated)_\n\nA reviewer finding said the description no longer matched the diff. The agent supplied a corrected body and the harness applied it directly -- see the PR description above for the current text.\n'
}
