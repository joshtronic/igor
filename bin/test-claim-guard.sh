#!/usr/bin/env bash
# test-claim-guard.sh -- unit tests for igor#496: the claim gate reclaimed
# issues that an open, ready PR already covered, rebuilding and force-pushing
# over the same agent/<n>-slug branch and destroying rework fixes (#492/#494).
#
# The invariant under test: forgejo_open_pr_covers_issue's keyword regex must
# stay as broad as pr_body_ensure_closes's "already satisfied" regex, or a PR
# whose body reads "fixes #N" (so no literal `Closes #N` line was ever
# appended) is invisible to the gate. Plus the pre-worktree branch abort,
# which must fire on a branch an open PR still lives on and stay out of the
# way of the rejected-attempt retry.
#
# Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-claim-guard: jq absent -- skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-claim-guard: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"
# shellcheck source=../lib/checkpoint.sh
. "$HERE/../lib/checkpoint.sh"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

echo "== forgejo_open_pr_covers_issue: branch-name signal (author-independent) =="
_fj() { cat <<'JSON'
[
 {"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"unrelated body, no keyword","user":{"login":"igor"}},
 {"number":10,"head":{"ref":"agent/49-something-else"},"body":"","user":{"login":"igor"}},
 {"number":11,"head":{"ref":"feature/manual"},"body":"nothing relevant","user":{"login":"human"}}
]
JSON
}
OUT=$(forgejo_open_pr_covers_issue acme/x 490)
eq "matches agent/490-<slug> branch even with no closing keyword" "1" "$(jq 'length' <<<"$OUT")"
eq "the matching PR is #492"                                       "492" "$(jq -r '.[0].number' <<<"$OUT")"
eq "the head ref rides along (the branch abort filters on it)"     "agent/490-fix-claim-gate" \
  "$(jq -r '.[0].head' <<<"$OUT")"
eq "agent/49-* (different issue, shared prefix) does NOT match"    "false" \
  "$(jq -r '[.[].number] | index(10) != null' <<<"$OUT")"

echo "== forgejo_open_pr_covers_issue: the root-cause keyword gap, now closed =="
# The exact shape that let #490/#491 slip through: a PR whose branch name
# doesn't happen to carry the issue number (title-slug drift is not modeled
# here) but whose body reads "fixes #490" -- a phrase forgejo_bot_prs_for_issue
# never matched (its regex requires the literal word "closes").
_fj() { printf '%s' '[{"number":492,"head":{"ref":"some-other-branch"},"body":"This PR fixes #490 by adding the missing guard.","user":{"login":"igor"}}]'; }
OUT=$(forgejo_open_pr_covers_issue acme/x 490)
eq "\"fixes #490\" prose is recognized (the bug forgejo_bot_prs_for_issue had)" "1" "$(jq 'length' <<<"$OUT")"
OLD=$(forgejo_bot_prs_for_issue acme/x 490 igor)
eq "...whereas forgejo_bot_prs_for_issue's narrower regex still misses it (documents the gap this fix closes)" \
  "0" "$(jq 'length' <<<"$OLD")"

_fj() { printf '%s' '[{"number":493,"head":{"ref":"some-other-branch"},"body":"Resolved #491 in the process.","user":{"login":"igor"}}]'; }
eq "\"resolved #491\" prose is also recognized" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 491)")"

_fj() { printf '%s' '[{"number":494,"head":{"ref":"some-other-branch"},"body":"Close #490 once merged.","user":{"login":"igor"}}]'; }
eq "\"close #490\" (no s) is also recognized" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

echo "== forgejo_open_pr_covers_issue: literal Closes still works, no false positives =="
_fj() { printf '%s' '[{"number":495,"head":{"ref":"agent/500-other-issue"},"body":"Closes #490","user":{"login":"igor"}}]'; }
eq "literal \"Closes #490\" still matches" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { printf '%s' '[{"number":496,"head":{"ref":"agent/500-other-issue"},"body":"Closes #4900","user":{"login":"igor"}}]'; }
eq "\"#4900\" does not falsely satisfy issue 490 (word-boundary respected)" "0" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { printf '%s' '[]'; }
eq "no open PRs at all -> empty" "0" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

echo "== forgejo_open_pr_covers_issue: paginates, and reports an incomplete listing =="
# A miss here is silent and repeats every tick, so a repo with more than one
# page of open PRs must not hide the covering PR on page 2.
_fj() {
  case "$2" in
    *page=1*) jq -nc '[range(50) | {number: (1000 + .), head: {ref: "other/\(.)"}, body: "nothing"}]' ;;
    *)        printf '%s' '[{"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"nothing"}]' ;;
  esac
}
OUT=$(forgejo_open_pr_covers_issue acme/x 490)
eq "a covering PR on page 2 is still found" "492" "$(jq -r '.[0].number // "none"' <<<"$OUT")"

_fj() { return 1; }
OUT=$(forgejo_open_pr_covers_issue acme/x 490); RC=$?
eq "an unfetchable listing returns nonzero..." "1" "$RC"
eq "...with no output, so a caller can't mistake it for \"nothing covering\"" "" "$OUT"

echo "== forgejo_prs_on_branches: which leftover branches still carry live work =="
COVERING='[{"number":492,"title":"t","head":"agent/490-fix-claim-gate"},{"number":493,"title":"t","head":"agent/490-old-slug"}]'
eq "an open PR built on the leftover branch is reported" "#492 (agent/490-fix-claim-gate)" \
  "$(forgejo_prs_on_branches "$COVERING" "agent/490-fix-claim-gate")"
eq "several leftover branches all report" "#492 (agent/490-fix-claim-gate), #493 (agent/490-old-slug)" \
  "$(forgejo_prs_on_branches "$COVERING" "$(printf 'agent/490-fix-claim-gate\nagent/490-old-slug')")"
eq "a leftover branch no open PR is built on reports nothing (rejected-attempt retry proceeds)" "" \
  "$(forgejo_prs_on_branches "$COVERING" "agent/490-rejected-attempt")"
eq "no covering PRs at all reports nothing" "" \
  "$(forgejo_prs_on_branches '[]' "agent/490-fix-claim-gate")"

# ---------------------------------------------------------------------------
# Discovery gate: the count that decides claimability is checkpoint_count_non_wip
# (lib/checkpoint.sh) applied to forgejo_open_pr_covers_issue's output -- the
# same function bin/tick.sh calls, not a re-implementation of it.
# ---------------------------------------------------------------------------
echo "== discovery gate: ready PR open -> NOT claimable =="
COVERING='[{"number":492,"title":"fix: claim gate re-claims issues","head":"agent/490-x"}]'
eq "a ready (non-WIP) covering PR blocks the claim" "1" "$(checkpoint_count_non_wip "$COVERING")"

echo "== discovery gate: WIP checkpoint PR open -> resume path unchanged, still claimable here =="
WIP_COVERING=$(jq -n --arg wip "$CHECKPOINT_WIP_PREFIX" '[{number: 490, title: ($wip + "issue #490 checkpoint"), head: "agent/490-x"}]')
eq "a WIP checkpoint PR does NOT block the claim (resume handles it downstream)" "0" \
  "$(checkpoint_count_non_wip "$WIP_COVERING")"

echo "== discovery gate: no covering PR -> claimable (unchanged) =="
eq "no open PR covering the issue -> claimable" "0" "$(checkpoint_count_non_wip '[]')"

# ---------------------------------------------------------------------------
# Defense in depth (bin/tick.sh): about to carve BRANCH fresh from PR_BASE
# (non-resume). Exercised against a REAL git remote -- mirrors the exact
# `git for-each-ref` tick.sh runs.
# ---------------------------------------------------------------------------
echo "== defense in depth: which origin branches the fresh-claim path notices =="
BARE="$TMPROOT/origin.git"; git init -q --bare -b master "$BARE"
SEED="$TMPROOT/seed"; git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
: >"$SEED/README.md"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$BARE"; git -C "$SEED" push -q origin master
git -C "$SEED" checkout -q -b agent/490-fix-claim-gate
: >"$SEED/rework-fix.txt"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m "rework fix"
git -C "$SEED" push -q origin agent/490-fix-claim-gate

CLONE="$TMPROOT/clone"; git clone -q "$BARE" "$CLONE"
stale_for() {
  git -C "$CLONE" for-each-ref --format='%(refname:short)' \
    "refs/remotes/origin/agent/${1}" "refs/remotes/origin/agent/${1}-*" \
    | sed 's#^origin/##'
}
eq "origin already has agent/490-* -> candidate for the abort check" "agent/490-fix-claim-gate" "$(stale_for 490)"
eq "plain unclaimed issue with no matching origin branch -> nothing to check" "" "$(stale_for 999)"
# agent/49-* must not falsely match issue 4 (prefix collision).
eq "agent/490-* does not falsely match issue 4 (no shared-prefix false positive)" "" "$(stale_for 4)"

echo "== defense in depth: only a branch an open PR lives on aborts the claim =="
STALE=$(stale_for 490)
eq "leftover branch + open PR built on it -> abort" "#492 (agent/490-fix-claim-gate)" \
  "$(forgejo_prs_on_branches '[{"number":492,"title":"t","head":"agent/490-fix-claim-gate"}]' "$STALE")"
eq "leftover branch from a CLOSED (rejected) PR -> no abort, the second attempt proceeds" "" \
  "$(forgejo_prs_on_branches '[]' "$STALE")"

# ---------------------------------------------------------------------------
# Structural regression net: tick.sh must actually wire the helpers up, and
# ISSUE_NUMBER must be assigned before the branch-abort block reads it -- under
# `set -u` an out-of-scope read there would kill every fresh claim while CI
# stayed green (nothing here executes tick.sh's claim path end to end).
# ---------------------------------------------------------------------------
echo "== tick.sh: wires up the structural guard + branch abort (igor#496) =="
TICK="$HERE/tick.sh"
eq "discovery loop calls forgejo_open_pr_covers_issue" "true" \
  "$(grep -q 'forgejo_open_pr_covers_issue ' "$TICK" && echo true || echo false)"
eq "discovery gate counts non-WIP entries via checkpoint_count_non_wip" "true" \
  "$(grep -q 'checkpoint_count_non_wip ' "$TICK" && echo true || echo false)"
eq "fresh -B path checks for a leftover agent/<n>(-*) branch on origin before overwriting" "true" \
  "$(grep -q 'STALE_BRANCHES=' "$TICK" && echo true || echo false)"
eq "that check narrows to branches an open PR is built on" "true" \
  "$(grep -A8 'STALE_BRANCHES=' "$TICK" | grep -q 'forgejo_prs_on_branches' && echo true || echo false)"
eq "and blocks via agent-block.sh (not a silent skip)" "true" \
  "$(grep -A16 'STALE_BRANCHES=' "$TICK" | grep -q 'agent-block.sh' && echo true || echo false)"

LN_SET=$(grep -n '^ISSUE_NUMBER=' "$TICK" | head -1 | cut -d: -f1)
LN_USE=$(grep -n 'STALE_BRANCHES=' "$TICK" | head -1 | cut -d: -f1)
eq "ISSUE_NUMBER is assigned before the branch-abort block reads it" "true" \
  "$([ -n "$LN_SET" ] && [ -n "$LN_USE" ] && [ "$LN_SET" -lt "$LN_USE" ] && echo true || echo false)"

if [ "$FAIL" -eq 0 ]; then echo "test-claim-guard: all checks passed"; exit 0; fi
echo "test-claim-guard: $FAIL check(s) FAILED"
exit 1
