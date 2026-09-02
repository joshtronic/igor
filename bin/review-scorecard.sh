#!/usr/bin/env bash
# review-scorecard.sh -- measure the review loop, with no model in the loop
# (igor#582). Built entirely on lib/review-corpus.sh: fetches each repo's
# merged PRs and their comment threads, parses each into a trajectory, and
# reports aggregate figures. Read-only and non-authoritative -- a report the
# operator reads, not a gate, and it never blocks or changes a merge.
#
# Usage:
#   bin/review-scorecard.sh <owner/repo> [<owner/repo> ...] [--limit N]
#
#   --limit N   only the N most recently merged PRs per repo (default: all,
#               bounded by FORGEJO_CLOSED_PULLS_MAX_PAGES)

set -uo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/review-corpus.sh
. "$AGENT_HOME/lib/review-corpus.sh"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

REPOS=()
LIMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      LIMIT="${2:-}"
      case "$LIMIT" in '' | *[!0-9]*) echo "--limit requires a positive integer" >&2; usage 2 ;; esac
      shift 2
      ;;
    -h | --help) usage 0 ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) REPOS+=("$1"); shift ;;
  esac
done
[ "${#REPOS[@]}" -gt 0 ] || { echo "usage: review-scorecard.sh <owner/repo> [...] [--limit N]" >&2; exit 2; }

RECORDS_FILE=$(mktemp)
trap 'rm -f "$RECORDS_FILE"' EXIT

TOTAL_MERGED=0
for repo in "${REPOS[@]}"; do
  echo "== ${repo}: listing merged PRs ==" >&2
  closed=$(forgejo_closed_pulls_all "$repo") || {
    echo "warning: could not list closed PRs for ${repo} (network/token?) -- skipping" >&2
    continue
  }
  merged=$(jq -c '[.[] | select(.merged == true)] | sort_by(.number)' <<<"$closed")
  if [ -n "$LIMIT" ]; then
    merged=$(jq -c --argjson n "$LIMIT" '.[-$n:]' <<<"$merged")
  fi
  count=$(jq 'length' <<<"$merged")
  echo "   ${count} merged PR(s)" >&2
  TOTAL_MERGED=$((TOTAL_MERGED + count))

  i=0
  while [ "$i" -lt "$count" ]; do
    number=$(jq -r ".[$i].number" <<<"$merged")
    comments=$(forgejo_pr_comments "$repo" "$number" 2>/dev/null) || comments='[]'
    record=$(review_corpus_trajectory "$comments" true)
    if [ "$record" != "{}" ]; then
      jq -c --arg repo "$repo" --argjson number "$number" '. + {repo: $repo, number: $number}' \
        <<<"$record" >>"$RECORDS_FILE"
    fi
    i=$((i + 1))
  done
done

SCORED=$(wc -l <"$RECORDS_FILE" | tr -d ' ')

if [ "$SCORED" -eq 0 ]; then
  echo "no PRs with automated review artifacts found across: ${REPOS[*]}"
  exit 0
fi

# All aggregation happens here, in one jq pass over the slurped records --
# the shell above is pure plumbing (fetch, filter, append).
jq -s -r --argjson total_merged "$TOTAL_MERGED" '
  def pct($n; $d): if $d == 0 then 0 else (($n * 1000 / $d) | round) / 10 end;

  . as $records
  | ($records | length) as $scored
  | ($records | map(.verdicts[]) ) as $verdicts
  | ($verdicts | length) as $vcount
  | (["APPROVE","REQUEST_CHANGES","COMMENT"] | map(. as $v | {verdict: $v, n: ($verdicts | map(select(. == $v)) | length)})) as $mix
  | ($records | map(.review_rounds) | sort) as $rounds
  | ($rounds | length) as $rn
  | ( if $rn == 0 then 0
      elif ($rn % 2) == 1 then $rounds[($rn - 1) / 2]
      else (($rounds[($rn / 2) - 1] + $rounds[$rn / 2]) / 2)
      end ) as $median_rounds
  | ((($rounds | add // 0) * 10 / (if $rn == 0 then 1 else $rn end) | round) / 10) as $mean_rounds
  | ($records | map(.rework_rounds) | add // 0) as $total_rework_rounds
  | ($records | map(.dismissal_count) | add // 0) as $total_dismissals
  | ($records | map(select(.dismissal_count > 0)) | length) as $prs_with_dismissal
  | ($records | map(select(.dismissed_then_approved)) | length) as $dismissed_then_approved
  | ($records | map(select(.finding_reraised)) | length) as $finding_reraised
  | (
      "== review scorecard =="
      , "PRs scored (had automated review artifacts): \($scored) of \($total_merged) merged"
      , ""
      , "Review-verdict artifacts: \($vcount)"
      , ($mix[] | "  \(.verdict): \(.n) (\(pct(.n; $vcount))%)")
      , ""
      , "Review rounds to merge: mean \($mean_rounds), median \($median_rounds)"
      , "Rework rounds (commits pushed after a review): \($total_rework_rounds)"
      , ""
      , "Dismissal comments: \($total_dismissals)"
      , "PRs with at least one dismissal: \($prs_with_dismissal) of \($scored) (\(pct($prs_with_dismissal; $scored))%)"
      , "Dismissed-then-approved PRs: \($dismissed_then_approved)"
      , "PRs where a dismissed finding was raised again: \($finding_reraised)"
    )
' "$RECORDS_FILE"
