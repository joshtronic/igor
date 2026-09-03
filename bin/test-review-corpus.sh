#!/usr/bin/env bash
# Unit tests for lib/review-corpus.sh -- parsing a PR's comment thread into a
# review-loop trajectory (igor#582), with no model in the loop.
#
# Eight behaviors are asserted, each picked because a parser that fakes it (a
# constant, a string-contains check with no anchoring) would still pass a
# lazier test:
#   1. a bare APPROVE trajectory
#   2. REQUEST_CHANGES -> rework -> APPROVE, in order
#   3. dismissal-then-APPROVE vs the identical trajectory minus the dismissal
#      (the two fixtures differ in exactly one comment)
#   4. a dismissed finding raised again vs one that was accepted
#   5. a header quoted inside a fenced code block must NOT count as an artifact
#   6. a human-only PR (zero automated artifacts) returns an empty record
#   7. the scorecard aggregation over a set of records -- verdict mix and
#      percentages, both median branches, the zero-record path, and the
#      unfetchable-PR caveat
#   8. the file survives being sourced under `set -e`
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-corpus: jq absent -- skipping"; exit 0; }

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/review-corpus.sh
. "$HERE/lib/review-corpus.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

# The three header lines the harness actually posts, pulled straight from
# source. Every fixture below is BUILT from these rather than retyping them,
# so an emoji/ZWJ/em-dash drift between what production posts and what the
# parser matches fails here instead of passing on fixtures that drifted along
# with the parser. The eq assertions pin the extraction itself: a grep that
# stops matching, or a sed that mangles the line, fails on this line rather
# than cascading into every later fixture as an unexplained mismatch.
REAL_REVIEW_HEADER_LINE=$(grep -n 'Review —.*automated' "$HERE/bin/tick.sh" | head -1 \
  | sed -E 's/^[0-9]+: *comment="//; s/\\`/`/g')
REAL_REWORK_HEADER_LINE=$(grep -n 'Rework —.*round.*automated' "$HERE/bin/tick.sh" | head -1 \
  | sed -E 's/^[0-9]+:"//')
REAL_DISMISS_HEADER_LINE=$(grep -n 'findings dismissed _(automated)_' "$HERE/lib/adjudication.sh" | head -1 \
  | sed -E 's/^[0-9]+: *head="//; s/"$//')

echo "== fidelity: fixtures use the harness's own header bytes =="
eq "review header extracted" '### 🤖 Review — `${verdict}` _(automated)_' "$REAL_REVIEW_HEADER_LINE"
eq "rework header extracted" '### 🔧 Rework — round ${PR_REWORK_ROUND} _(automated)_' "$REAL_REWORK_HEADER_LINE"
eq "dismissal header extracted" '### 🧑‍⚖️ Rework — findings dismissed _(automated)_' "$REAL_DISMISS_HEADER_LINE"

# --- fixture builders --------------------------------------------------

mk_comment() {  # mk_comment <created_at> <body>
  jq -n -c --arg at "$1" --arg body "$2" '{user: {login: "igor"}, created_at: $at, body: $body}'
}

# The harness's header lines carry the shell placeholder they interpolate at
# post time; the fixtures substitute it the same way production does.
review_header()  { printf '%s' "${REAL_REVIEW_HEADER_LINE/'${verdict}'/$1}"; }
rework_header()  { printf '%s' "${REAL_REWORK_HEADER_LINE/'${PR_REWORK_ROUND}'/$1}"; }

mk_review() {  # mk_review <created_at> <verdict> <sha> <ci> <text>
  local body
  body=$(printf '%s\n\nCI for `%s`: **%s**\n\n%s\n\n---\n<sub>note</sub>\n<!-- review sha=%s verdict=%s ci=%s -->' \
    "$(review_header "$2")" "$3" "$4" "$5" "$3" "$2" "$4")
  mk_comment "$1" "$body"
}

mk_rework() {  # mk_rework <created_at> <round>
  local body
  body=$(printf '%s\n\nAddressed the review on `model` at **effort medium** — 1 new commit(s).\n\n<!-- audit:rework round=%s effort=medium -->' \
    "$(rework_header "$2")" "$2")
  mk_comment "$1" "$body"
}

mk_dismissal() {  # mk_dismissal <created_at> <text> <converged: true|false>
  local body tail_
  if [ "$3" = "true" ]; then
    tail_="No code changes: the agent judged every point raised not to need one. Nothing further happens on its own, so it is yours -- either the reasoning holds and you merge, or it does not and you say so."
  else
    tail_="The rest of the findings were addressed in the commits on this branch. The reviewer will re-review the new head."
  fi
  body=$(printf '%s\n\n%s\n\n---\n\n%s\n<!-- adjudication:dismissed -->' \
    "$REAL_DISMISS_HEADER_LINE" "$2" "$tail_")
  mk_comment "$1" "$body"
}

arr() { jq -s -c '.' <<<"$(printf '%s\n' "$@")"; }  # arr <comment-json>... -> JSON array

# --- 1. a bare APPROVE, no rework ---------------------------------------

echo "== single APPROVE, no rework =="
C1=$(mk_review "2026-01-01T00:00:00Z" APPROVE abcd1234 success "Looks good.")
R1=$(review_corpus_trajectory "$(arr "$C1")" true)
eq "review_rounds" "1" "$(jq -r '.review_rounds' <<<"$R1")"
eq "rework_rounds" "0" "$(jq -r '.rework_rounds' <<<"$R1")"
eq "dismissal_count" "0" "$(jq -r '.dismissal_count' <<<"$R1")"
eq "terminal_verdict" "APPROVE" "$(jq -r '.terminal_verdict' <<<"$R1")"
eq "verdicts" '["APPROVE"]' "$(jq -c '.verdicts' <<<"$R1")"

# --- 2. REQUEST_CHANGES -> rework -> APPROVE ----------------------------

echo "== REQUEST_CHANGES -> rework -> APPROVE =="
C1=$(mk_review "2026-01-01T00:00:00Z" REQUEST_CHANGES sha0001 success "Fix the null check.")
C2=$(mk_rework "2026-01-01T01:00:00Z" 1)
C3=$(mk_review "2026-01-01T02:00:00Z" APPROVE sha0002 success "LGTM now.")
R2=$(review_corpus_trajectory "$(arr "$C1" "$C2" "$C3")" true)
eq "review_rounds" "2" "$(jq -r '.review_rounds' <<<"$R2")"
eq "rework_rounds" "1" "$(jq -r '.rework_rounds' <<<"$R2")"
eq "verdicts in order" '["REQUEST_CHANGES","APPROVE"]' "$(jq -c '.verdicts' <<<"$R2")"
eq "terminal_verdict" "APPROVE" "$(jq -r '.terminal_verdict' <<<"$R2")"

# --- 3. dismissal-then-APPROVE vs the same trajectory minus the dismissal --
# The two fixtures below differ in exactly ONE comment (the dismissal) so the
# assertion tests dismissal detection alone, not some other structural change.

echo "== dismissed-then-approved: one comment is the whole difference =="
D_RC=$(mk_review "2026-01-01T00:00:00Z" REQUEST_CHANGES shaA success "Nit: rename the variable.")
D_RW=$(mk_rework "2026-01-01T01:00:00Z" 1)
D_DISMISS=$(mk_dismissal "2026-01-01T01:30:00Z" "Dismissed: the variable name already matches the file's convention." false)
D_APPROVE=$(mk_review "2026-01-01T02:00:00Z" APPROVE shaB success "LGTM.")

WITH=$(arr "$D_RC" "$D_RW" "$D_DISMISS" "$D_APPROVE")
WITHOUT=$(arr "$D_RC" "$D_RW" "$D_APPROVE")

RWITH=$(review_corpus_trajectory "$WITH" true)
RWITHOUT=$(review_corpus_trajectory "$WITHOUT" true)

eq "with dismissal: dismissal_count 1" "1" "$(jq -r '.dismissal_count' <<<"$RWITH")"
eq "with dismissal: dismissed_then_approved" "true" "$(jq -r '.dismissed_then_approved' <<<"$RWITH")"
eq "with dismissal: round is 1 (after the 1st review)" "1" "$(jq -r '.dismissals[0].round' <<<"$RWITH")"
eq "with dismissal: dismissal followed_by_approve" "true" "$(jq -r '.dismissals[0].followed_by_approve' <<<"$RWITH")"
eq "without dismissal: dismissal_count 0" "0" "$(jq -r '.dismissal_count' <<<"$RWITHOUT")"
eq "without dismissal: dismissed_then_approved false" "false" "$(jq -r '.dismissed_then_approved' <<<"$RWITHOUT")"

# --- 4. a dismissed finding raised again, vs one that was accepted --------

echo "== a dismissed finding raised again is distinguished from one accepted =="
E_RC1=$(mk_review "2026-01-01T00:00:00Z" REQUEST_CHANGES shaA success "- Missing null check on line 42 in foo()")
E_RW1=$(mk_rework "2026-01-01T01:00:00Z" 1)
E_DISMISS=$(mk_dismissal "2026-01-01T01:30:00Z" \
  "$(printf '%s\n%s' "- Missing null check on line 42 in foo()" "Dismissed -- the caller already guards against null.")" false)
E_RC2_RERAISED=$(mk_review "2026-01-01T02:00:00Z" REQUEST_CHANGES shaB success "- Missing null check on line 42 in foo()")
E_RC2_ACCEPTED=$(mk_review "2026-01-01T02:00:00Z" APPROVE shaB success "LGTM, thanks for clarifying.")

RERAISED=$(review_corpus_trajectory "$(arr "$E_RC1" "$E_RW1" "$E_DISMISS" "$E_RC2_RERAISED")" true)
ACCEPTED=$(review_corpus_trajectory "$(arr "$E_RC1" "$E_RW1" "$E_DISMISS" "$E_RC2_ACCEPTED")" true)

eq "raised again: finding_reraised" "true" "$(jq -r '.finding_reraised' <<<"$RERAISED")"
eq "raised again: dismissals[0].reraised" "true" "$(jq -r '.dismissals[0].reraised' <<<"$RERAISED")"
eq "accepted: finding_reraised" "false" "$(jq -r '.finding_reraised' <<<"$ACCEPTED")"
eq "accepted: dismissals[0].reraised" "false" "$(jq -r '.dismissals[0].reraised' <<<"$ACCEPTED")"

# --- 5. a header quoted in a fenced code block is not an artifact ----------

echo "== a header quoted inside a fenced code block is not counted =="
# The quoted header is the real one, so the anchoring is what rejects this --
# not bytes the parser would have failed to match wherever they appeared.
FENCED_BODY=$(printf 'For reference, this is what the header looks like:\n\n```\n%s\n```\n\nJust an example, not an actual review.' \
  "$(review_header APPROVE)")
F1=$(mk_comment "2026-01-01T00:00:00Z" "$FENCED_BODY")
R5=$(review_corpus_trajectory "$(arr "$F1")" true)
eq "fenced header -> empty record, not counted as APPROVE" "{}" "$R5"

# --- 6. a human-only PR (zero automated artifacts) --------------------------

echo "== human-only PR returns an empty record =="
H1=$(mk_comment "2026-01-01T00:00:00Z" "Thanks for the PR, taking a look now.")
H2=$(mk_comment "2026-01-01T01:00:00Z" "LGTM, merging.")
R6=$(review_corpus_trajectory "$(arr "$H1" "$H2")" true)
eq "human-only -> empty record" "{}" "$R6"
eq "no comments at all -> empty record" "{}" "$(review_corpus_trajectory '[]' true)"

# --- merged passthrough, and reading comments from stdin -------------------

echo "== merged flag passthrough and stdin input =="
eq "merged=true" "true" "$(jq -r '.merged' <<<"$(review_corpus_trajectory "$(arr "$C1")" true)")"
eq "merged=false" "false" "$(jq -r '.merged' <<<"$(review_corpus_trajectory "$(arr "$C1")" false)")"
eq "merged omitted -> null (unknown)" "null" "$(jq -r '.merged' <<<"$(review_corpus_trajectory "$(arr "$C1")")")"
eq "comments read from stdin when no argument given" "1" \
  "$(arr "$C1" | review_corpus_trajectory | jq -r '.review_rounds')"

# --- 7. the scorecard aggregation -----------------------------------------
# Every number bin/review-scorecard.sh prints comes out of this function, so
# it is asserted here over synthetic records rather than only being reachable
# by running the whole script against a live forge.

echo "== scorecard aggregation over synthetic records =="

RECORDS=$(mktemp); trap 'rm -f "$RECORDS"' EXIT

rec() {  # rec <verdicts-json> <rework> <dismissals> <then_approved> <reraised>
  jq -n -c --argjson v "$1" --argjson rw "$2" --argjson dc "$3" \
    --argjson ta "$4" --argjson rr "$5" \
    '{verdicts: $v, review_rounds: ($v | length), rework_rounds: $rw,
      dismissal_count: $dc, dismissed_then_approved: $ta, finding_reraised: $rr}'
}

# 4 records, 10 verdicts: 5 APPROVE / 4 REQUEST_CHANGES / 1 COMMENT.
# review_rounds are 1,2,3,4 -> even count, median (2+3)/2 = 2.5, mean 2.5.
# The two middle values differ deliberately: with an even count where they are
# equal, the odd branch's `rounds[($rn - 1) / 2]` truncates to the same answer
# and the assertion would pass on either branch.
{
  rec '["APPROVE"]'                                            0 0 false false
  rec '["REQUEST_CHANGES","APPROVE"]'                          1 0 false false
  rec '["REQUEST_CHANGES","COMMENT","APPROVE"]'                1 1 true  false
  rec '["REQUEST_CHANGES","REQUEST_CHANGES","APPROVE","APPROVE"]' 2 2 false true
} >"$RECORDS"

S=$(review_corpus_scorecard "$RECORDS" 10)
line() { grep -F "$1" <<<"$S" | head -1; }

eq "scored/merged denominators come from the caller" \
  "PRs scored (had automated review artifacts): 4 of 10 merged" "$(line 'PRs scored')"
eq "verdict artifacts are counted across all records" \
  "Review-verdict artifacts: 10" "$(line 'Review-verdict artifacts')"
eq "APPROVE mix + percentage"         "  APPROVE: 5 (50%)"        "$(line '  APPROVE:')"
eq "REQUEST_CHANGES mix + percentage" "  REQUEST_CHANGES: 4 (40%)" "$(line '  REQUEST_CHANGES:')"
eq "COMMENT mix + percentage"         "  COMMENT: 1 (10%)"        "$(line '  COMMENT:')"
eq "even record count takes the two-middle-values median branch" \
  "Review rounds to merge: mean 2.5, median 2.5" "$(line 'Review rounds to merge')"
eq "rework rounds are summed" "Rework rounds (commits pushed after a review): 4" "$(line 'Rework rounds')"
eq "dismissal comments are summed" "Dismissal comments: 3" "$(line 'Dismissal comments:')"
eq "PRs with a dismissal counts PRs, not dismissals" \
  "PRs with at least one dismissal: 2 of 4 (50%)" "$(line 'PRs with at least one')"
eq "dismissed-then-approved" "Dismissed-then-approved PRs: 1" "$(line 'Dismissed-then-approved')"
eq "reraised findings" "PRs where a dismissed finding reappeared verbatim in a later review: 1" \
  "$(line 'reappeared verbatim')"

# The two lines under that count are a caveat about the METRIC, so they have to
# read the same whether the count is 1 or 0. The first version asserted "this
# reads 0 across the live corpus" unconditionally and so contradicted the line
# directly above it on exactly this fixture.
caveat() { grep -A2 -F 'reappeared verbatim' <<<"$S" | tail -2; }
CAVEAT_ON_HIT=$(caveat)
case "$CAVEAT_ON_HIT" in
  *"lower bound"*) ok "the reraised count carries a lower-bound caveat" ;;
  *) bad "the reraised count carries a lower-bound caveat: got [$CAVEAT_ON_HIT]" ;;
esac

# An odd count takes the other median branch: rounds 1,2,6 -> median 2, mean 3.
{
  rec '["APPROVE"]'                                                    0 0 false false
  rec '["REQUEST_CHANGES","APPROVE"]'                                  1 0 false false
  rec '["COMMENT","COMMENT","COMMENT","COMMENT","COMMENT","APPROVE"]'  5 0 false false
} >"$RECORDS"
S=$(review_corpus_scorecard "$RECORDS" 3)
eq "odd record count takes the middle-value median branch" \
  "Review rounds to merge: mean 3, median 2" "$(line 'Review rounds to merge')"
eq "no record reraises a finding here" \
  "PRs where a dismissed finding reappeared verbatim in a later review: 0" "$(line 'reappeared verbatim')"
eq "the reraised caveat says the same thing at 0 as it does at 1" "$CAVEAT_ON_HIT" "$(caveat)"

# The zero-record path: the script short-circuits before calling this, but the
# aggregation must not divide by zero if it is ever reached directly.
: >"$RECORDS"
S=$(review_corpus_scorecard "$RECORDS" 0)
eq "zero records: no division by zero, scored 0" \
  "PRs scored (had automated review artifacts): 0 of 0 merged" "$(line 'PRs scored')"
eq "zero records: percentages are 0, not null or nan" "  APPROVE: 0 (0%)" "$(line '  APPROVE:')"
eq "zero records: mean and median are 0" \
  "Review rounds to merge: mean 0, median 0" "$(line 'Review rounds to merge')"

# A merged PR whose comments could not be fetched is NOT a PR with no artifacts:
# it shrinks the scored count and the denominator of every percentage below it.
# The count rides in the report itself rather than only on stderr, so a run
# redirected to a file still carries the caveat on its own figures.
{ rec '["APPROVE"]' 0 0 false false; } >"$RECORDS"
S=$(review_corpus_scorecard "$RECORDS" 3 2)
eq "unfetchable PRs are reported next to the scored count" \
  "2 merged PR(s) excluded: their comments could not be fetched" "$(line 'could not be fetched')"
S=$(review_corpus_scorecard "$RECORDS" 3 0)
eq "no unfetchable PRs -> no excluded line at all" "" "$(line 'could not be fetched')"
S=$(review_corpus_scorecard "$RECORDS" 3)
eq "the excluded count defaults to 0 when the caller omits it" "" "$(line 'could not be fetched')"

# --- 8. sourcing under set -e ---------------------------------------------
# `read -d ''` returns nonzero at EOF-without-a-NUL, which is every heredoc, so
# an unguarded `read -r -d '' VAR <<EOF` at file scope exits any shell that
# sources this file under `set -e`. Both current callers use `set -uo pipefail`
# and never noticed; the next one would have.

echo "== sourcing under set -e =="
if bash -c 'set -euo pipefail; . "$1/lib/review-corpus.sh"; [ -n "$REVIEW_CORPUS_JQ" ] && [ -n "$REVIEW_SCORECARD_JQ" ]' _ "$HERE"; then
  ok "sourced under set -e with both jq programs set"
else
  bad "sourcing under set -e aborted or left a jq program empty"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-corpus: all checks passed"
else
  echo "test-review-corpus: $FAIL FAILED"
  exit 1
fi
