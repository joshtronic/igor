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
#
# --limit trims the REPORT, not the fetch: every run walks the repo's whole
# closed-PR listing first and slices afterwards. So `--limit 5` costs the same
# API calls as no limit, and a repo past FORGEJO_CLOSED_PULLS_MAX_PAGES x 50
# closed PRs is skipped even for a small limit (raise that env var to cover it).
# forgejo_closed_pulls_recent would make the small case cheap, but it sorts by
# recentupdate over closed PRs, merged and rejected alike -- so "the N most
# recently merged" would become "however many of the N most recently touched
# closed PRs happen to have merged", a denominator that silently shrinks. This
# tool exists to keep these figures honest, so it pays for the exact ordering.

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
      # 0 has to be rejected explicitly: it passes *[!0-9]* and then `.[-0:]`
      # is `.[0:]`, i.e. silently "all" -- the opposite of a limit.
      case "$LIMIT" in '' | *[!0-9]* | 0) echo "--limit requires a positive integer" >&2; usage 2 ;; esac
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
    case $? in
      2) echo "warning: ${repo} has more than $((FORGEJO_CLOSED_PULLS_MAX_PAGES * 50)) closed PRs (FORGEJO_CLOSED_PULLS_MAX_PAGES) -- skipping" >&2 ;;
      *) echo "warning: could not list closed PRs for ${repo} (network/token?) -- skipping" >&2 ;;
    esac
    continue
  }
  # Sorted by merge time, not number: --limit says "most recently merged", and
  # a PR opened earlier can merge later.
  merged=$(jq -c '[.[] | select(.merged == true)] | sort_by(.merged_at // "")' <<<"$closed")
  if [ -n "$LIMIT" ]; then
    merged=$(jq -c --argjson n "$LIMIT" '.[-$n:]' <<<"$merged")
  fi
  count=$(jq 'length' <<<"$merged")
  echo "   ${count} merged PR(s)" >&2
  TOTAL_MERGED=$((TOTAL_MERGED + count))

  i=0
  while [ "$i" -lt "$count" ]; do
    number=$(jq -r ".[$i].number" <<<"$merged")
    comments=$(forgejo_pr_comments "$repo" "$number" 2>/dev/null) || comments=''
    # An empty-but-successful fetch (204, a truncated body) is not a failure the
    # `||` above catches, and review_corpus_trajectory reads stdin when handed
    # an empty string -- which here would block on the terminal.
    [ -n "$comments" ] || comments='[]'
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

# All aggregation happens in lib/review-corpus.sh, in one jq pass over the
# slurped records -- this script is pure plumbing (fetch, filter, append).
review_corpus_scorecard "$RECORDS_FILE" "$TOTAL_MERGED"
