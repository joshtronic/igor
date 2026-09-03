#!/usr/bin/env bash
# test-review-scorecard.sh -- end-to-end tests for bin/review-scorecard.sh over a
# doubled forge (igor#582). The parser and the aggregation have their own units
# in bin/test-review-corpus.sh; what is only reachable here is the script's
# plumbing, and specifically its accounting for a PR whose comment thread cannot
# be fetched.
#
# That case is worth its own test because its failure mode is silence: handing
# the parser an empty array on a failed fetch scores the PR as a human-only
# thread, which drops it from the scored count and from the denominator of every
# percentage -- a report quietly reading low with nothing on the page saying so.
#
# `curl` is doubled rather than `_fj`, because the script under test sources
# lib/forgejo.sh itself and would clobber an `_fj` defined out here; an exported
# function is inherited by the child bash instead.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-scorecard: jq absent -- skipping"; exit 0; }

HERE=$(cd "$(dirname "$0")/.." && pwd)

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

# The review header as production posts it, so a fixture comment is recognized
# for the same reason a real one is (see bin/test-review-corpus.sh).
REVIEW_HEADER=$(grep -n 'Review —.*automated' "$HERE/bin/tick.sh" | head -1 \
  | sed -E 's/^[0-9]+: *comment="//; s/\\`/`/g')
REVIEW_HEADER=${REVIEW_HEADER/'${verdict}'/APPROVE}

FIXTURE_PULLS=$(jq -n -c '[{number: 1, merged: true, merged_at: "2026-01-01T00:00:00Z"},
                           {number: 2, merged: true, merged_at: "2026-01-02T00:00:00Z"}]')
FIXTURE_COMMENTS=$(jq -n -c --arg h "$REVIEW_HEADER" \
  '[{user: {login: "igor"}, created_at: "2026-01-01T00:00:00Z",
     body: ($h + "\n\nCI for `abc1234`: **success**\n\nLooks good.")}]')

# FAIL_PRS is the space-separated list of PR numbers whose comment fetch should
# answer HTTP >= 400. `-sf` makes that curl exit 22, which _fj deliberately does
# not retry -- so the failure path costs no sleeps.
curl() {
  local arg url='' n
  for arg in "$@"; do case "$arg" in http*) url="$arg" ;; esac; done
  case "$url" in
    *"/pulls?state=closed"*"page=1"*) printf '%s' "$FIXTURE_PULLS" ;;
    *"/pulls?state=closed"*) printf '%s' '[]' ;;
    *"/comments"*)
      n=${url##*/issues/}; n=${n%%/comments*}
      case " ${FAIL_PRS:-} " in *" $n "*) return 22 ;; esac
      printf '%s' "$FIXTURE_COMMENTS" ;;
    *) return 22 ;;
  esac
}
export -f curl
export FIXTURE_PULLS FIXTURE_COMMENTS
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"

echo "== both threads readable: every merged PR is scored =="
export FAIL_PRS=""
OUT=$("$HERE/bin/review-scorecard.sh" acme/x 2>/dev/null)
eq "both PRs scored" "PRs scored (had automated review artifacts): 2 of 2 merged" \
  "$(grep -F 'PRs scored' <<<"$OUT")"
eq "nothing excluded, so no excluded line" "" "$(grep -F 'could not be fetched' <<<"$OUT")"

echo "== one thread unreadable: excluded and said so, not silently dropped =="
ERRFILE=$(mktemp); trap 'rm -f "$ERRFILE"' EXIT
export FAIL_PRS="2"
OUT=$("$HERE/bin/review-scorecard.sh" acme/x 2>"$ERRFILE")
ERR=$(cat "$ERRFILE")

eq "the unreadable PR stays in the merged denominator" \
  "PRs scored (had automated review artifacts): 1 of 2 merged" "$(grep -F 'PRs scored' <<<"$OUT")"
eq "the report itself carries the exclusion, not just stderr" \
  "1 merged PR(s) excluded: their comments could not be fetched" \
  "$(grep -F 'could not be fetched' <<<"$OUT")"
eq "stderr names the PR that could not be read" \
  "warning: could not fetch comments for acme/x#2 -- excluded" \
  "$(grep -F 'could not fetch comments' <<<"$ERR")"

# The whole point: an unreadable thread must not be scored as one with no
# artifacts. Both would be absent from the records file, so the count is the
# only thing telling them apart.
eq "it is not counted as a PR that merely had no artifacts" "1" \
  "$(grep -cF 'could not be fetched' <<<"$OUT")"

echo "== every thread unreadable: the empty report still explains itself =="
export FAIL_PRS="1 2"
OUT=$("$HERE/bin/review-scorecard.sh" acme/x 2>/dev/null)
eq "the no-artifacts message is qualified by the fetch failures" \
  "(2 merged PR(s) excluded: their comments could not be fetched)" \
  "$(grep -F 'could not be fetched' <<<"$OUT")"

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-scorecard: all checks passed"
else
  echo "test-review-scorecard: $FAIL FAILED"
  exit 1
fi
