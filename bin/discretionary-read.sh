#!/usr/bin/env bash
# discretionary-read.sh -- harness-owned reading tick executor.
#
# Replaces the "claude code does a shape-c reading tick" path with
# a direct API call. Picks a source from brain's reading-sources
# config, fetches its index, picks a fresh URL, then calls
# bin/agent-read.sh to fetch + journal that URL via one direct API
# call. Writes the journal file the brain commit flow expects, and
# appends the URL to the reading log.
#
# Usage:
#   bin/discretionary-read.sh <worktree-path>
#
# Source list:
#   $BRAIN_PATH/memories/reading/sources.md
#
# Each line in sources.md that matches `- <int> -- <url> -- <label>`
# is a candidate source, with the integer as its sampling weight.
# Igor can edit that file himself; the harness picks up changes on
# every tick.
#
# Algorithm:
#   1. Parse sources.md -> list of (weight, url) pairs.
#   2. Weighted random sample to pick a primary source.
#   3. Fetch the source URL, extract candidate links from it,
#      dedupe against the reading log, pick one at random.
#   4. If the source yields no fresh URL (offline, all already
#      read, parse error), drop it from the list and resample
#      until we find one or run out of sources.
#   5. Call bin/agent-read.sh on the chosen URL, capture
#      title + journal, write the journal file, append to the
#      reading log.
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
#   1  bad args / missing sources file
#   2  no candidate URL found in any source
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
SOURCES_FILE="$BRAIN_PATH/memories/reading/sources.md"
LOG_FILE="$BRAIN_PATH/memories/reading/log.md"
JOURNAL_FILE="$WORKTREE/.igor/IGOR_JOURNAL.md"
UA="Mozilla/5.0 (compatible; Igor/1.0; +https://igor.bot)"

if [ ! -f "$SOURCES_FILE" ]; then
  echo "discretionary-read: sources file not found at $SOURCES_FILE" >&2
  echo "discretionary-read: brain may not be cloned, or sources.md not yet committed" >&2
  exit 1
fi

mkdir -p "$(dirname "$JOURNAL_FILE")"

# -- parse sources -----------------------------------------------

# Match lines like: - 25 -- https://example.com -- label
# Weights at 0 are skipped (so a source can stay listed but disabled).
# Output: "<weight>|<url>" per line.
# Portable awk (works on mawk -- no 3-arg match()).
# Format: "- <weight> -- <url> [-- <label>]" => $1='-' $2=weight $3='--' $4=url.
parse_sources() {
  awk '
    $1 == "-" && $2 ~ /^[0-9]+$/ && $3 == "--" && $4 ~ /^https?:\/\// {
      if ($2 + 0 > 0) printf "%s|%s\n", $2, $4
    }
  ' "$SOURCES_FILE"
}

sources=$(parse_sources)
if [ -z "$sources" ]; then
  echo "discretionary-read: no enabled sources in $SOURCES_FILE" >&2
  exit 2
fi

# -- helpers ------------------------------------------------------

fetch_html() {
  curl -sfL --max-time 15 --max-filesize 5000000 \
    -A "$UA" "$1" 2>/dev/null || true
}

# Extract plausible content links from HTML. Strips static-asset
# extensions and navigation-shaped URLs. Returns one URL per line,
# deduped.
extract_links() {
  printf '%s' "$1" \
    | grep -oE 'href="https?://[^"]+"' \
    | sed -E 's/^href="//; s/"$//' \
    | grep -vE '\.(jpg|jpeg|png|gif|svg|ico|css|js|pdf|xml|atom|rss)(\?|$)' \
    | grep -vE '/(login|signup|register|search\?|rss|feed|atom)([?/]|$)' \
    | sort -u
}

# Hostname of a URL, sans leading "www.". Trailing path is dropped.
url_host() {
  printf '%s' "$1" | sed -E 's|^https?://([^/]+).*|\1|; s|^www\.||'
}

# Last non-empty path segment of a URL, sans query/fragment. The
# typical "slug" of a blog post -- "fledgling" out of
# https://thatgirljen.com/2026/02/02/fledgling/.
url_slug() {
  printf '%s' "$1" \
    | sed -E 's|^https?://[^/]+||; s|[?#].*||; s|/+$||' \
    | awk -F'/' '{ print $NF }'
}

# Dedupe filter. Drops URLs already touched, where "touched" means:
#   1. The URL literally appears in log.md (harness-written entries
#      include the URL).
#   2. The domain AND slug appear on the same line in log.md OR in
#      any brain/journal entry. Catches Claude-written prose where
#      Igor said "Read thatgirljen.com -- fledgling" but never
#      captured the URL itself.
# Slug needs to be >=4 chars to reduce false positives from short
# numeric or stop-word slugs.
#
# Limitation: case (2) only fires when the URL slug matches a token
# in the prose. Multi-word titles ("a-confession-im-an-ai-first-
# coder-now" vs "A Confession: I'm an AI-First Coder Now") slip
# through and get re-read once -- but the harness writes the URL to
# log.md on success, so future picks dedupe via case (1).
filter_unread() {
  while IFS= read -r url; do
    [ -z "$url" ] && continue

    if [ -f "$LOG_FILE" ] && grep -qF "$url" "$LOG_FILE" 2>/dev/null; then
      continue
    fi

    local domain slug
    domain=$(url_host "$url")
    slug=$(url_slug "$url")

    if [ -n "$domain" ] && [ -n "$slug" ] && [ ${#slug} -ge 4 ]; then
      if [ -f "$LOG_FILE" ] \
         && grep -F "$domain" "$LOG_FILE" 2>/dev/null \
         | grep -qF "$slug" 2>/dev/null; then
        continue
      fi
      if [ -d "$BRAIN_PATH/journal" ] \
         && grep -rF "$domain" "$BRAIN_PATH/journal" 2>/dev/null \
         | grep -qF "$slug" 2>/dev/null; then
        continue
      fi
    fi

    printf '%s\n' "$url"
  done
}

# Weighted random sample from sources. Each iteration trims the
# list to remove a source we've already tried, so subsequent picks
# don't repeat the failed source.
sample_weighted() {
  local list="$1"
  local total
  total=$(awk -F'|' '{ s += $1 } END { print s + 0 }' <<<"$list")
  [ "$total" -le 0 ] && return 1
  local roll=$((RANDOM % total))
  awk -F'|' -v r="$roll" '
    {
      s += $1
      if (r < s) { print; exit }
    }
  ' <<<"$list"
}

# Try a source: fetch, extract, dedupe, pick. Returns URL on stdout
# or empty if nothing fresh.
#
# Prefers same-host candidates over off-host ones. On a personal
# blog the homepage links to its own posts; off-host hrefs are
# almost always footer cruft ("powered by GitHub Pages", social
# icons, attribution). Falling through to off-host only when there
# are no same-host candidates keeps aggregator-style sources (Kagi
# Small Web etc.) working in the rare case they end up listed.
try_source() {
  local source_url="$1"
  local source_host
  source_host=$(url_host "$source_url")
  local html
  html=$(fetch_html "$source_url")
  [ -z "$html" ] && return
  local fresh
  fresh=$(extract_links "$html" | filter_unread)
  [ -z "$fresh" ] && return
  local same_host
  same_host=$(printf '%s\n' "$fresh" | while IFS= read -r u; do
    [ -n "$u" ] && [ "$(url_host "$u")" = "$source_host" ] && printf '%s\n' "$u"
  done)
  if [ -n "$same_host" ]; then
    printf '%s\n' "$same_host" | shuf -n 1
  else
    printf '%s\n' "$fresh" | shuf -n 1
  fi
}

# -- discover a fresh URL ----------------------------------------

URL=""
PICKED_SOURCE=""
remaining="$sources"

while [ -n "$remaining" ]; do
  picked=$(sample_weighted "$remaining") || break
  source_weight=${picked%%|*}
  source_url=${picked#*|}

  result=$(try_source "$source_url")
  if [ -n "$result" ]; then
    URL="$result"
    PICKED_SOURCE="$source_url"
    break
  fi

  echo "discretionary-read: source $source_url yielded no fresh URL, trying another" >&2
  # Drop this source from remaining and retry
  remaining=$(grep -vF "$source_weight|$source_url" <<<"$remaining" || true)
done

if [ -z "$URL" ]; then
  echo "discretionary-read: no candidate URL found across any source" >&2
  exit 2
fi

echo "discretionary-read: selected via $PICKED_SOURCE -> $URL" >&2

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
# Forgejo flags U+2013/U+2014 as "ambiguous code points" when they
# show up in committed text. Model output uses them freely; collapse
# to ASCII "--" before the brain commit picks the journal up.
sed -i.bak -e 's/–/--/g' -e 's/—/--/g' "$JOURNAL_FILE" && rm -f "${JOURNAL_FILE}.bak"
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

# -- post-read reflection ----------------------------------------
#
# Single-shot Haiku call: did this read deserve a weight nudge on
# the source? Any new domains worth pulling into the pool? Bounded
# (delta -1/0/1, min weight 1, candidates land at weight 0). If
# the reflection fails for any reason -- API error, parse error,
# timeout -- we log it and continue. The read tick already succeeded;
# rebalancing is a nice-to-have on top.

apply_weight_delta() {
  local target_url="$1"
  local delta="$2"
  local tmp
  tmp=$(mktemp)
  awk -v url="$target_url" -v delta="$delta" '
    $1 == "-" && $2 ~ /^[0-9]+$/ && $3 == "--" && $4 == url {
      newweight = $2 + delta
      if (newweight < 1) newweight = 1
      $2 = newweight
      print
      next
    }
    { print }
  ' "$SOURCES_FILE" > "$tmp" && mv "$tmp" "$SOURCES_FILE"
}

append_candidate() {
  local cand_url="$1"
  local cand_label="$2"
  # Already listed (any weight)? Match the URL as the 4th field on
  # a source line -- avoids false-positives from inline mentions in
  # surrounding prose.
  if awk -v url="$cand_url" '
       $1 == "-" && $2 ~ /^[0-9]+$/ && $3 == "--" && $4 == url { found=1; exit }
       END { exit !found }
     ' "$SOURCES_FILE"; then
    return
  fi
  if ! grep -qF "## Candidates" "$SOURCES_FILE"; then
    {
      printf '\n## Candidates (auto-discovered)\n\n'
      printf 'Surfaced by post-read reflection. Weight 0 = listed\n'
      printf 'but not sampled. Dial up when one looks worth trying.\n\n'
    } >> "$SOURCES_FILE"
  fi
  printf '%s\n' "- 0 -- $cand_url -- $cand_label" >> "$SOURCES_FILE"
  echo "discretionary-read: candidate added -- $cand_url ($cand_label)" >&2
}

reflection=$("$IGOR_HOME/bin/agent-reflect-read.sh" \
  "$PICKED_SOURCE" "$URL" "$TITLE" "$JOURNAL_FILE" "$SOURCES_FILE" 2>/dev/null) || {
  echo "discretionary-read: reflection skipped (executor failed)" >&2
  reflection=""
}

if [ -n "$reflection" ]; then
  delta=$(jq -r '.weight_delta // 0' <<<"$reflection" 2>/dev/null || echo 0)
  case "$delta" in
    -1|0|1) ;;
    *) delta=0 ;;
  esac
  weight_reason=$(jq -r '.weight_reason // ""' <<<"$reflection" 2>/dev/null || echo "")

  if [ "$delta" -ne 0 ]; then
    apply_weight_delta "$PICKED_SOURCE" "$delta"
    echo "discretionary-read: weight delta $delta for $PICKED_SOURCE -- $weight_reason" >&2
  else
    echo "discretionary-read: weight held for $PICKED_SOURCE -- $weight_reason" >&2
  fi

  cand_tmp=$(mktemp)
  jq -c '.candidates[]?' <<<"$reflection" 2>/dev/null > "$cand_tmp" || true
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    cand_url=$(jq -r '.url // ""' <<<"$candidate" 2>/dev/null || echo "")
    cand_label=$(jq -r '.label // ""' <<<"$candidate" 2>/dev/null || echo "")
    [ -z "$cand_url" ] && continue
    [ -z "$cand_label" ] && cand_label="(unlabeled)"
    append_candidate "$cand_url" "$cand_label"
  done < "$cand_tmp"
  rm -f "$cand_tmp"
fi

# -- post-tick ideas reflection ----------------------------------
#
# A read shifts what feels timely. The just-written journal entry
# is the freshest signal of where Igor's head is right now -- pass
# it to the ideas reflection helper, which asks Haiku whether any
# blog-ideas should move up or down a slot. Bounded (max 3 moves,
# 1 slot each). Failures are silent -- the read tick succeeded.

IDEAS_FILE="$BRAIN_PATH/blog-ideas.md"
if [ -x "$IGOR_HOME/bin/agent-reflect-ideas.py" ] && [ -f "$IDEAS_FILE" ]; then
  python3 "$IGOR_HOME/bin/agent-reflect-ideas.py" \
    "$JOURNAL_FILE" "$IDEAS_FILE" 2>&1 \
    | sed 's/^/discretionary-read: ideas-reflection: /' >&2 \
    || true
fi

echo "discretionary-read: success" >&2
