#!/usr/bin/env bash
# discretionary-read.sh -- harness-owned reading tick executor.
#
# Replaces the "claude code does a shape-c reading tick" path with
# a direct API call. Discovers a URL via the decision tree below,
# fetches + journals via bin/agent-read.sh, writes the journal file
# the brain commit flow expects, and appends the URL to the reading
# log.
#
# Usage:
#   bin/discretionary-read.sh <worktree-path>
#
# Decision tree picks a source category, then a specific URL from
# that category. Categories reflect the sources Igor actually reads
# in practice:
#
#   25%  joshtronic.com  -- Josh's blog
#   15%  thatgirljen.com -- Jen's blog
#   30%  Hacker News front page
#   30%  Prior sources   -- domains already in the reading log
#                          (find a fresh post from a site Igor
#                          liked enough to return to)
#
# Each strategy fetches an index page, extracts candidate URLs,
# filters anything already in the reading log, and picks one at
# random. If a strategy comes up empty, the next one is tried.
#
# Reads:
#   IGOR_BRAIN_PATH    path to local brain clone
#   ANTHROPIC_API_KEY  (via agent-read.sh)
#
# Writes:
#   <worktree>/.igor/IGOR_JOURNAL.md
#   $BRAIN_PATH/memories/reading/log.md
#
# Exit codes:
#   0  success
#   1  bad args / config
#   2  no candidate URL found in any category
#   3  agent-read.sh failed
#   4  journal write failed

set -uo pipefail

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: discretionary-read.sh <worktree-path>" >&2
  exit 1
fi

BRAIN_PATH="${IGOR_BRAIN_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/brain}"
LOG_FILE="$BRAIN_PATH/memories/reading/log.md"
JOURNAL_FILE="$WORKTREE/.igor/IGOR_JOURNAL.md"
UA="Mozilla/5.0 (compatible; Igor/1.0; +https://igor.bot)"

mkdir -p "$(dirname "$JOURNAL_FILE")"

# -- helpers ------------------------------------------------------

# fetch_html <url> -- curl the URL or return empty on failure.
fetch_html() {
  curl -sfL --max-time 15 --max-filesize 5000000 \
    -A "$UA" "$1" 2>/dev/null || true
}

# extract_links <html> -- print http(s) URLs from anchor tags,
# stripped, one per line. Filters out static-asset extensions and
# obvious non-content links.
extract_links() {
  printf '%s' "$1" \
    | grep -oE 'href="https?://[^"]+"' \
    | sed -E 's/^href="//; s/"$//' \
    | grep -vE '\.(jpg|jpeg|png|gif|svg|ico|css|js|pdf|xml|atom|rss)(\?|$)' \
    | grep -vE '^https?://[^/]+/(login|signup|register|tag/|category/|search\?|rss|feed)' \
    | sort -u
}

# filter_unread <urls> -- read URLs from stdin, print only those
# not already in the reading log.
filter_unread() {
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    if [ -f "$LOG_FILE" ] && grep -qF "$url" "$LOG_FILE" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$url"
  done
}

# pick_random <urls> -- read URLs from stdin, print one at random.
pick_random() {
  grep . | shuf -n 1
}

# -- discovery strategies ----------------------------------------

# Each strategy prints a URL on stdout if it finds a fresh
# candidate, or nothing if it comes up empty.

strategy_joshtronic() {
  local html
  html=$(fetch_html "https://joshtronic.com")
  [ -z "$html" ] && return
  # Look for joshtronic.com post URLs specifically (avoid links out)
  printf '%s' "$html" \
    | grep -oE 'href="https?://joshtronic\.com/[^"]+"' \
    | sed -E 's/^href="//; s/"$//' \
    | grep -vE '/(tag/|category/|page/|links/?$|colophon/?$|about/?$|now/?$|rss|feed|atom)' \
    | grep -E '/[0-9]{4}|/[a-z][a-z0-9-]{6,}' \
    | sort -u \
    | filter_unread \
    | pick_random
}

strategy_thatgirljen() {
  local html
  html=$(fetch_html "https://thatgirljen.com")
  [ -z "$html" ] && return
  printf '%s' "$html" \
    | grep -oE 'href="https?://thatgirljen\.com/[^"]+"' \
    | sed -E 's/^href="//; s/"$//' \
    | grep -vE '/(tag/|category/|page/|about|now|rss|feed|atom)' \
    | grep -E '/[0-9]{4}|/[a-z][a-z0-9-]{6,}' \
    | sort -u \
    | filter_unread \
    | pick_random
}

strategy_hackernews() {
  # HN front page: extract story URLs (external links, not internal
  # item pages). The 'storylink' / 'titleline' class names changed
  # over the years; just take any https://[^/]+/ that isn't ycombinator.
  local html
  html=$(fetch_html "https://news.ycombinator.com/")
  [ -z "$html" ] && return
  extract_links "$html" \
    | grep -vE '^https?://(news\.)?ycombinator\.com' \
    | filter_unread \
    | pick_random
}

strategy_prior_source() {
  # Find domains already in the reading log -- sites Igor has read
  # before. Pick one at random and look for a new post on it.
  [ -f "$LOG_FILE" ] || return
  local domain
  domain=$(grep -oE '^- [a-z0-9.-]+\.[a-z]+' "$LOG_FILE" \
    | sed -E 's/^- //' \
    | grep -vE '^(joshtronic\.com|thatgirljen\.com|news\.ycombinator\.com)$' \
    | sort -u \
    | shuf -n 1)
  [ -z "$domain" ] && return
  local html
  html=$(fetch_html "https://${domain}")
  [ -z "$html" ] && return
  extract_links "$html" \
    | grep -E "^https?://${domain}/" \
    | filter_unread \
    | pick_random
}

# -- decision tree ----------------------------------------------

URL=""
PICKED_STRATEGY=""

pick_strategy() {
  local roll=$((RANDOM % 100))
  # 25 / 15 / 30 / 30 -- if a strategy comes up empty we fall
  # through the remaining ones in order so we don't fail just
  # because (say) Jen hasn't posted anything new.
  local order
  if [ "$roll" -lt 25 ]; then
    order="joshtronic thatgirljen hackernews prior_source"
  elif [ "$roll" -lt 40 ]; then
    order="thatgirljen joshtronic hackernews prior_source"
  elif [ "$roll" -lt 70 ]; then
    order="hackernews prior_source joshtronic thatgirljen"
  else
    order="prior_source hackernews joshtronic thatgirljen"
  fi
  for s in $order; do
    local result
    result=$("strategy_${s}" 2>/dev/null)
    if [ -n "$result" ]; then
      URL="$result"
      PICKED_STRATEGY="$s"
      return
    fi
  done
}

pick_strategy

if [ -z "$URL" ]; then
  echo "discretionary-read: no candidate URL found in any strategy -- everything was either offline, empty, or already read" >&2
  exit 2
fi

echo "discretionary-read: selected via $PICKED_STRATEGY: $URL" >&2

# -- call agent-read ---------------------------------------------

read_output=$("$IGOR_HOME/bin/agent-read.sh" "$URL") || {
  echo "discretionary-read: agent-read failed for $URL" >&2
  exit 3
}

TITLE=$(jq -r '.title // ""' <<<"$read_output")
JOURNAL=$(jq -r '.journal // ""' <<<"$read_output")

if [ -z "$JOURNAL" ]; then
  echo "discretionary-read: agent-read returned empty journal" >&2
  exit 3
fi

# -- write journal -----------------------------------------------

printf '%s\n' "$JOURNAL" > "$JOURNAL_FILE" || {
  echo "discretionary-read: failed to write $JOURNAL_FILE" >&2
  exit 4
}
echo "discretionary-read: wrote journal entry to $JOURNAL_FILE" >&2

# -- append to reading log ---------------------------------------

domain=$(printf '%s' "$URL" \
  | sed -E 's|^https?://([^/]+).*|\1|' \
  | sed -E 's|^www\.||')

entry="- ${domain} -- \"${TITLE}\" -- ${URL}"

today=$(date +%Y-%m-%d)
mkdir -p "$(dirname "$LOG_FILE")"

if [ ! -f "$LOG_FILE" ]; then
  cat > "$LOG_FILE" <<HDR
# Reading log

A dated list of things I've read. The harness appends to this on
every harness-driven reading tick. Takeaways and reflections live
in the journal entry from the tick I read it.

HDR
fi

if ! grep -qF "## $today" "$LOG_FILE"; then
  printf '\n## %s\n\n' "$today" >> "$LOG_FILE"
fi

if ! grep -qF "$entry" "$LOG_FILE"; then
  printf '%s\n' "$entry" >> "$LOG_FILE"
fi

echo "discretionary-read: appended to reading log -> $entry" >&2
echo "discretionary-read: success" >&2
