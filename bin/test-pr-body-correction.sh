#!/usr/bin/env bash
# test-pr-body-correction.sh -- the rework agent's channel for correcting a
# PR *description* it has no remote write access to (igor#607).
#
# The behaviour under test: a reviewer finding against the PR body (a checked
# box that no longer matches the diff) previously had nowhere to land -- the
# rework agent could not edit the body, and .agent/PR_BODY.md is a NEW-PR-only
# seed the harness never reads on a reopened PR. This file is the channel;
# tick.sh applies it via forgejo_edit_pr regardless of whether the round also
# produced commits.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/pr-body-correction.sh
. "$HERE/lib/pr-body-correction.sh"
# shellcheck source=../lib/review.sh
. "$HERE/lib/review.sh"
# shellcheck source=../lib/checkpoint.sh
. "$HERE/lib/checkpoint.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [${2:0:120}] lacks [$3]" ;; esac; }

WT=$(mktemp -d); trap 'rm -rf "$WT"' EXIT
mkdir -p "$WT/.agent"

echo "== reading a correction from a worktree =="
if pr_body_correction_read "$WT" >/dev/null 2>&1; then bad "no file -> no correction"; else ok "no file -> no correction"; fi

: > "$WT/.agent/pr_body_correction.md"
if pr_body_correction_read "$WT" >/dev/null 2>&1; then bad "empty file -> no correction"; else ok "empty file -> no correction"; fi

printf '\n\n   \t\n' > "$WT/.agent/pr_body_correction.md"
if pr_body_correction_read "$WT" >/dev/null 2>&1; then bad "whitespace-only -> no correction"; else ok "whitespace-only -> no correction"; fi

printf -- '## What this PR does\n\n- [x] fix: MASSIVE_API_KEY is optional, not required\n' > "$WT/.agent/pr_body_correction.md"
if pr_body_correction_read "$WT" >/dev/null 2>&1; then ok "real content -> correction"; else bad "real content -> correction"; fi
has "content round-trips" "$(pr_body_correction_read "$WT")" "MASSIVE_API_KEY is optional"

echo "== a missing worktree is not a correction =="
if pr_body_correction_read "$WT/nope" >/dev/null 2>&1; then bad "absent dir -> no correction"; else ok "absent dir -> no correction"; fi
eq "pr_body_correction_read fails cleanly on an absent dir" "1" \
   "$(pr_body_correction_read "$WT/nope" >/dev/null 2>&1; echo $?)"

echo "== a stale file from a previous round is not this round's correction =="
printf -- 'stale correction from a previous round\n' > "$WT/.agent/pr_body_correction.md"
pr_body_correction_reset "$WT"
if pr_body_correction_read "$WT" >/dev/null 2>&1; then bad "reset clears a stale correction file"; else ok "reset clears a stale correction file"; fi

# Must not care whether the file, the dir, or the worktree is there: it runs
# unconditionally before the run, and under `set -e` a nonzero exit would take
# the tick down.
eq "reset is a no-op on an already-clean worktree" "0" \
   "$(pr_body_correction_reset "$WT" >/dev/null 2>&1; echo $?)"
eq "reset is a no-op on a worktree that has no .agent dir" "0" \
   "$(pr_body_correction_reset "$WT/nope" >/dev/null 2>&1; echo $?)"

echo "== the confirmation comment =="
COMMENT=$(pr_body_correction_comment)
has "it says the description was corrected" "$COMMENT" "description"
has "it says this was automated" "$COMMENT" "automated"

echo "== the harness's own 'Closes #N' guarantee survives a correction =="
# The agent is told to write a FULL replacement body, so it can drop the
# "Closes #N" line the harness appended at open time (#372) and the issue
# silently stops auto-closing on merge. The harness re-applies its own
# guarantee to the replacement rather than trusting the prompt to say so.
OLD_BODY=$'## What this PR does\n\n- [x] feat: thing\n\nCloses #607'
NEW_BODY=$'## What this PR does\n\n- [x] fix: thing, accurately this time'

FIXED=$(pr_body_ensure_closes "$NEW_BODY" "$(review_closed_issue_number "$OLD_BODY")")
has "a dropped trailer is restored from the body being replaced" "$FIXED" "Closes #607"
has "and the agent's corrected text is kept verbatim" "$FIXED" "accurately this time"

KEPT=$(pr_body_ensure_closes "$NEW_BODY"$'\n\nCloses #607' "$(review_closed_issue_number "$OLD_BODY")")
eq "a trailer the agent kept is not duplicated" "1" "$(grep -c 'Closes #607' <<<"$KEPT")"

NONE=$(pr_body_ensure_closes "$NEW_BODY" "$(review_closed_issue_number 'names no issue at all')")
case "$NONE" in
  *Closes*) bad "a PR that closes no issue gains no trailer" ;;
  *)        ok  "a PR that closes no issue gains no trailer" ;;
esac

echo "== bin/tick.sh: the wiring (source assertions) =="
# These read the source rather than driving it: the branch lives inline in the
# PR-review flow, which needs a worktree, a repo, and a model call to reach.
TICK="$HERE/bin/tick.sh"

if grep -q 'pr_body_correction_reset "\$PR_WORKTREE"' "$TICK"; then
  ok "the PR-rework flow resets the correction file before the run"
else bad "the PR-rework flow resets the correction file before the run"; fi

if grep -q 'pr_body_correction_read "\$PR_WORKTREE"' "$TICK"; then
  ok "the post-run flow consults the correction file"
else bad "the post-run flow consults the correction file"; fi

if grep -q 'forgejo_edit_pr "\$PR_REPO" "\$PR_NUMBER" --body "\$PR_BODY_FIX"' "$TICK"; then
  ok "a correction is applied via forgejo_edit_pr"
else bad "a correction is applied via forgejo_edit_pr"; fi

if grep -qF 'pr_body_ensure_closes "$PR_BODY_FIX" "$(review_closed_issue_number "$PR_BODY")"' "$TICK"; then
  ok "the replacement body is put through pr_body_ensure_closes first"
else bad "the replacement body is put through pr_body_ensure_closes first"; fi

# ...and that has to happen BEFORE the PATCH, not after it.
ENSURE_AT=$(grep -nF 'pr_body_ensure_closes "$PR_BODY_FIX"' "$TICK" | head -1 | cut -d: -f1)
EDIT_AT=$(grep -n 'forgejo_edit_pr "\$PR_REPO" "\$PR_NUMBER" --body "\$PR_BODY_FIX"' "$TICK" | head -1 | cut -d: -f1)
if [ -n "$ENSURE_AT" ] && [ -n "$EDIT_AT" ] && [ "$ENSURE_AT" -lt "$EDIT_AT" ]; then
  ok "the trailer is restored BEFORE the PATCH (ensure ${ENSURE_AT} < edit ${EDIT_AT})"
else
  bad "the trailer is restored BEFORE the PATCH (ensure ${ENSURE_AT:-?}, edit ${EDIT_AT:-?})"
fi

if grep -q 'pr_body_correction_comment' "$TICK"; then
  ok "a confirmation comment is posted"
else bad "a confirmation comment is posted"; fi

# The core requirement (decision 3 in the ticket): this must NOT be gated on
# commits. Pin the structure -- the read has to sit ABOVE where PR_NEW is
# computed (the commits/no-commits fork), so both paths get it.
READ_AT=$(grep -n 'pr_body_correction_read "\$PR_WORKTREE"' "$TICK" | head -1 | cut -d: -f1)
PR_NEW_AT=$(grep -n 'PR_NEW=\$(git rev-list' "$TICK" | head -1 | cut -d: -f1)
if [ -n "$READ_AT" ] && [ -n "$PR_NEW_AT" ] && [ "$READ_AT" -lt "$PR_NEW_AT" ]; then
  ok "the correction is applied ABOVE the commits/no-commits split (read ${READ_AT} < split ${PR_NEW_AT})"
else
  bad "the correction is applied ABOVE the commits/no-commits split (read ${READ_AT:-?}, split ${PR_NEW_AT:-?})"
fi

# Ordering: reading after the worktree is torn down would silently never fire.
FINAL_RM=$(grep -n 'git worktree remove --force "\$PR_WORKTREE"' "$TICK" | tail -1 | cut -d: -f1)
if [ -n "$READ_AT" ] && [ -n "$FINAL_RM" ] && [ "$READ_AT" -lt "$FINAL_RM" ]; then
  ok "the correction is read BEFORE the worktree is removed (read ${READ_AT} < rm ${FINAL_RM})"
else
  bad "the correction is read BEFORE the worktree is removed (read ${READ_AT:-?}, rm ${FINAL_RM:-?})"
fi

# Ordering, the other end: the reset has to precede the read, or it clears the
# correction it was supposed to be guarding.
RESET_AT=$(grep -n 'pr_body_correction_reset "\$PR_WORKTREE"' "$TICK" | tail -1 | cut -d: -f1)
if [ -n "$READ_AT" ] && [ -n "$RESET_AT" ] && [ "$RESET_AT" -lt "$READ_AT" ]; then
  ok "the reset runs BEFORE the read (reset ${RESET_AT} < read ${READ_AT})"
else
  bad "the reset runs BEFORE the read (reset ${RESET_AT:-?}, read ${READ_AT:-?})"
fi

# The file is written INSIDE the repo the agent is committing to, so the claim
# "a correction cannot leak into the diff" rests entirely on the PR-rework
# worktree getting the ignore-everything scratch dir before the run -- same
# invariant lib/adjudication.sh's dismissed.md relies on.
if grep -q 'init_igor_scratch "\$PR_WORKTREE"' "$TICK"; then
  ok "the PR-rework worktree gets the ignored .agent scratch dir"
else bad "the PR-rework worktree gets the ignored .agent scratch dir"; fi

# The prompt has to name the exact path the harness reads, or the agent writes
# somewhere nothing looks. Both heredocs (binding + reassignment) need it.
PROMPT_MENTIONS=$(grep -c '\.agent/pr_body_correction\.md' "$TICK")
if [ "$PROMPT_MENTIONS" -ge 2 ]; then
  ok "both rework prompts name the same path the lib reads (${PROMPT_MENTIONS} mentions)"
else
  bad "both rework prompts name the same path the lib reads (found ${PROMPT_MENTIONS})"
fi
eq "and that path matches PR_BODY_CORRECTION_FILE" ".agent/pr_body_correction.md" "$PR_BODY_CORRECTION_FILE"

if [ "$FAIL" -eq 0 ]; then
  echo "test-pr-body-correction: all checks passed"
else
  echo "test-pr-body-correction: $FAIL FAILED"
  exit 1
fi
