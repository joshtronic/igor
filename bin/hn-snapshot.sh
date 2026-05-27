#!/usr/bin/env bash
# hn-snapshot.sh -- ingest HN front page into brain's HN ledger.
#
# Around-the-clock snapshot of HN's top 30 stories. No Claude, no
# article fetching, no destination-ledger updates -- just keeps
# brain/memories/reading/sources/news.ycombinator.com.md fresh so
# discretionary-reading ticks have a rich backlog to pick from.
#
# Format matches what bin/discretionary-read.sh writes for HN
# entries: `- [ ] URL -- hn-rank N -- hn-points M -- hn-date
# YYYY-MM-DD`. The two scripts duplicate the ledger format
# (intentional minimal duplication; cleaner-but-bigger lib
# extraction can come later if more shared logic surfaces).
# Updates use min-rank-wins and max-points-wins, matching
# ledger_update_rank / ledger_update_points in discretionary-read.sh.
#
# tick.sh calls this with a 1-hour cooldown gate so it runs at most
# 24 times a day regardless of how many ticks fire.
#
# Usage:
#   bin/hn-snapshot.sh <brain-path> <output-body-file>
#
# Exit codes:
#   0  success (ingest completed; body summary written)
#   1  bad args
#   2  HN API unreachable / empty response

set -uo pipefail

BRAIN_PATH="${1:-}"
BODY_OUT="${2:-}"
if [ -z "$BRAIN_PATH" ] || [ ! -d "$BRAIN_PATH" ] || [ -z "$BODY_OUT" ]; then
  echo "usage: hn-snapshot.sh <brain-path> <output-body-file>" >&2
  exit 1
fi

UA='Mozilla/5.0 (compatible; agent/hn-snapshot)'
LEDGER="$BRAIN_PATH/memories/reading/sources/news.ycombinator.com.md"

# Convert Unix epoch to YYYY-MM-DD. GNU's `date -d @N` first
# (Debian/Linux production), BSD's `date -r N` fallback (local dev).
epoch_to_date() {
  local epoch="$1"
  [ -z "$epoch" ] || [ "$epoch" = "0" ] && return 0
  date -d "@$epoch" +%Y-%m-%d 2>/dev/null \
    || date -r "$epoch" +%Y-%m-%d 2>/dev/null \
    || true
}

# Ensure the ledger exists with the minimal header that
# discretionary-read.sh expects.
ensure_ledger() {
  [ -f "$LEDGER" ] && return 0
  mkdir -p "$(dirname "$LEDGER")"
  cat > "$LEDGER" <<HDR
# Posts seen from news.ycombinator.com

Source: https://news.ycombinator.com
Discovery: pending

## Index
HDR
}

# Is URL already in the ledger? Returns 0 if yes, 1 if no.
url_present() {
  local url="$1"
  awk -v url="$url" '
    /^- \[[ x]\] / {
      line = $0
      sub(/^- \[[ x]\] /, "", line)
      sub(/ .*$/, "", line)
      if (line == url) { found = 1; exit }
    }
    END { exit !found }
  ' "$LEDGER"
}

# Upsert: append URL if not present; otherwise update rank (min)
# and points (max) in-place on the existing line.
upsert_url() {
  local url="$1" rank="$2" points="$3" hn_date="$4"

  if url_present "$url"; then
    local tmp; tmp=$(mktemp)
    awk -v url="$url" -v rank="$rank" -v points="$points" '
      /^- \[[ x]\] / {
        line = $0
        first = line
        sub(/^- \[[ x]\] /, "", first)
        sub(/ .*$/, "", first)
        if (first == url) {
          # rank: keep min (highest front-page position observed)
          if (match(line, /hn-rank [0-9]+/)) {
            cur = substr(line, RSTART + 8, RLENGTH - 8) + 0
            if (rank + 0 < cur) sub(/hn-rank [0-9]+/, "hn-rank " rank, line)
          } else {
            line = line " -- hn-rank " rank
          }
          # points: keep max (peak upvotes observed)
          if (match(line, /hn-points [0-9]+/)) {
            cur = substr(line, RSTART + 10, RLENGTH - 10) + 0
            if (points + 0 > cur) sub(/hn-points [0-9]+/, "hn-points " points, line)
          } else {
            line = line " -- hn-points " points
          }
          print line
          next
        }
      }
      { print }
    ' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
    return 1  # signal "updated existing"
  fi

  # New URL: append. Insert blank line before first list item.
  local annotation="hn-rank $rank -- hn-points $points"
  [ -n "$hn_date" ] && annotation="$annotation -- hn-date $hn_date"
  if ! grep -qE '^- \[' "$LEDGER" 2>/dev/null; then
    printf '\n' >> "$LEDGER"
  fi
  printf -- '- [ ] %s -- %s\n' "$url" "$annotation" >> "$LEDGER"
  return 0  # signal "new"
}

# Fetch HN front page via Algolia. Yields one row per URL:
#   <rank>|<points>|<created_at_epoch>|<url>
# rank is the row's position in Algolia's front_page-tagged results,
# which is HN front-page rank.
fetch_hn() {
  local api='https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30'
  curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$api" 2>/dev/null \
    | jq -r '.hits[]? | select(.url != null) | "\(.points // 0)|\(.created_at_i // 0)|\(.url)"' \
    | awk -F'|' '{ print NR "|" $0 }'
}

# -- main ---------------------------------------------------------

ensure_ledger

DISCOVERED=$(fetch_hn) || true
if [ -z "$DISCOVERED" ]; then
  echo "hn-snapshot: HN API empty or unreachable" >&2
  exit 2
fi

NEW=0
UPDATED=0
TOP_URL=""
TOP_POINTS=""

while IFS='|' read -r rank points epoch url; do
  [ -z "$url" ] && continue
  hn_date=$(epoch_to_date "$epoch")
  set +e
  upsert_url "$url" "$rank" "$points" "$hn_date"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    NEW=$((NEW + 1))
  else
    UPDATED=$((UPDATED + 1))
  fi
  if [ "$rank" = "1" ]; then
    TOP_URL="$url"
    TOP_POINTS="$points"
  fi
done <<<"$DISCOVERED"

TOTAL=$((NEW + UPDATED))

# Canned body summary -- single short paragraph, no fanout.
# printf needs `--` end-of-options before format strings that
# start with `-`, otherwise printf treats `-S...` as a flag.
{
  printf 'HN front-page snapshot.\n\n'
  printf -- '- Stories ingested: %d (%d new, %d updated)\n' "$TOTAL" "$NEW" "$UPDATED"
  [ -n "$TOP_URL" ] && printf -- '- Top: %s (%s pts)\n' "$TOP_URL" "$TOP_POINTS"
} > "$BODY_OUT"

exit 0
