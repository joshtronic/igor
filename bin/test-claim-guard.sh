#!/usr/bin/env bash
# test-claim-guard.sh -- unit tests for igor#496: the claim gate reclaimed
# issues that an open, ready PR already covered, rebuilding and force-pushing
# over the same agent/<n>-slug branch and destroying rework fixes (#492/#494).
#
# Two arms under test, pulling in opposite directions. The branch arm
# (`agent/<n>(-*)`) must catch every bot PR, since that is the class the gate
# exists to protect. The body arm must NOT catch a PR that merely mentions the
# issue in prose -- igor's own PR bodies do that constantly, and a false
# positive there stalls an unrelated issue silently and indefinitely. Plus the
# pre-worktree branch abort, which must fire on a branch an open PR still
# lives on and stay out of the way of the rejected-attempt retry.
#
# The operator amendment (appended to the issue before claim) makes
# ASSIGNMENT the primary claim lock: a claimed issue stays assigned to the
# bot for its PR's whole lifecycle, and is unassigned only when the issue
# closes or the work genuinely returns to the pool. The sections below cover
# that: the recovery sweep must leave an in-flight (real, non-WIP PR)
# assignment alone instead of clearing it every tick, and the ship path must
# stop clearing the assignment the moment a PR opens.
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
# forgejo_open_prs walks pages until one comes back empty, so every _fj stub
# standing in for a whole listing has to answer page 2 with [].
_fj() {
  case "$2" in
    *page=1*) cat <<'JSON'
[
 {"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"unrelated body, no keyword","user":{"login":"igor"}},
 {"number":10,"head":{"ref":"agent/49-something-else"},"body":"","user":{"login":"igor"}},
 {"number":11,"head":{"ref":"feature/manual"},"body":"nothing relevant","user":{"login":"human"}}
]
JSON
      ;;
    *) printf '%s' '[]' ;;
  esac
}
OUT=$(forgejo_open_pr_covers_issue acme/x 490)
eq "matches agent/490-<slug> branch even with no closing keyword" "1" "$(jq 'length' <<<"$OUT")"
eq "the matching PR is #492"                                       "492" "$(jq -r '.[0].number' <<<"$OUT")"
eq "the head ref rides along (the branch abort filters on it)"     "agent/490-fix-claim-gate" \
  "$(jq -r '.[0].head' <<<"$OUT")"
eq "agent/49-* (different issue, shared prefix) does NOT match"    "false" \
  "$(jq -r '[.[].number] | index(10) != null' <<<"$OUT")"

echo "== forgejo_prs_covering_issue: body arm matches a STANDALONE closing line =="
# covers <body> [issue] -- how many PRs the body arm alone matches. The head
# ref is deliberately outside the agent/ namespace so only the body can match.
covers() {
  local prs
  prs=$(jq -nc --arg b "$1" '[{number: 492, head: {ref: "some-other-branch"}, body: $b, user: {login: "igor"}}]')
  jq 'length' <<<"$(forgejo_prs_covering_issue "$prs" "${2:-490}")"
}
eq "bare \"Closes #490\""                     "1" "$(covers 'Closes #490')"
eq "the line pr_body_ensure_closes appends"   "1" "$(covers "$(pr_body_ensure_closes 'did the work' 490)")"
eq "\"Fixes #490.\" with a trailing period"   "1" "$(covers 'Fixes #490.')"
eq "\"- Resolves #490\" as a list item"       "1" "$(covers '- Resolves #490')"
eq "\"Close #490\" (no s) on its own line"    "1" "$(covers "$(printf 'intro\nClose #490\n')")"
eq "CRLF line endings (what the API returns)" "1" "$(covers "$(printf 'intro\r\nCloses #490\r\nmore\r\n')")"
eq "\"Resolved #491\" on its own line"        "1" "$(covers 'Resolved #491' 491)"

echo "== forgejo_prs_covering_issue: a prose mention must NOT match (igor#497) =="
# The body arm matches ANY open PR by ANY author, so anything looser than a
# standalone closing line makes the discovery loop skip an unrelated issue on
# every tick for as long as the PR is open -- silent, and indefinite. igor's
# own PR bodies are the first case: they quote other tickets constantly.
eq "mid-sentence \"This PR fixes #490 by ...\"" "0" \
  "$(covers 'This PR fixes #490 by adding the missing guard.')"
eq "the same phrase wrapped onto a fresh line"  "0" \
  "$(covers "$(printf 'a body of\nfixes #490 by adding the missing guard. satisfied the old regex')")"
eq "a checklist item mentioning the issue"      "0" \
  "$(covers "$(printf '## What this PR does\n\n- [x] fix: something that also fixes #490 somehow\n')")"
eq "\"#4900\" does not falsely satisfy issue 490" "0" "$(covers 'Closes #4900')"
eq "no keyword at all"                            "0" "$(covers 'see #490 for context')"

echo "== forgejo_prs_covering_issue: the branch arm is what covers every bot PR =="
# A bot PR whose body only mentions the issue in prose is still caught, because
# bin/tick.sh builds BRANCH as agent/<n>[-slug] and every bot PR lives there.
# That is the arm that closes igor#496; the body arm is for the rest.
INCIDENT='[{"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"This PR fixes #490 by adding the missing guard.","user":{"login":"igor"}}]'
eq "prose body + agent/490-<slug> branch -> covered" "1" \
  "$(jq 'length' <<<"$(forgejo_prs_covering_issue "$INCIDENT" 490)")"
_fj() { printf '%s' "$INCIDENT"; }
eq "...and forgejo_bot_prs_for_issue would have missed it (the igor#496 gap)" "0" \
  "$(jq 'length' <<<"$(forgejo_bot_prs_for_issue acme/x 490 igor)")"

echo "== forgejo_open_prs: paginates, and reports an incomplete listing =="
# A miss here is silent and repeats every tick, so a repo with more than one
# page of open PRs must not hide the covering PR on page 2.
_fj() {
  case "$2" in
    *page=1*) jq -nc '[range(50) | {number: (1000 + .), head: {ref: "other/\(.)"}, body: "nothing"}]' ;;
    *page=2*) printf '%s' '[{"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"nothing"}]' ;;
    *)        printf '%s' '[]' ;;
  esac
}
OUT=$(forgejo_open_pr_covers_issue acme/x 490)
eq "a covering PR on page 2 is still found" "492" "$(jq -r '.[0].number // "none"' <<<"$OUT")"

# A short page is NOT treated as the end: a Forgejo whose MAX_RESPONSE_ITEMS is
# below our limit=50 would otherwise report "complete" after page 1.
_fj() {
  case "$2" in
    *page=1*) jq -nc '[range(10) | {number: (1000 + .), head: {ref: "other/\(.)"}, body: "nothing"}]' ;;
    *page=2*) printf '%s' '[{"number":492,"head":{"ref":"agent/490-fix-claim-gate"},"body":"nothing"}]' ;;
    *)        printf '%s' '[]' ;;
  esac
}
eq "a server that honours a smaller page size still gets walked to the end" "492" \
  "$(jq -r '.[0].number // "none"' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { printf '%s' '[]'; }
eq "no open PRs at all -> empty" "0" "$(jq 'length' <<<"$(forgejo_open_pr_covers_issue acme/x 490)")"

_fj() { return 1; }
OUT=$(forgejo_open_pr_covers_issue acme/x 490); RC=$?
eq "an unfetchable listing returns nonzero..." "1" "$RC"
eq "...with no output, so a caller can't mistake it for \"nothing covering\"" "" "$OUT"

echo "== forgejo_open_prs: a degenerate response terminates instead of spinning =="
# `jq length` on an empty body yields an empty string, and `[ "" -lt 50 ]` is
# an error, not false -- which in the first cut meant page++ forever, hanging
# the tick. Both the numeric guard and the page cap have to hold for these to
# return at all, so a regression shows up as a hung suite, not a red one.
_fj() { printf ''; }
OUT=$(forgejo_open_prs acme/x); RC=$?
eq "an empty body ends the walk nonzero" "1" "$RC"
eq "...and emits nothing"                ""  "$OUT"

_fj() { printf '%s' 'not json at all'; }
OUT=$(forgejo_open_prs acme/x); RC=$?
eq "an unparseable body ends the walk nonzero" "1" "$RC"

# A server that keeps answering with a full page must hit the cap. The cap is
# lowered inside the substitution's subshell so the override can't leak.
_fj() { jq -nc '[range(50) | {number: ., head: {ref: "other/\(.)"}, body: "x"}]'; }
# shellcheck disable=SC2034  # read by forgejo_open_prs (lib/forgejo.sh)
OUT=$(FORGEJO_OPEN_PRS_MAX_PAGES=3; forgejo_open_prs acme/x); RC=$?
eq "an endless full-page server hits the page cap and returns nonzero" "1" "$RC"

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
# (lib/checkpoint.sh) applied to forgejo_prs_covering_issue's output -- the
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
eq "discovery loop filters via forgejo_prs_covering_issue" "true" \
  "$(grep -q 'forgejo_prs_covering_issue ' "$TICK" && echo true || echo false)"
eq "...against a listing hoisted OUT of the candidate loop (one fetch per repo)" "true" \
  "$(awk '/^  CANDIDATES=/,/^  while read -r candidate/' "$TICK" | grep -q 'forgejo_open_prs ' && echo true || echo false)"
eq "discovery gate counts non-WIP entries via checkpoint_count_non_wip" "true" \
  "$(grep -q 'checkpoint_count_non_wip ' "$TICK" && echo true || echo false)"
eq "the branch abort re-queries with forgejo_open_pr_covers_issue" "true" \
  "$(grep -A8 'STALE_BRANCHES=' "$TICK" | grep -q 'forgejo_open_pr_covers_issue ' && echo true || echo false)"
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

# ---------------------------------------------------------------------------
# Assignment as the primary claim lock (operator amendment to igor#496): the
# recovery sweep's own 3-way split, exercised with the exact shape
# forgejo_bot_prs_for_issue returns ({number, state, title, merged}) and the
# exact filter + checkpoint_count_non_wip call bin/tick.sh's recovery loop
# runs. Pure logic, no network.
# ---------------------------------------------------------------------------
echo "== recovery sweep: real (non-WIP) open PR -> in flight, hands off =="
recovery_split() {
  # Mirrors bin/tick.sh's recovery loop exactly: filter to open, then split
  # via checkpoint_count_non_wip. Echoes "total nonwip" for the caller to read.
  local history="$1" open total nonwip
  open=$(jq -c '[.[] | select(.state == "open")]' <<<"$history")
  total=$(jq 'length' <<<"$open")
  nonwip=$(checkpoint_count_non_wip "$open")
  printf '%s %s' "$total" "$nonwip"
}
READY_ONLY='[{"number":492,"state":"open","title":"fix: real work","merged":false}]'
eq "a real open PR -> nonwip=1 (hands off, no unassign)" "1 1" "$(recovery_split "$READY_ONLY")"

echo "== recovery sweep: WIP checkpoint draft only -> mid-resume crash, unassign for resume =="
WIP_ONLY=$(jq -n --arg wip "$CHECKPOINT_WIP_PREFIX" \
  '[{number: 490, state: "open", title: ($wip + "issue #490 checkpoint"), merged: false}]')
eq "a WIP-only open PR -> total=1, nonwip=0 (unassign so discovery can resume)" "1 0" "$(recovery_split "$WIP_ONLY")"

echo "== recovery sweep: no open PR at all -> true orphan, re-queue =="
NO_OPEN='[{"number":489,"state":"closed","title":"an earlier rejected attempt","merged":false}]'
eq "only closed history -> total=0 (orphan: comment + unassign + worktree cleanup)" "0 0" "$(recovery_split "$NO_OPEN")"
eq "no history at all -> total=0 (orphan)" "0 0" "$(recovery_split '[]')"

echo "== recovery sweep: rejected history alongside a live real PR -> still hands off =="
MIXED='[{"number":489,"state":"closed","title":"rejected attempt","merged":false},{"number":492,"state":"open","title":"fix: real work","merged":false}]'
eq "closed history + one real open PR -> nonwip=1 (hands off, not orphaned)" "1 1" "$(recovery_split "$MIXED")"

echo "== recovery sweep: tick.sh wires up the WIP-aware 3-way split (igor#496 amendment) =="
eq "recovery filters bot PR history down to open ones" "true" \
  "$(grep -q 'O_OPEN_PRS=\$(jq -c' "$TICK" && echo true || echo false)"
eq "recovery splits via checkpoint_count_non_wip, same helper discovery uses" "true" \
  "$(grep -q 'O_OPEN_NONWIP=\$(checkpoint_count_non_wip "\$O_OPEN_PRS")' "$TICK" && echo true || echo false)"
RECOVERY_START=$(grep -n 'log "recovery sweep' "$TICK" | head -1 | cut -d: -f1)
RECOVERY_END=$(awk -v start="$RECOVERY_START" 'NR>start && /^fi$/ {print NR; exit}' "$TICK")
RECOVERY_BLOCK=$(sed -n "${RECOVERY_START},${RECOVERY_END}p" "$TICK")
eq "a real open PR case does NOT call forgejo_unassign_all" "true" \
  "$(printf '%s\n' "$RECOVERY_BLOCK" | awk '/O_OPEN_NONWIP" -gt 0/,/continue/' | grep -q 'forgejo_unassign_all' && echo false || echo true)"
eq "the WIP-only case still calls forgejo_unassign_all (resume path preserved)" "true" \
  "$(printf '%s\n' "$RECOVERY_BLOCK" | awk '/O_OPEN_TOTAL" -gt 0/,/continue/' | grep -q 'forgejo_unassign_all "\$O_REPO" "\$O_NUM"' && echo true || echo false)"
eq "the orphan case still comments + unassigns + cleans up the worktree" "true" \
  "$(printf '%s\n' "$RECOVERY_BLOCK" | grep -q 'orphaned, re-queueing' && printf '%s\n' "$RECOVERY_BLOCK" | grep -q 'git worktree remove' && echo true || echo false)"

echo "== ship path: opening/finalizing a PR no longer clears the issue assignment (igor#496 amendment) =="
PR_OUTCOME_LINE=$(grep -n 'log "outcome: PR (' "$TICK" | head -1 | cut -d: -f1)
NOOP_ELSE_LINE=$(awk -v start="$PR_OUTCOME_LINE" 'NR>start && /^else$/ {print NR; exit}' "$TICK")
SHIP_BLOCK=$(sed -n "${PR_OUTCOME_LINE},${NOOP_ELSE_LINE}p" "$TICK")
eq "the ship path does not unassign FORGEJO_REPO/ISSUE_NUMBER after a successful PR" "true" \
  "$(printf '%s\n' "$SHIP_BLOCK" | grep -q 'forgejo_unassign_all "\$FORGEJO_REPO" "\$ISSUE_NUMBER"' && echo false || echo true)"
eq "...while the noop (0-commit) outcome still unassigns to return the issue to the pool" "true" \
  "$(sed -n "${NOOP_ELSE_LINE},\$p" "$TICK" | grep -q 'forgejo_unassign_all "\$FORGEJO_REPO" "\$ISSUE_NUMBER"' && echo true || echo false)"

echo "== rejected-PR strike: records the block in the BODY with an operator probe (igor#546) =="
# The strike used to comment the reason and nothing else. Two problems that
# fix together: a re-queued run is prompted from the issue BODY alone
# (igor#434), and lib/blockprobe.sh's sweep reads its probe from the body too
# -- so a comment-only strike is both invisible to the next run and
# permanently UNPROBED. `operator` is the right kind here and not a
# formality: "the agent opened N PRs and all were closed" is a human
# judgement call, so the sweep must never auto-requeue it.
# shellcheck source=../lib/blockprobe.sh
. "$HERE/../lib/blockprobe.sh"
STRIKE_START=$(grep -n 'rejected bot PRs, applying Status/Blocked' "$TICK" | head -1 | cut -d: -f1)
STRIKE_END=$(awk -v start="$STRIKE_START" 'NR>start && /^ *continue$/ {print NR; exit}' "$TICK")
STRIKE_BLOCK=$(sed -n "${STRIKE_START},${STRIKE_END}p" "$TICK")
eq "the strike writes the reason to the issue body, not only a comment" "true" \
  "$(printf '%s\n' "$STRIKE_BLOCK" | grep -q 'forgejo_append_issue_body "\$R_NAME" "\$C_NUM"' && echo true || echo false)"
eq "...and still comments it (the body append is best-effort, not a swap)" "true" \
  "$(printf '%s\n' "$STRIKE_BLOCK" | grep -q 'forgejo_comment "\$R_NAME" "\$C_NUM" "\$C_BLOCK_REASON"' && echo true || echo false)"
eq "body and comment carry the SAME reason text" "1" \
  "$(printf '%s\n' "$STRIKE_BLOCK" | grep -c 'C_BLOCK_REASON=')"
eq "a failed body append warns instead of aborting the strike" "true" \
  "$(printf '%s\n' "$STRIKE_BLOCK" | grep -q 'could not append the block reason' && echo true || echo false)"

# Cross-boundary check: run the probe literal tick.sh embeds through the
# consumer that has to read it back. A typo'd kind would silently degrade
# every strike to UNPROBED, and no structural grep would notice.
STRIKE_PROBE=$(printf '%s\n' "$STRIKE_BLOCK" | sed -n '/<!-- probe/,/-->/p' | sed 's/".*$//')
STRIKE_BODY=$(printf '## Blocked (2026-08-28 00:00Z)\n\nsome reason\n\n%s\n' "$STRIKE_PROBE")
eq "blockprobe parses the strike's probe as a recognized kind" "operator" \
  "$(blockprobe_parse_kind "$STRIKE_BODY")"
eq "...which is in the sweep's closed vocabulary" "true" \
  "$(case " $BLOCKPROBE_KINDS " in *" operator "*) echo true ;; *) echo false ;; esac)"

if [ "$FAIL" -eq 0 ]; then echo "test-claim-guard: all checks passed"; exit 0; fi
echo "test-claim-guard: $FAIL check(s) FAILED"
exit 1
