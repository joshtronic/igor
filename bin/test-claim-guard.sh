#!/usr/bin/env bash
# test-claim-guard.sh -- unit tests for igor#496: the claim gate re-claimed
# issues with an open, ready PR already covering them, rebuilding and
# force-pushing over the same agent/<n>-slug branch and destroying rework
# fixes (PRs #492/#494).
#
# Root cause: forgejo_bot_prs_for_issue's closing-keyword regex only matches
# the literal word "closes", but pr_body_ensure_closes -- which decides
# whether to APPEND a "Closes #N" line to a PR body -- treats the wider
# close/fix/resolve family (any inflection) as already-satisfied and leaves
# the body alone. A PR whose own prose says e.g. "This fixes #490 by ..." is
# therefore invisible to the narrower regex: the discovery gate sees no
# in-flight PR for the issue and reclaims it, rebuilding the branch from
# scratch. forgejo_open_pr_covers_issue (lib/forgejo.sh) closes that gap with
# a structural, author-independent check: an open PR whose head branch is the
# issue's own agent/<n>(-*) namespace, OR whose body matches the SAME broad
# keyword family pr_body_ensure_closes already treats as satisfying, blocks
# reclaim -- regardless of assignment history, review state, or anything in
# discretionary-state.json.
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
eq "\"resolved #491\" prose is also recognized" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 491)"$'\n')"

_fj() { printf '%s' '[{"number":494,"head":{"ref":"some-other-branch"},"body":"Close #490 once merged.","user":{"login":"igor"}}]'; }
eq "\"close #490\" (no s) is also recognized" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

echo "== forgejo_open_pr_covers_issue: literal Closes still works, no false positives =="
_fj() { printf '%s' '[{"number":495,"head":{"ref":"agent/500-other-issue"},"body":"Closes #490","user":{"login":"igor"}}]'; }
eq "literal \"Closes #490\" still matches" "1" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { printf '%s' '[{"number":496,"head":{"ref":"agent/500-other-issue"},"body":"Closes #4900","user":{"login":"igor"}}]'; }
eq "\"#4900\" does not falsely satisfy issue 490 (word-boundary respected)" "0" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { printf '%s' '[]'; }
eq "no open PRs at all -> empty" "0" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

# ---------------------------------------------------------------------------
# Discovery gate's EXACT filter (bin/tick.sh, post-fix): open, non-WIP entries
# from forgejo_open_pr_covers_issue block the claim; a WIP checkpoint entry
# does not (it falls through to the existing resume path, unchanged).
# ---------------------------------------------------------------------------
echo "== discovery gate: ready PR open -> NOT claimable =="
COVERING='[{"number":492,"title":"fix: claim gate re-claims issues"}]'
GATE=$(jq --arg wip "$CHECKPOINT_WIP_PREFIX" \
  '[.[] | select((.title // "") | startswith($wip) | not)] | length' <<<"$COVERING")
eq "a ready (non-WIP) covering PR blocks the claim" "true" "$([ "$GATE" -gt 0 ] && echo true || echo false)"

echo "== discovery gate: WIP checkpoint PR open -> resume path unchanged, still claimable here =="
WIP_COVERING=$(jq -n --arg wip "$CHECKPOINT_WIP_PREFIX" '[{number: 490, title: ($wip + "issue #490 checkpoint")}]')
GATE=$(jq --arg wip "$CHECKPOINT_WIP_PREFIX" \
  '[.[] | select((.title // "") | startswith($wip) | not)] | length' <<<"$WIP_COVERING")
eq "a WIP checkpoint PR does NOT block the claim (resume handles it downstream)" "0" "$GATE"

echo "== discovery gate: no covering PR -> claimable (unchanged) =="
GATE=$(jq --arg wip "$CHECKPOINT_WIP_PREFIX" \
  '[.[] | select((.title // "") | startswith($wip) | not)] | length' <<<'[]')
eq "no open PR covering the issue -> claimable" "0" "$GATE"

# ---------------------------------------------------------------------------
# Defense in depth (bin/tick.sh): about to carve BRANCH fresh from PR_BASE
# (non-resume). If origin already carries ANY agent/<n>(-*) branch, abort
# instead of force-pushing over it. Exercised against a REAL git remote --
# mirrors the exact `git for-each-ref` tick.sh runs.
# ---------------------------------------------------------------------------
echo "== defense in depth: fresh claim aborts when origin already has agent/<n>-* =="
BARE="$TMPROOT/origin.git"; git init -q --bare -b master "$BARE"
SEED="$TMPROOT/seed"; git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
: >"$SEED/README.md"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$BARE"; git -C "$SEED" push -q origin master
git -C "$SEED" checkout -q -b agent/490-fix-claim-gate
: >"$SEED/rework-fix.txt"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m "rework fix"
git -C "$SEED" push -q origin agent/490-fix-claim-gate

CLONE="$TMPROOT/clone"; git clone -q "$BARE" "$CLONE"
ISSUE_NUMBER=490
STALE_BRANCHES=$(git -C "$CLONE" for-each-ref --format='%(refname:short)' \
  "refs/remotes/origin/agent/${ISSUE_NUMBER}" "refs/remotes/origin/agent/${ISSUE_NUMBER}-*" \
  | sed 's#^origin/##')
eq "origin already has agent/490-* -> STALE_BRANCHES non-empty (abort)" "agent/490-fix-claim-gate" "$STALE_BRANCHES"

ISSUE_NUMBER=999
STALE_BRANCHES=$(git -C "$CLONE" for-each-ref --format='%(refname:short)' \
  "refs/remotes/origin/agent/${ISSUE_NUMBER}" "refs/remotes/origin/agent/${ISSUE_NUMBER}-*" \
  | sed 's#^origin/##')
eq "plain unclaimed issue with no matching origin branch -> STALE_BRANCHES empty (proceed)" "" "$STALE_BRANCHES"

# agent/49-* must not falsely match issue 4 (prefix collision).
ISSUE_NUMBER=4
STALE_BRANCHES=$(git -C "$CLONE" for-each-ref --format='%(refname:short)' \
  "refs/remotes/origin/agent/${ISSUE_NUMBER}" "refs/remotes/origin/agent/${ISSUE_NUMBER}-*" \
  | sed 's#^origin/##')
eq "agent/490-* does not falsely match issue 4 (no shared-prefix false positive)" "" "$STALE_BRANCHES"

# ---------------------------------------------------------------------------
# Structural regression net: tick.sh must actually call the new helper in the
# discovery loop and carry the branch-abort snippet, not just have them exist
# unused in lib/forgejo.sh.
# ---------------------------------------------------------------------------
echo "== tick.sh: wires up the structural guard + branch abort (igor#496) =="
TICK="$HERE/tick.sh"
eq "discovery loop calls forgejo_open_pr_covers_issue" "true" \
  "$(grep -q 'C_COVERING=\$(forgejo_open_pr_covers_issue ' "$TICK" && echo true || echo false)"
eq "fresh -B path checks for a stale agent/<n>(-*) branch on origin before overwriting" "true" \
  "$(grep -q 'STALE_BRANCHES=\$(git for-each-ref' "$TICK" && echo true || echo false)"
eq "the branch-abort path blocks via agent-block.sh (not a silent skip)" "true" \
  "$(grep -A8 'STALE_BRANCHES=\$(git for-each-ref' "$TICK" | grep -q 'agent-block.sh' && echo true || echo false)"

if [ "$FAIL" -eq 0 ]; then echo "test-claim-guard: all checks passed"; exit 0; fi
echo "test-claim-guard: $FAIL check(s) FAILED"
exit 1
