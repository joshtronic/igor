#!/usr/bin/env bash
# discretionary-read.sh -- harness-owned reading tick executor.
#
# Picks a reading source via weighted sample from brain's
# sources.md, runs source-type-appropriate discovery, picks a
# URL the agent hasn't read yet, calls bin/agent-read.sh to fetch +
# journal it, then runs post-read reflection on the source's
# weight + candidates + promotions.
#
# Three source types, detected by URL pattern:
#
#   personal -- a blog or site whose homepage is the canonical
#               post list. Discovery probes /sitemap.xml,
#               /rss.xml, /atom.xml, etc.; the discovered URLs
#               are all on the source's own domain.
#
#   hn       -- Hacker News. Discovery fetches HN's RSS feed;
#               URLs there go to many different domains.
#               Position in the feed = HN rank, stashed as a
#               "hn-rank N" annotation on the ledger entry.
#
#   kagi     -- Kagi Small Web (https://kagi.com/smallweb).
#               One-shot redirect: curl follows it and returns
#               whatever random small-web URL Kagi picked.
#
# Per-domain ledgers at memories/reading/sources/<domain>.md:
#
#   - Created (minimal header) the first time a URL on that
#     domain is encountered, regardless of which source surfaced
#     it. Empty Discovery line until the domain gets its sitemap
#     fetched.
#   - The sitemap fetch is LAZY: only after the agent actually reads
#     a URL from the domain does the harness probe + fetch its
#     sitemap and append the archive. Natural pacing -- we don't
#     spawn 30 sitemap probes per HN ingest.
#   - URLs land as `- [ ] <url> [-- annotation]*`. The mark-read
#     step flips to `[x]` and adds a `read YYYY-MM-DD` annotation
#     while preserving any others (notably hn-rank).
#
# Usage:
#   bin/discretionary-read.sh <worktree-path>
#
# Exit codes:
#   0  success
#   1  bad args / missing sources file
#   2  no candidate URL found in any source
#   3  agent-read.sh failed
#   4  journal write failed

set -uo pipefail

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: discretionary-read.sh <worktree-path>" >&2
  exit 1
fi

BRAIN_PATH="${AGENT_BRAIN_PATH:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/repos/igor/brain}"
SOURCES_FILE="$BRAIN_PATH/memories/reading/sources.md"
LOG_FILE="$BRAIN_PATH/memories/reading/log.md"
JOURNAL_FILE="$WORKTREE/.agent/AGENT_JOURNAL.md"
UA="Mozilla/5.0 (compatible; Agent/1.0)"

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

# -- generic helpers ----------------------------------------------

fetch_html() {
  curl -sfL --max-time 15 --max-filesize 5000000 \
    -A "$UA" "$1" 2>/dev/null || true
}

url_host() {
  printf '%s' "$1" | sed -E 's|^https?://([^/]+).*|\1|; s|^www\.||'
}

# Source type detection. Two aggregator / one-shot sources get
# their own discovery + ledger flow; everything else is "personal"
# and uses sitemap-style discovery on its own homepage.
source_type() {
  case "$1" in
    *://kagi.com/smallweb*) printf 'kagi' ;;
    *://news.ycombinator.com*) printf 'hn' ;;
    *) printf 'personal' ;;
  esac
}

# Returns 0 (true) if the URL is navigation / boilerplate / asset
# shaped -- not content worth reading. Pure bash `[[ =~ ]]` matches
# (no `printf | grep` pipelines) -- called per-URL in tight loops
# (HN fanout = 30 URLs/tick), so avoiding subprocess spawn keeps
# the loop fast and eliminates SIGPIPE warnings on early-exit
# grep.
is_nav_url() {
  local url="$1"
  case "$url" in
    *://*/login*|*://*/signup*|*://*/register*) return 0 ;;
  esac
  [[ "$url" =~ \.(jpg|jpeg|png|gif|svg|ico|css|js|pdf|xml|atom|rss)(\?|$) ]] && return 0
  [[ "$url" =~ /(login|signup|register|search\?|rss|feed|atom|legal|about|about-us|contact|contact-us|privacy|privacy-policy|terms|terms-of-service|tos|imprint|cookies|cookie-policy|jobs|careers|hiring|sitemap|apply|api|tag|tags|category|categories|archive|archives|page|colophon)([?/]|$) ]] && return 0
  [[ "$url" =~ ^https?://[^/]+/?$ ]] && return 0
  return 1
}

# Extract plausible content links from HTML. Returns href URLs
# with fragments stripped. is_nav_url runs at ledger-append time.
extract_links() {
  printf '%s' "$1" \
    | grep -oE 'href="https?://[^"]+"' \
    | sed -E 's/^href="//; s/"$//; s/#.*$//' \
    | sort -u
}

# Weighted random sample from "<weight>|<url>" lines.
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

# -- per-domain ledger ---------------------------------------------
#
# Ledger file lives at memories/reading/sources/<domain>.md.
# Lines look like:
#
#   - [ ] https://thatgirljen.com/2026/02/02/fledgling/
#   - [x] https://thatgirljen.com/2026/03/15/spring/ -- read 2026-05-22
#
# URL is the first token after `[ ]`/`[x]`. Everything after the
# first `--` is annotations (space-separated key+value, recurring
# `--` separators). Annotations:
#
#   read YYYY-MM-DD    when this URL was read (only on [x] lines)
#
# Source-specific metadata lives in the SOURCE's ledger, not on
# random destination ledgers. HN's ledger (news.ycombinator.com.md)
# carries three annotations per URL:
#
#   hn-rank N          highest position this URL reached on HN
#                      (lowest number wins on update)
#   hn-points N        peak upvote count the agent observed on HN
#                      (highest number wins on update)
#   hn-date YYYY-MM-DD HN submission date (set on first append,
#                      immutable -- the date the story was posted)
#
# The destination domain's ledger records the same URL but stays
# focused on the domain itself. Future aggregator sources do the
# same -- their metadata lives in the aggregator's ledger.

ledger_path() {
  printf '%s/memories/reading/sources/%s.md' "$BRAIN_PATH" "$(url_host "$1")"
}

# Strip trailing blank lines (markdownlint MD012).
ledger_strip_trailing_blanks() {
  local f="$1"
  [ -f "$f" ] || return 0
  local tmp; tmp=$(mktemp)
  sed -e :a -e '/^$/{$d;N;ba' -e '}' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Create a ledger with just the header. No sitemap fetch.
# Idempotent: if the file already exists, strip trailing blanks
# (auto-heal of older format) and return.
ledger_init_minimal() {
  local ledger="$1" source_url="$2"
  if [ -f "$ledger" ]; then
    ledger_strip_trailing_blanks "$ledger"
    return 0
  fi
  mkdir -p "$(dirname "$ledger")"
  cat > "$ledger" <<HDR
# Posts seen from $(url_host "$source_url")

Source: ${source_url}
Discovery: pending

## Index
HDR
}

# Discovery method from the header (sitemap|rss|html|pending).
ledger_get_method() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -m1 -E '^Discovery:' "$ledger" 2>/dev/null \
    | sed -E 's/^Discovery:[[:space:]]*([a-z]+).*/\1/'
}

ledger_get_discovery_url() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  grep -m1 -E '^Discovery:.*cached at' "$ledger" 2>/dev/null \
    | sed -E 's/^Discovery:[^(]*\(cached at ([^,)]+).*$/\1/'
}

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

# All URLs in the ledger, both [ ] and [x]. Pulls the first
# https? token after the checkbox; annotations after are dropped.
ledger_load_all_urls() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  awk '
    /^- \[[ x]\] / {
      sub(/^- \[[ x]\] /, "")
      sub(/ .*$/, "")  # drop everything from first space onward
      print
    }
  ' "$ledger"
}

ledger_load_fresh_urls() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  awk '
    /^- \[ \] / {
      sub(/^- \[ \] /, "")
      sub(/ .*$/, "")
      print
    }
  ' "$ledger"
}

# Is this exact URL in the ledger, in any state?
ledger_url_present() {
  local ledger="$1" url="$2"
  [ -f "$ledger" ] || return 1
  awk -v url="$url" '
    /^- \[[ x]\] / {
      line = $0
      sub(/^- \[[ x]\] /, "", line)
      sub(/ .*$/, "", line)
      if (line == url) { found = 1; exit }
    }
    END { exit !found }
  ' "$ledger"
}

# Is this URL marked read in the ledger?
ledger_url_is_read() {
  local ledger="$1" url="$2"
  [ -f "$ledger" ] || return 1
  awk -v url="$url" '
    /^- \[x\] / {
      line = $0
      sub(/^- \[x\] /, "", line)
      sub(/ .*$/, "", line)
      if (line == url) { found = 1; exit }
    }
    END { exit !found }
  ' "$ledger"
}

# Get the hn-rank annotation for a URL, or empty if not present.
ledger_get_rank() {
  local ledger="$1" url="$2"
  [ -f "$ledger" ] || return 0
  awk -v url="$url" '
    /^- \[[ x]\] / {
      line = $0
      first = $0
      sub(/^- \[[ x]\] /, "", first)
      sub(/ .*$/, "", first)
      if (first == url) {
        if (match(line, /hn-rank [0-9]+/)) {
          print substr(line, RSTART + 8, RLENGTH - 8)
          exit
        }
      }
    }
  ' "$ledger"
}

# Append a URL to the ledger as `- [ ] <url>` with optional
# annotation. No-op if the URL is already in the ledger (any
# state) or is nav-shaped. The first URL appended to a fresh
# ledger gets a blank-line separator before it (MD022).
ledger_append_url() {
  local ledger="$1" url="$2" annotation="${3:-}"
  [ -f "$ledger" ] || return 1
  url=$(printf '%s' "$url" | sed 's/#.*//')
  if is_nav_url "$url"; then return 0; fi
  if ledger_url_present "$ledger" "$url"; then return 0; fi
  # Blank line before first list entry.
  if ! grep -qE '^- \[' "$ledger" 2>/dev/null; then
    printf '\n' >> "$ledger"
  fi
  if [ -n "$annotation" ]; then
    printf -- '- [ ] %s -- %s\n' "$url" "$annotation" >> "$ledger"
  else
    printf -- '- [ ] %s\n' "$url" >> "$ledger"
  fi
}

# Stream-version (reads URLs from stdin, one per line). For
# discoveries that yield many URLs at once (sitemap, RSS body).
# No annotations applied.
ledger_append_urls() {
  local ledger="$1" url
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    ledger_append_url "$ledger" "$url"
  done
}

# Update (or add) the hn-rank annotation. If the URL already has
# a rank, keep the LOWER number (highest front-page position).
ledger_update_rank() {
  local ledger="$1" url="$2" new_rank="$3"
  [ -f "$ledger" ] || return 0
  local tmp; tmp=$(mktemp)
  awk -v url="$url" -v rank="$new_rank" '
    /^- \[[ x]\] / {
      line = $0
      first = $0
      sub(/^- \[[ x]\] /, "", first)
      sub(/ .*$/, "", first)
      if (first == url) {
        if (match(line, /hn-rank [0-9]+/)) {
          existing = substr(line, RSTART + 8, RLENGTH - 8) + 0
          if (rank + 0 < existing) {
            sub(/hn-rank [0-9]+/, "hn-rank " rank, line)
          }
        } else {
          line = line " -- hn-rank " rank
        }
        print line
        next
      }
    }
    { print }
  ' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# Update (or add) the hn-points annotation. If the URL already
# has points, keep the HIGHER number (peak upvotes the agent observed).
ledger_update_points() {
  local ledger="$1" url="$2" new_points="$3"
  [ -f "$ledger" ] || return 0
  local tmp; tmp=$(mktemp)
  awk -v url="$url" -v points="$new_points" '
    /^- \[[ x]\] / {
      line = $0
      first = $0
      sub(/^- \[[ x]\] /, "", first)
      sub(/ .*$/, "", first)
      if (first == url) {
        if (match(line, /hn-points [0-9]+/)) {
          existing = substr(line, RSTART + 10, RLENGTH - 10) + 0
          if (points + 0 > existing) {
            sub(/hn-points [0-9]+/, "hn-points " points, line)
          }
        } else {
          line = line " -- hn-points " points
        }
        print line
        next
      }
    }
    { print }
  ' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# Flip [ ] to [x] and add `read YYYY-MM-DD`. Preserves any
# existing annotations on the line.
ledger_mark_read() {
  local ledger="$1" url="$2"
  [ -f "$ledger" ] || return 0
  local today tmp
  today=$(date +%Y-%m-%d)
  tmp=$(mktemp)
  awk -v url="$url" -v today="$today" '
    /^- \[ \] / {
      line = $0
      first = $0
      sub(/^- \[ \] /, "", first)
      sub(/ .*$/, "", first)
      if (first == url) {
        # Pull off everything after the URL (annotations or nothing).
        tail = line
        sub("^- \\[ \\] " url, "", tail)
        # Build new line: [x] url -- read DATE [-- existing annotations]
        if (tail == "" || tail ~ /^[[:space:]]*$/) {
          printf "- [x] %s -- read %s\n", url, today
        } else {
          # tail starts with " --" already; insert "read DATE" after the URL
          sub(/^[[:space:]]*--[[:space:]]*/, "", tail)
          printf "- [x] %s -- read %s -- %s\n", url, today, tail
        }
        next
      }
    }
    { print }
  ' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

# -- discovery: shared probe + parsers ----------------------------

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

probe_discovery() {
  local source_url="$1"
  source_url="${source_url%/}"
  local path try_url content head
  for path in "${DISCOVERY_PATHS[@]}"; do
    try_url="${source_url}${path}"
    content=$(curl -sfL --max-time 10 --max-filesize 5000000 -A "$UA" "$try_url" 2>/dev/null)
    [ -z "$content" ] && continue
    # Bash substring -- avoids `printf | head -c` which sends SIGPIPE
    # to printf when content is large (sitemap.xml can be 100KB+).
    head="${content:0:2048}"
    case "$head" in
      *"<urlset"*|*"<sitemapindex"*)
        printf 'sitemap|%s' "$try_url"
        return 0
        ;;
      *"<rss "*|*"<rss>"*|*"<feed "*|*"<feed>"*|*"<feed xmlns"*)
        printf 'rss|%s' "$try_url"
        return 0
        ;;
    esac
  done
  printf 'html|%s' "$source_url"
}

parse_sitemap() {
  local url="$1" content
  content=$(curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$url" 2>/dev/null)
  [ -z "$content" ] && return
  # WordPress / CMS sitemap indexes list sub-sitemaps; recurse one level.
  # Bash substring + glob -- no `printf | head | grep` pipeline.
  if [[ "${content:0:2048}" == *"<sitemapindex"* ]]; then
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
    printf '%s' "$content" | grep -oE '<link>[^<]+</link>' \
      | sed -E 's,</?link>,,g'
    printf '%s' "$content" | grep -oE '<link[^>]+href="[^"]+"' \
      | sed -E 's/.*href="([^"]+)".*/\1/'
  } | grep -E '^https?://' | sort -u
}

# Populate a ledger by probing for its sitemap/RSS endpoint (if
# not yet known) and appending all discovered URLs. Idempotent:
# once the ledger has a non-pending method cached, this is a fast
# refresh (probe URL is known, just re-fetch + append).
ledger_populate() {
  local ledger="$1" source_url="$2"
  [ -f "$ledger" ] || return 0
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

  local discovered
  case "$method" in
    sitemap) discovered=$(parse_sitemap "$discovery_url") ;;
    rss)     discovered=$(parse_rss "$discovery_url") ;;
    html|*)
      local html
      html=$(fetch_html "$source_url")
      [ -n "$html" ] && discovered=$(extract_links "$html") || discovered=""
      ;;
  esac

  [ -n "$discovered" ] && printf '%s\n' "$discovered" | ledger_append_urls "$ledger"
}

# -- discovery: aggregators ---------------------------------------

# HN: query the Algolia API for the current front page. Returns
# "<rank>|<points>|<created_at_epoch>|<url>" rows. created_at is
# the HN submission time (immutable), used as the hn-date
# annotation. Algolia is preferred over the raw RSS because it
# includes upvotes, comment counts, and timestamps in one query.
#
# Self-posts (Ask HN, Tell HN) have null url -- those get
# filtered. Only external story URLs make it into the ledger.
discover_hn() {
  local api='https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30'
  curl -sfL --max-time 15 --max-filesize 5000000 -A "$UA" "$api" 2>/dev/null \
    | jq -r '.hits[]? | select(.url != null) | "\(.points // 0)|\(.created_at_i // 0)|\(.url)"' \
    | awk -F'|' '{ print NR "|" $0 }'
}

# Convert a Unix epoch to YYYY-MM-DD. Tries GNU's `date -d @N`
# first (Debian/Linux -- where the agent actually runs); falls back
# to BSD's `date -r N` for local-dev portability. Empty string
# if neither works (or the input is missing / zero).
epoch_to_date() {
  local epoch="$1"
  [ -z "$epoch" ] || [ "$epoch" = "0" ] && return 0
  date -d "@$epoch" +%Y-%m-%d 2>/dev/null \
    || date -r "$epoch" +%Y-%m-%d 2>/dev/null \
    || true
}

# Kagi Small Web: redirects to a random small-web URL. Follow
# the redirect and return the final URL.
discover_kagi() {
  local endpoint="$1"
  curl -sL --max-time 15 -A "$UA" -o /dev/null \
    -w '%{url_effective}' "$endpoint" 2>/dev/null
}

# -- pick + read --------------------------------------------------
#
# Per-source-type discovery + candidate selection. Each branch
# builds a `candidates` list of URLs to try, in priority order.
# The read loop pops one at a time and calls agent-read; failures
# go to the next.

MAX_ATTEMPTS=3
attempts=0
read_output=""
URL=""
PICKED_SOURCE=""
PICKED_SOURCE_TYPE=""
remaining_sources="$sources"
candidates=""

while [ "$attempts" -lt "$MAX_ATTEMPTS" ]; do
  if [ -z "$candidates" ]; then
    [ -z "$remaining_sources" ] && break
    picked=$(sample_weighted "$remaining_sources") || break
    source_weight=${picked%%|*}
    source_url=${picked#*|}
    PICKED_SOURCE="$source_url"
    PICKED_SOURCE_TYPE=$(source_type "$source_url")
    remaining_sources=$(grep -vF "$source_weight|$source_url" <<<"$remaining_sources" || true)

    case "$PICKED_SOURCE_TYPE" in
      personal)
        # Sampling a personal site IS visiting it -- populate
        # eagerly so the picker has the full archive to choose from.
        ledger=$(ledger_path "$source_url")
        ledger_init_minimal "$ledger" "$source_url"
        ledger_populate "$ledger" "$source_url"
        # Candidates: unread URLs from this domain's ledger,
        # cross-source dedupe via log.md (rare; mostly relevant if
        # the same URL surfaced via HN before).
        candidates=""
        while IFS= read -r fresh_url; do
          [ -z "$fresh_url" ] && continue
          if [ -f "$LOG_FILE" ] && grep -qF "$fresh_url" "$LOG_FILE" 2>/dev/null; then
            ledger_mark_read "$ledger" "$fresh_url"
            continue
          fi
          candidates="${candidates}${fresh_url}"$'\n'
        done < <(ledger_load_fresh_urls "$ledger" | shuf)
        candidates=$(printf '%s' "$candidates" | awk 'NF')
        ;;
      hn)
        # HN flow: hn-rank / hn-points annotations live on HN's
        # OWN ledger (news.ycombinator.com.md) -- the master list
        # of URLs the agent has ever seen on HN's front page. The
        # destination domain ledger (e.g. theverge.com.md, etc.)
        # records the URL too, but without HN-specific gunk -- so
        # foo.com's ledger stays focused on foo.com.
        #
        # Picker walks HN's ledger (sorted by points DESC, rank
        # ASC), filters out URLs marked read in EITHER ledger.
        # That cross-source dedup catches the case where the agent
        # read a URL via HN and later the same URL turns up in
        # the destination's own sitemap (after promotion).
        discovered=$(discover_hn)
        if [ -z "$discovered" ]; then
          echo "discretionary-read: HN API empty or unreachable, trying another source" >&2
          continue
        fi

        hn_ledger=$(ledger_path "https://news.ycombinator.com")
        ledger_init_minimal "$hn_ledger" "https://news.ycombinator.com"

        # Ingest this tick's RSS into both ledgers. HN's gets
        # annotations; the destination's just notes the URL.
        # hn-date is set on FIRST append and never changes
        # (submission date is immutable); rank/points get
        # updated on subsequent appearances.
        while IFS='|' read -r rank points created_at_i url; do
          [ -z "$url" ] && continue
          hn_date=$(epoch_to_date "$created_at_i")
          annotation="hn-rank $rank -- hn-points $points"
          [ -n "$hn_date" ] && annotation="$annotation -- hn-date $hn_date"
          ledger_append_url "$hn_ledger" "$url" "$annotation"
          ledger_update_rank "$hn_ledger" "$url" "$rank"
          ledger_update_points "$hn_ledger" "$url" "$points"
          dest_ledger=$(ledger_path "$url")
          if [ "$dest_ledger" != "$hn_ledger" ]; then
            ledger_init_minimal "$dest_ledger" "$url"
            ledger_append_url "$dest_ledger" "$url"
          fi
          # If log.md already shows this URL as read, mark in both.
          if [ -f "$LOG_FILE" ] && grep -qF "$url" "$LOG_FILE" 2>/dev/null; then
            ledger_mark_read "$hn_ledger" "$url"
            [ "$dest_ledger" != "$hn_ledger" ] && ledger_mark_read "$dest_ledger" "$url"
          fi
        done <<<"$discovered"

        # Candidate set: HN's fresh URLs (- [ ]) minus anything
        # marked read in its destination domain's ledger.
        # Sort key extracted from annotations on each HN line.
        sorted_candidates=""
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          # URL is the first token after "- [ ] "
          cand_url=$(printf '%s' "$line" | sed -E 's/^- \[ \] ([^ ]+).*/\1/')
          [ -z "$cand_url" ] && continue
          cand_dest=$(ledger_path "$cand_url")
          if [ "$cand_dest" != "$hn_ledger" ] \
             && ledger_url_is_read "$cand_dest" "$cand_url"; then
            ledger_mark_read "$hn_ledger" "$cand_url"
            continue
          fi
          cand_points=$(printf '%s' "$line" | grep -oE 'hn-points [0-9]+' | awk '{print $2}')
          cand_rank=$(printf '%s' "$line" | grep -oE 'hn-rank [0-9]+' | awk '{print $2}')
          sorted_candidates="${sorted_candidates}${cand_points:-0}|${cand_rank:-999}|${cand_url}"$'\n'
        done < <(grep '^- \[ \]' "$hn_ledger" 2>/dev/null)
        candidates=$(printf '%s' "$sorted_candidates" \
          | awk 'NF' \
          | sort -t'|' -k1nr -k2n \
          | cut -d'|' -f3-)
        ;;
      kagi)
        # Kagi Small Web one-shot: follow the redirect, get a
        # random URL, fanout to its domain ledger.
        target=$(discover_kagi "$source_url")
        if [ -z "$target" ] || ! printf '%s' "$target" | grep -qE '^https?://'; then
          echo "discretionary-read: Kagi smallweb redirect failed, trying another source" >&2
          continue
        fi
        dest_ledger=$(ledger_path "$target")
        ledger_init_minimal "$dest_ledger" "$target"
        if ledger_url_is_read "$dest_ledger" "$target"; then
          echo "discretionary-read: Kagi sent us to a URL we've read, trying another source" >&2
          continue
        fi
        ledger_append_url "$dest_ledger" "$target"
        candidates="$target"
        ;;
    esac

    if [ -z "$candidates" ]; then
      echo "discretionary-read: $(url_host "$source_url") has no fresh URLs after dedupe, trying another source" >&2
      continue
    fi
  fi

  URL=$(printf '%s\n' "$candidates" | head -1)
  candidates=$(printf '%s\n' "$candidates" | tail -n +2)

  attempts=$((attempts + 1))
  echo "discretionary-read: attempt $attempts/$MAX_ATTEMPTS -- $PICKED_SOURCE -> $URL" >&2

  # Tee agent-read's stderr: streams through to journalctl in real
  # time (so RAG build progress, curl errors, etc., are visible)
  # AND gets captured to a temp file so we can pluck the last line
  # on failure for the discretionary-read warning. Previously stderr
  # was redirected to file only -- the RAG `rag: flushed redis db /
  # rag: collected N journal + M memory / rag: indexed ... entries`
  # output never surfaced on reading ticks because it was buried.
  err_file=$(mktemp)
  if read_output=$("$AGENT_HOME/bin/agent-read.sh" "$URL" 2> >(tee "$err_file" >&2)); then
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

# Target ledger = the URL's domain ledger (NOT the source's).
# For personal sources, source domain == URL domain, so this is
# the same file. For HN/Kagi, it's the destination domain.
TARGET_LEDGER=$(ledger_path "$URL")
ledger_mark_read "$TARGET_LEDGER" "$URL"

# For HN reads: mark in HN's ledger too (where the URL was
# tracked with its rank/points annotations). The destination
# ledger above and HN's ledger now both have the URL as [x].
if [ "$PICKED_SOURCE_TYPE" = "hn" ]; then
  HN_LEDGER=$(ledger_path "https://news.ycombinator.com")
  if [ "$HN_LEDGER" != "$TARGET_LEDGER" ]; then
    ledger_mark_read "$HN_LEDGER" "$URL"
  fi
fi

# Lazy sitemap fetch: NOW that the agent's actually read from this
# domain, populate its ledger with the rest of the archive.
# Idempotent -- no-op if already populated.
ledger_populate "$TARGET_LEDGER" "$URL"

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
      printf 'but not sampled. the agent promotes them to weight 1 when\n'
      printf 'recent reads show enough signal -- no human bump needed.\n\n'
    } >> "$SOURCES_FILE"
  fi
  printf '%s\n' "- 0 -- $cand_url -- $cand_label" >> "$SOURCES_FILE"
  echo "discretionary-read: candidate added -- $cand_url ($cand_label)" >&2
}

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

reflection=$("$AGENT_HOME/bin/agent-reflect-read.sh" \
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

  # Weight adjustments only make sense when source domain == URL
  # domain (personal sites). For aggregator sources (HN, Kagi),
  # the URL lives on some destination domain that has nothing to
  # do with the source's quality -- a thin Verge article should
  # not downweight HN. Candidates + promotions still apply; the
  # weight stays where it is.
  if [ "$delta" -ne 0 ]; then
    if [ "$PICKED_SOURCE_TYPE" = "personal" ]; then
      apply_weight_delta "$PICKED_SOURCE" "$delta"
      echo "discretionary-read: weight delta $delta for $PICKED_SOURCE -- $weight_reason" >&2
    else
      echo "discretionary-read: weight delta $delta SKIPPED for $PICKED_SOURCE (aggregator -- destination quality doesn't reflect source) -- $weight_reason" >&2
    fi
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

IDEAS_FILE="$BRAIN_PATH/blog-ideas.md"
if [ -x "$AGENT_HOME/bin/agent-reflect-ideas.py" ] && [ -f "$IDEAS_FILE" ]; then
  python3 "$AGENT_HOME/bin/agent-reflect-ideas.py" \
    "$JOURNAL_FILE" "$IDEAS_FILE" 2>&1 \
    | sed 's/^/discretionary-read: ideas-reflection: /' >&2 \
    || true
fi

echo "discretionary-read: success" >&2
