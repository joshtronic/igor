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

# Returns 0 (true) if the URL is navigation / boilerplate / asset
# shaped -- not content worth reading. Used by extract_links (HTML
# scrape path) and by ledger_append_urls (sitemap/RSS paths) so
# all three discovery routes apply the same denylist.
is_nav_url() {
  local url="$1"
  case "$url" in
    *://*/login*|*://*/signup*|*://*/register*) return 0 ;;
  esac
  printf '%s' "$url" | grep -qE '\.(jpg|jpeg|png|gif|svg|ico|css|js|pdf|xml|atom|rss)(\?|$)' && return 0
  printf '%s' "$url" | grep -qE '/(login|signup|register|search\?|rss|feed|atom|legal|about|about-us|contact|contact-us|privacy|privacy-policy|terms|terms-of-service|tos|imprint|cookies|cookie-policy|jobs|careers|hiring|sitemap|apply|api|tag|tags|category|categories|archive|archives|page|colophon)([?/]|$)' && return 0
  printf '%s' "$url" | grep -qE '^https?://[^/]+/?$' && return 0
  return 1
}

# Extract plausible content links from HTML. Returns href URLs from
# <a href="..."> tags, fragments stripped. Doesn't apply the nav
# filter -- ledger_append_urls runs is_nav_url on everything
# regardless of discovery method, so filtering here would be
# duplicative.
extract_links() {
  printf '%s' "$1" \
    | grep -oE 'href="https?://[^"]+"' \
    | sed -E 's/^href="//; s/"$//; s/#.*$//' \
    | sort -u
}

# Hostname of a URL, sans leading "www.". Trailing path is dropped.
url_host() {
  printf '%s' "$1" | sed -E 's|^https?://([^/]+).*|\1|; s|^www\.||'
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

# -- per-source ledger ---------------------------------------------
#
# Each reading source has a ledger at memories/reading/sources/
# <domain>.md tracking which URLs have been seen (`- [ ]`) and
# which have been read (`- [x] -- read YYYY-MM-DD`). The ledger
# replaces the heuristic domain+slug-match dedupe we used to do
# against log.md and journal entries -- exact-URL matching is
# unambiguous, fast, and survives multi-word titles like
# "A Confession: I'm an AI-First Coder Now" that the substring
# heuristic missed.
#
# Discovery method is cached in the ledger header so each tick is
# a single fetch (sitemap.xml / rss.xml / homepage HTML) rather
# than re-probing the 8-path list every time.

ledger_path() {
  local source_url="$1"
  printf '%s/memories/reading/sources/%s.md' "$BRAIN_PATH" "$(url_host "$source_url")"
}

# Strip trailing blank lines from a file. Used to keep ledger files
# clean for markdownlint MD012 (no multiple consecutive blank lines),
# which fires when a file ends with one or more blank lines AND
# implicitly counts EOF as a blank.
ledger_strip_trailing_blanks() {
  local f="$1"
  [ -f "$f" ] || return 0
  local tmp; tmp=$(mktemp)
  # Classic sed idiom: at EOF in an empty line, delete; otherwise
  # accumulate and continue. Strips all trailing empty lines.
  sed -e :a -e '/^$/{$d;N;ba' -e '}' "$f" > "$tmp" && mv "$tmp" "$f"
}

ledger_init() {
  local ledger="$1" source_url="$2"
  if [ -f "$ledger" ]; then
    # Auto-heal: pre-existing ledgers from before the MD012 fix
    # end with a trailing blank line that trips markdownlint.
    # Normalize on every init so brain CI passes after the next
    # commit_brain_changes picks up the modification.
    ledger_strip_trailing_blanks "$ledger"
    return 0
  fi
  mkdir -p "$(dirname "$ledger")"
  # No trailing blank line after "## Index" -- markdownlint MD012
  # treats it as multiple consecutive blanks at EOF. The first URL
  # appended via ledger_append_urls will insert the blank-line
  # separator between the heading and the list (for MD022).
  cat > "$ledger" <<HDR
# Posts seen from $(url_host "$source_url")

Source: ${source_url}
Discovery: pending

## Index
HDR
}

# Read the discovery method (sitemap|rss|html|pending) from the
# ledger header. Empty if missing or malformed.
ledger_get_method() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -m1 -E '^Discovery:' "$ledger" 2>/dev/null \
    | sed -E 's/^Discovery:[[:space:]]*([a-z]+).*/\1/'
}

# Read the discovery URL cached in the header.
ledger_get_discovery_url() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -m1 -E '^Discovery:.*cached at' "$ledger" 2>/dev/null \
    | sed -E 's/^Discovery:[^(]*\(cached at ([^,)]+).*$/\1/'
}

# Rewrite the Discovery: header line with the resolved method + URL.
ledger_set_method() {
  local ledger="$1" method="$2" discovery_url="$3"
  local today line tmp
  today=$(date +%Y-%m-%d)
  line="Discovery: ${method} (cached at ${discovery_url}, last checked ${today})"
  tmp=$(mktemp)
  awk -v line="$line" '
    !done && /^Discovery:/ { print line; done=1; next }
    { print }
  ' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# All URLs in the ledger (both [ ] and [x] entries).
ledger_load_all_urls() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -oE '^- \[[ x]\] https?://[^ ]+' "$ledger" 2>/dev/null \
    | sed -E 's/^- \[[ x]\] //'
}

# Fresh (- [ ]) URLs only.
ledger_load_fresh_urls() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -oE '^- \[ \] https?://[^ ]+' "$ledger" 2>/dev/null \
    | sed -E 's/^- \[ \] //'
}

# Append new URLs to the ledger as `- [ ] <url>`. Skips URLs that
# are already in the ledger (any state), nav/boilerplate URLs
# (via is_nav_url), and bare-domain URLs. Reads stdin.
#
# If the ledger has no URL entries yet, the first appended URL
# gets a blank-line separator inserted before it -- "## Index"
# needs a blank line before the list for markdownlint MD022.
ledger_append_urls() {
  local ledger="$1" url existing first_append=0
  existing=$(ledger_load_all_urls "$ledger")
  [ -z "$existing" ] && first_append=1
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    url=$(printf '%s' "$url" | sed 's/#.*//')
    if is_nav_url "$url"; then
      continue
    fi
    if printf '%s\n' "$existing" | grep -qxF "$url"; then
      continue
    fi
    if [ "$first_append" = "1" ]; then
      printf '\n' >> "$ledger"
      first_append=0
    fi
    printf -- '- [ ] %s\n' "$url" >> "$ledger"
    existing="${existing}"$'\n'"${url}"
  done
}

# Flip a URL's `[ ]` to `[x]` with a read date.
ledger_mark_read() {
  local ledger="$1" url="$2"
  [ -f "$ledger" ] || return 0
  local today tmp
  today=$(date +%Y-%m-%d)
  tmp=$(mktemp)
  awk -v url="$url" -v today="$today" '
    {
      if ($0 == "- [ ] " url) {
        printf "- [x] %s -- read %s\n", url, today
      } else {
        print
      }
    }
  ' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# -- discovery -----------------------------------------------------
#
# Probe a source's homepage for the canonical post-list endpoint.
# Sitemaps and RSS/Atom feeds are far more authoritative than
# scraping homepage HTML (which only sees the most-recent slice of
# the archive). HTML stays as the fallback for aggregators (HN
# doesn't sitemap individual stories) and for sites with no feed.
#
# Discovery probes happen ONCE per source, the result lands in the
# ledger header, and subsequent ticks fetch the cached URL directly.

DISCOVERY_PATHS=(
  "/sitemap.xml"
  "/sitemap_index.xml"
  "/rss.xml"
  "/atom.xml"
  "/feed.xml"
  "/feed/"
  "/rss/"
  "/index.xml"
)

# Probe the discovery paths and return "<method>|<url>" for the
# first one that returns valid sitemap/RSS content. Falls back to
# "html|<homepage>" if none match.
probe_discovery() {
  local source_url="$1"
  source_url=$(printf '%s' "$source_url" | sed 's:/$::')
  local path try_url content
  for path in "${DISCOVERY_PATHS[@]}"; do
    try_url="${source_url}${path}"
    content=$(curl -sfL --max-time 10 --max-filesize 5000000 -A "$UA" "$try_url" 2>/dev/null)
    [ -z "$content" ] && continue
    local head
    head=$(printf '%s' "$content" | head -c 2048)
    if printf '%s' "$head" | grep -qE '<urlset|<sitemapindex'; then
      printf 'sitemap|%s' "$try_url"
      return 0
    fi
    if printf '%s' "$head" | grep -qE '<rss[ >]|<feed[ >]|<feed xmlns'; then
      printf 'rss|%s' "$try_url"
      return 0
    fi
  done
  printf 'html|%s' "$source_url"
}

parse_sitemap() {
  local url="$1" content
  content=$(curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$url" 2>/dev/null)
  [ -z "$content" ] && return

  # WordPress and many other CMSes return a sitemap INDEX at
  # /sitemap.xml or /wp-sitemap.xml -- a list of sub-sitemap URLs,
  # not actual posts. Detect <sitemapindex> and recurse one level:
  # fetch each sub-sitemap, extract its <loc> entries, aggregate.
  # No deeper recursion (sitemap indexes rarely nest beyond one
  # level; if they do, we just miss those URLs -- not fatal).
  if printf '%s' "$content" | head -c 2048 | grep -qE '<sitemapindex'; then
    local sub_urls sub
    sub_urls=$(printf '%s' "$content" \
      | grep -oE '<loc>[^<]+</loc>' \
      | sed -E 's,</?loc>,,g')
    while IFS= read -r sub; do
      [ -z "$sub" ] && continue
      curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$sub" 2>/dev/null \
        | grep -oE '<loc>[^<]+</loc>' \
        | sed -E 's,</?loc>,,g' \
        | grep -vE '\.(xml|gz)$'
    done <<<"$sub_urls"
    return
  fi

  # Plain urlset: extract <loc> entries directly. Skip any that
  # point to sub-sitemaps (shouldn't happen in a urlset, but
  # defensive).
  printf '%s' "$content" \
    | grep -oE '<loc>[^<]+</loc>' \
    | sed -E 's,</?loc>,,g' \
    | grep -vE '\.(xml|gz)$'
}

parse_rss() {
  local url="$1"
  local content
  content=$(curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$url" 2>/dev/null)
  {
    # RSS 2.0: <link>...</link> inside <item>. Greedy global match;
    # also catches channel-level <link> (the homepage), filtered
    # later by ledger_append_urls' bare-domain drop.
    printf '%s' "$content" | grep -oE '<link>[^<]+</link>' \
      | sed -E 's,</?link>,,g'
    # Atom: <link href="..." .../>
    printf '%s' "$content" | grep -oE '<link[^>]+href="[^"]+"' \
      | sed -E 's/.*href="([^"]+)".*/\1/'
  } | grep -E '^https?://' | sort -u
}

# Discover URLs from a source using the cached discovery method.
# Probes (and caches) on first call per ledger.
discover_source_urls() {
  local source_url="$1" ledger="$2"
  local method discovery_url
  method=$(ledger_get_method "$ledger")
  discovery_url=$(ledger_get_discovery_url "$ledger")

  if [ -z "$method" ] || [ "$method" = "pending" ]; then
    local probe
    probe=$(probe_discovery "$source_url")
    method="${probe%%|*}"
    discovery_url="${probe#*|}"
    ledger_set_method "$ledger" "$method" "$discovery_url"
    echo "discretionary-read: discovery for $(url_host "$source_url") -> $method ($discovery_url)" >&2
  fi

  case "$method" in
    sitemap) parse_sitemap "$discovery_url" ;;
    rss)     parse_rss "$discovery_url" ;;
    html|*)
      local html
      html=$(fetch_html "$source_url")
      [ -n "$html" ] && extract_links "$html"
      ;;
  esac
}

# -- discover a fresh URL + read it (with retry) ------------------
#
# Loop is bounded: up to MAX_ATTEMPTS calls to agent-read.sh per
# tick. For each source picked, the harness:
#   1. Ensures the per-source ledger exists.
#   2. Discovers URLs via the cached method (sitemap/rss/html).
#   3. Appends any new URLs to the ledger as `- [ ]`.
#   4. Picks a random `- [ ]` URL that's NOT also in log.md (cross-
#      source dedupe -- the same article surfaced from HN and from
#      the author's blog shouldn't get read twice).
#   5. Calls agent-read.sh. Failures drop the URL from the current
#      source's pool for this run.
#
# Failed URLs stay re-tryable on future ticks (the failure was
# probably transient: rate limit, momentary 5xx, etc.).
#
# Cross-source dedupe is a soft filter against log.md (where every
# read tick writes its URL). If we find a URL we've already read,
# we flip it to `[x]` in the ledger so future picks don't keep
# rejecting it.

MAX_ATTEMPTS=3
PICKED_LEDGER=""
attempts=0
read_output=""
URL=""
PICKED_SOURCE=""
remaining_sources="$sources"
candidates=""

while [ "$attempts" -lt "$MAX_ATTEMPTS" ]; do
  if [ -z "$candidates" ]; then
    [ -z "$remaining_sources" ] && break
    picked=$(sample_weighted "$remaining_sources") || break
    source_weight=${picked%%|*}
    source_url=${picked#*|}
    PICKED_SOURCE="$source_url"
    remaining_sources=$(grep -vF "$source_weight|$source_url" <<<"$remaining_sources" || true)

    PICKED_LEDGER=$(ledger_path "$source_url")
    ledger_init "$PICKED_LEDGER" "$source_url"

    # Discover + append new URLs to the ledger.
    discovered=$(discover_source_urls "$source_url" "$PICKED_LEDGER")
    if [ -n "$discovered" ]; then
      printf '%s\n' "$discovered" | ledger_append_urls "$PICKED_LEDGER"
    fi

    # Candidate pool = fresh URLs in ledger, minus anything already
    # in log.md (cross-source dedupe). URLs found in log.md get
    # flipped to [x] in the ledger so we don't keep checking them.
    candidates=""
    while IFS= read -r fresh_url; do
      [ -z "$fresh_url" ] && continue
      if [ -f "$LOG_FILE" ] && grep -qF "$fresh_url" "$LOG_FILE" 2>/dev/null; then
        ledger_mark_read "$PICKED_LEDGER" "$fresh_url"
        continue
      fi
      candidates="${candidates}${fresh_url}"$'\n'
    done < <(ledger_load_fresh_urls "$PICKED_LEDGER" | shuf)
    candidates=$(printf '%s' "$candidates" | awk 'NF')

    if [ -z "$candidates" ]; then
      echo "discretionary-read: $(url_host "$source_url") has no fresh URLs after dedupe, trying another source" >&2
      continue
    fi
  fi

  URL=$(printf '%s\n' "$candidates" | head -1)
  candidates=$(printf '%s\n' "$candidates" | tail -n +2)

  attempts=$((attempts + 1))
  echo "discretionary-read: attempt $attempts/$MAX_ATTEMPTS -- $PICKED_SOURCE -> $URL" >&2

  err_file=$(mktemp)
  if read_output=$("$IGOR_HOME/bin/agent-read.sh" "$URL" 2>"$err_file"); then
    rm -f "$err_file"
    break
  fi
  last_err=$(tail -1 "$err_file")
  rm -f "$err_file"
  echo "discretionary-read: agent-read failed for $URL -- ${last_err:-unknown error}" >&2
  read_output=""
  URL=""
done

if [ -z "$read_output" ]; then
  if [ "$attempts" -eq 0 ]; then
    echo "discretionary-read: no candidate URL found across any source" >&2
    exit 2
  fi
  echo "discretionary-read: agent-read failed across $attempts attempt(s)" >&2
  exit 3
fi

# Mark the URL as read in the source's ledger.
[ -n "$PICKED_LEDGER" ] && ledger_mark_read "$PICKED_LEDGER" "$URL"

echo "discretionary-read: selected via $PICKED_SOURCE -> $URL" >&2

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
      printf 'but not sampled. Igor promotes them to weight 1 when\n'
      printf 'recent reads show enough signal -- no human bump needed.\n\n'
    } >> "$SOURCES_FILE"
  fi
  printf '%s\n' "- 0 -- $cand_url -- $cand_label" >> "$SOURCES_FILE"
  echo "discretionary-read: candidate added -- $cand_url ($cand_label)" >&2
}

# Promote a candidate from weight 0 to weight 1. No-op if the URL
# isn't found at weight 0 (already promoted, never added, or sitting
# at a higher weight already).
promote_candidate() {
  local target_url="$1"
  local tmp
  tmp=$(mktemp)
  awk -v url="$target_url" '
    $1 == "-" && $2 == "0" && $3 == "--" && $4 == url {
      $2 = 1
      print
      next
    }
    { print }
  ' "$SOURCES_FILE" > "$tmp" && mv "$tmp" "$SOURCES_FILE"
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

  # Promotions: weight-0 candidates that the reflection thinks
  # have earned a sample. Igor adjusts his own pool over time --
  # no human-bump needed.
  prom_tmp=$(mktemp)
  jq -c '.promotions[]?' <<<"$reflection" 2>/dev/null > "$prom_tmp" || true
  while IFS= read -r promotion; do
    [ -z "$promotion" ] && continue
    prom_url=$(jq -r '.url // ""' <<<"$promotion" 2>/dev/null || echo "")
    prom_reason=$(jq -r '.reason // ""' <<<"$promotion" 2>/dev/null || echo "")
    [ -z "$prom_url" ] && continue
    promote_candidate "$prom_url"
    echo "discretionary-read: promoted candidate $prom_url (0 -> 1) -- $prom_reason" >&2
  done < "$prom_tmp"
  rm -f "$prom_tmp"
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
