#!/usr/bin/env bash
# test-adjudication.sh -- the rework agent's standing to DISAGREE with a review
# finding, and the converged/stuck distinction that falls out of it.
#
# The behaviour under test: before this, an agent that correctly dismissed every
# finding produced no commits, which was indistinguishable from an agent that
# crashed or could not act. Both escalated with "didn't make any new commits."
# The dismissals file is what separates them, so the tests that matter are the
# ones about an EMPTY or ABSENT file -- getting those wrong turns every stuck
# rework into a false "converged" and hands the operator an empty rationale.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/adjudication.sh
. "$HERE/lib/adjudication.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [${2:0:120}] lacks [$3]" ;; esac; }

WT=$(mktemp -d); trap 'rm -rf "$WT"' EXIT
mkdir -p "$WT/.agent"

echo "== reading dismissals from a worktree =="
if adjudication_has "$WT"; then bad "no file -> no dismissals"; else ok "no file -> no dismissals"; fi

: > "$WT/.agent/dismissed.md"
if adjudication_has "$WT"; then bad "empty file -> no dismissals"; else ok "empty file -> no dismissals"; fi

printf '\n\n   \t\n' > "$WT/.agent/dismissed.md"
if adjudication_has "$WT"; then bad "whitespace-only -> no dismissals"; else ok "whitespace-only -> no dismissals"; fi

printf -- '- Finding 2: greps clean, no call site passes null. Dismissed.\n' > "$WT/.agent/dismissed.md"
if adjudication_has "$WT"; then ok "real content -> dismissals"; else bad "real content -> dismissals"; fi
has "content round-trips" "$(adjudication_read "$WT")" "no call site passes null"

echo "== a missing worktree is not a dismissal =="
if adjudication_has "$WT/nope"; then bad "absent dir -> no dismissals"; else ok "absent dir -> no dismissals"; fi
eq "adjudication_read fails cleanly on an absent dir" "1" \
   "$(adjudication_read "$WT/nope" >/dev/null 2>&1; echo $?)"

echo "== the comment tells the operator what is being asked of them =="
BODY="- Finding 2: dismissed, the reviewer misread the guard."
CONV=$(adjudication_comment "$BODY" true)
PART=$(adjudication_comment "$BODY" false)
has "converged carries the reasoning"  "$CONV" "the reviewer misread the guard"
has "partial carries the reasoning"    "$PART" "the reviewer misread the guard"
has "both say findings were dismissed" "$CONV" "findings dismissed"
has "converged says it is now theirs"  "$CONV" "it is yours"
has "partial says the loop continues"  "$PART" "will re-review"
case "$PART" in *"it is yours"*) bad "partial must NOT claim the loop ended" ;; *) ok "partial must NOT claim the loop ended" ;; esac
case "$CONV" in *"will re-review"*) bad "converged must NOT promise another review" ;; *) ok "converged must NOT promise another review" ;; esac

# The no-commits branch also fires on a plain reassignment, where the points
# came from the operator's own comments and there was no automated review loop
# to end. Wording that assumes the shadow reviewer would be asserting something
# false on that path. Body chosen to contain neither phrase itself.
NEUTRAL=$(adjudication_comment "- dismissed: the guard already covers that input." true)
case "$NEUTRAL" in
  *"automated loop"*|*"the reviewer"*)
    bad "converged must not assume the points came from the shadow reviewer" ;;
  *) ok "converged must not assume the points came from the shadow reviewer" ;;
esac

echo "== the log line distinguishes the two outcomes =="
has "converged log names convergence" "$(adjudication_log_line r 1 true)"  "converged"
has "converged log names the handoff" "$(adjudication_log_line r 1 true)"  "handing to the human"
has "partial log names the commits"   "$(adjudication_log_line r 1 false)" "fixed in commits"
case "$(adjudication_log_line r 1 false)" in
  *converged*) bad "partial log must not say converged" ;;
  *)           ok  "partial log must not say converged" ;;
esac

echo "== a stale file from a previous round is not this round's argument =="
# adjudication_reset is what makes "the file is non-empty" mean "the agent
# dismissed something THIS run". Without it a worktree that survives a crash at
# the same path -- or is ever reused across rounds -- lets a round where the
# agent did nothing report as CONVERGED and post someone else's reasoning,
# which is the exact false positive the empty-file cases above exist to stop.
printf -- '- stale reasoning from a previous round\n' > "$WT/.agent/dismissed.md"
adjudication_reset "$WT"
if adjudication_has "$WT"; then bad "reset clears a stale dismissals file"; else ok "reset clears a stale dismissals file"; fi

# Must not care whether the file, the dir, or the worktree is there: it runs
# unconditionally before the run, and under `set -e` a nonzero exit would take
# the tick down.
eq "reset is a no-op on an already-clean worktree" "0" \
   "$(adjudication_reset "$WT" >/dev/null 2>&1; echo $?)"
eq "reset is a no-op on a worktree that has no .agent dir" "0" \
   "$(adjudication_reset "$WT/nope" >/dev/null 2>&1; echo $?)"

echo "== bin/tick.sh: the wiring (source assertions) =="
# These read the source rather than driving it: the branches live inline in the
# PR-review flow, which needs a worktree, a repo, and a model call to reach.
# Labelled as source checks, not dressed up as behavioural coverage -- but they
# do catch a revert, which the pure tests above cannot.
TICK="$HERE/bin/tick.sh"

if grep -q 'adjudication_reset "\$PR_WORKTREE"' "$TICK"; then
  ok "the PR-rework flow resets the dismissals file"
else bad "the PR-rework flow resets the dismissals file"; fi

if grep -q 'adjudication_read "\$PR_WORKTREE"' "$TICK"; then
  ok "the post-run flow consults the dismissals file"
else bad "the post-run flow consults the dismissals file"; fi

# -ge, not -eq: both paths must consult it, but a future third call site is a
# legitimate addition and shouldn't fail a suite that has no behavioural
# complaint about it.
CONSULTS=$(grep -c 'adjudication_read "\$PR_WORKTREE"' "$TICK")
if [ "$CONSULTS" -ge 2 ]; then
  ok "it is consulted on BOTH the commits and no-commits paths (${CONSULTS} sites)"
else
  bad "it is consulted on BOTH the commits and no-commits paths (found ${CONSULTS})"
fi

# Ordering: reading after the worktree is torn down would silently never fire.
LAST_READ=$(grep -n 'adjudication_read "\$PR_WORKTREE"' "$TICK" | tail -1 | cut -d: -f1)
FINAL_RM=$(grep -n 'git worktree remove --force "\$PR_WORKTREE"' "$TICK" | tail -1 | cut -d: -f1)
if [ -n "$LAST_READ" ] && [ -n "$FINAL_RM" ] && [ "$LAST_READ" -lt "$FINAL_RM" ]; then
  ok "dismissals are read BEFORE the worktree is removed (read ${LAST_READ} < rm ${FINAL_RM})"
else
  bad "dismissals are read BEFORE the worktree is removed (read ${LAST_READ:-?}, rm ${FINAL_RM:-?})"
fi

# Ordering, the other end: the reset has to precede EVERY read, or it clears the
# argument it was supposed to be guarding. FIRST read, not last -- one read
# landing above the reset is the whole bug.
FIRST_READ=$(grep -n 'adjudication_read "\$PR_WORKTREE"' "$TICK" | head -1 | cut -d: -f1)
RESET_AT=$(grep -n 'adjudication_reset "\$PR_WORKTREE"' "$TICK" | tail -1 | cut -d: -f1)
if [ -n "$FIRST_READ" ] && [ -n "$RESET_AT" ] && [ "$RESET_AT" -lt "$FIRST_READ" ]; then
  ok "the reset runs BEFORE any read (reset ${RESET_AT} < read ${FIRST_READ})"
else
  bad "the reset runs BEFORE any read (reset ${RESET_AT:-?}, read ${FIRST_READ:-?})"
fi

# The file is written INSIDE the repo the agent is committing to, so the claim
# "a dismissal cannot leak into the diff" rests entirely on the PR-rework
# worktree getting the ignore-everything scratch dir before the run. Drop that
# call and dismissals start showing up in the PR.
if grep -q 'init_igor_scratch "\$PR_WORKTREE"' "$TICK"; then
  ok "the PR-rework worktree gets the ignored .agent scratch dir"
else bad "the PR-rework worktree gets the ignored .agent scratch dir"; fi
if grep -q "printf '\*\\\\n' > \"\$worktree/.agent/.gitignore\"" "$TICK"; then
  ok "and that scratch dir ignores everything in it"
else bad "and that scratch dir ignores everything in it"; fi

# The prompt has to name the exact path the harness reads, or the agent writes
# somewhere nothing looks.
if grep -q '\.agent/dismissed\.md' "$TICK"; then
  ok "the rework prompt names the same path the lib reads"
else bad "the rework prompt names the same path the lib reads"; fi
eq "and that path matches ADJUDICATION_FILE" "$ADJUDICATION_FILE" ".agent/dismissed.md"

if [ "$FAIL" -eq 0 ]; then
  echo "test-adjudication: all checks passed"
else
  echo "test-adjudication: $FAIL FAILED"
  exit 1
fi
