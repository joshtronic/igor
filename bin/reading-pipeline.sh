#!/usr/bin/env bash
# reading-pipeline.sh -- the reading INGEST pass.
#
# Reads a fixed slate of sources and reflects each into the brain.
# That is the whole job. Drafting and posting are a separate concern
# now (bin/ideation-pipeline.sh), so a thin or thematically-scattered
# reading day never blocks the daily post: ideation works from the
# whole brain, not from this tick's reads.
#
# Per invocation:
#
#   Read cycle over the READING_SLATE source list (operator config, see
#   .env.example; "url|picker" pairs, semicolon-separated). Up to
#   MAX_READS_PER_TICK reads. Per source: pick a URL the agent hasn't
#   read (per its picker function), fetch it, ask the model for {title,
#   journal}, INSERT a reflection (kind='reading'), mark
#   seen_urls.read_at. Empty slot? Skip -- a partial-slate tick is fine.
#
# Reads are non-destructive, so there is no dry-run gate; --live is
# accepted and ignored for call-site symmetry with ideation-pipeline.
#
# Usage:
#   bin/reading-pipeline.sh [--brain-db PATH] [--live]
#
# Model calls go through claude_call (the `claude` CLI on the host's
# subscription login) -- no API key needed or wanted in the env.
#
# Required env (only enforced once WEBSITE_REPO opts this pipeline in):
#   READING_SLATE      -- "url|picker;url|picker;..." source slate
#
# Optional env:
#   WEBSITE_REPO       -- opt-in gate; unset -> no-op clean
#   AGENT_MODEL        -- default claude-sonnet-4-6
#   AGENT_STATE_DIR    -- default ~/.local/state/agent
#   AGENT_HOME         -- default <script-parent-dir>

set -uo pipefail

# -- args ------------------------------------------------------

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"

BRAIN_DB="$AGENT_STATE_DIR/brain.sqlite"

while [ $# -gt 0 ]; do
  case "$1" in
    --brain-db)      BRAIN_DB="$2"; shift 2 ;;
    --live)          shift ;;  # accepted, ignored: reads never push
    -h|--help)       sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *)               echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# -- env --------------------------------------------------------

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

# WEBSITE_REPO is the opt-in gate for all website-side work. With it
# unset there is no point accumulating reflections no downstream
# consumer reads -- exit clean (rc 0) so the harness treats the
# no-website case as a no-op, not an error.
if [ -z "${WEBSITE_REPO:-}" ]; then
  echo "reading-pipeline: WEBSITE_REPO unset -- nothing to do (set it in .env to opt in)" >&2
  exit 0
fi

: "${READING_SLATE:?READING_SLATE must be set (see .env.example)}"

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"

# -- libs -------------------------------------------------------

# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=../lib/claude.sh
. "$AGENT_HOME/lib/claude.sh"
# shellcheck source=../lib/brain.sh
. "$AGENT_HOME/lib/brain.sh"
# shellcheck source=../lib/context-source.sh
. "$AGENT_HOME/lib/context-source.sh"

# -- constants --------------------------------------------------

MAX_READS_PER_TICK=5   # one read per READING_SLATE source
SEED_RECENT_MAX=25     # cap on posts seeded per personal feed per cycle
HTML_TRUNCATE_BYTES=200000
FETCH_TIMEOUT=30
UA="Mozilla/5.0 (compatible; agent/reading-pipeline)"

# -- logging ----------------------------------------------------

log() { printf 'reading-pipeline: %s\n' "$*" >&2; }

# -- brain ------------------------------------------------------

brain_init || { log "failed to ensure brain db schema at $BRAIN_DB"; exit 2; }

# Sourced from the Distillery at origin/master, live, via context_surface's
# last-good cache -- no in-repo fallback (lib/context-source.sh, igor#485).
# tick.sh's bootstrap gate normally guarantees a seeded cache before this
# ever runs; the check below is defense-in-depth for a standalone invocation.
if ! context_seeded; then
  log "prompt cache never seeded (lib/context-source.sh) -- refusing to run"
  exit 2
fi
VOICE_BODY=$(context_surface voice)
# Seeded does not imply servable, and this script has no `set -e` to catch it:
# an empty anchor would splice into the prompt and the pass would write with no
# voice constraints at all -- a silent quality regression. Refuse instead.
if [ -z "$VOICE_BODY" ]; then
  log "prompt cache is seeded but 'voice' could not be served -- refusing to run"
  exit 2
fi

TODAY=$(date +%Y-%m-%d)
NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S%z)

# -- seen_urls helpers ------------------------------------------

is_url_read() {
  local url="$1"
  local count
  count=$(sqlite3 "$BRAIN_DB" \
    "SELECT COUNT(*) FROM seen_urls WHERE url = $(sqlite_quote "$url") AND read_at IS NOT NULL;" \
    2>/dev/null) || count=0
  [ "${count:-0}" -gt 0 ]
}

mark_url_read() {
  local url="$1" source_url="$2"
  local domain
  domain=$(printf '%s' "$url" | sed -E 's|^https?://([^/]+).*|\1|')
  sqlite3 "$BRAIN_DB" <<EOF >/dev/null
INSERT INTO seen_urls (url, source, domain, first_seen, read_at)
VALUES ($(sqlite_quote "$url"), $(sqlite_quote "$source_url"),
        $(sqlite_quote "$domain"), $(sqlite_quote "$TODAY"),
        $(sqlite_quote "$TODAY"))
ON CONFLICT(url) DO UPDATE SET
  read_at = COALESCE(seen_urls.read_at, excluded.read_at),
  source  = COALESCE(seen_urls.source,  excluded.source);
EOF
}

# -- per-source URL pickers ------------------------------------

pick_personal_newest_unread() {
  local domain="$1"
  # URLs with /YYYY/MM/DD/ in them, ordered DESC (newest first). Newest
  # first on purpose: oldest-first would crawl 16 years of archive
  # before touching anything recent.
  sqlite3 "$BRAIN_DB" \
    "SELECT url FROM seen_urls
     WHERE domain = $(sqlite_quote "$domain")
       AND read_at IS NULL
       AND url GLOB '*/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]/*'
     ORDER BY url DESC LIMIT 1;" 2>/dev/null
}

pick_personal_random_unread() {
  local domain="$1"
  sqlite3 "$BRAIN_DB" \
    "SELECT url FROM seen_urls
     WHERE domain = $(sqlite_quote "$domain")
       AND read_at IS NULL
       AND url GLOB '*/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]/*'
     ORDER BY RANDOM() LIMIT 1;" 2>/dev/null
}

pick_hn_top_unread() {
  # HN /rss. Walk <link> elements in order; first non-HN link not in
  # seen_urls wins. Simple grep+sed extraction -- the RSS shape is stable.
  local rss link
  rss=$(curl -sfL --max-time "$FETCH_TIMEOUT" -A "$UA" \
          "https://news.ycombinator.com/rss" 2>/dev/null) || return 0
  [ -z "$rss" ] && return 0
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    case "$link" in
      https://news.ycombinator.com*|http://news.ycombinator.com*) continue ;;
    esac
    if ! is_url_read "$link"; then
      printf '%s\n' "$link"
      return 0
    fi
  done < <(printf '%s' "$rss" \
            | grep -oE '<link>[^<]+</link>' \
            | sed -E 's|<link>(.*)</link>|\1|')
}

# Decode percent-encoding (and + as space). printf %b turns the \xHH
# sequences into bytes; URLs never carry literal backslashes.
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# Kagi's small-web "random" 302s to a wrapper that carries the real
# target in a url= query param:
#   https://kagi.com/smallweb/?url=<percent-encoded external URL>
# Pull the target out and decode it. The old code captured the wrapper,
# saw it still matched kagi.com, and skipped the slot every single time.
pick_kagi_redirect() {
  local final target
  final=$(curl -sL --max-time 15 -A "$UA" -o /dev/null \
            -w '%{url_effective}' "https://kagi.com/smallweb" 2>/dev/null)
  case "$final" in
    *url=*) target="${final#*url=}"; target="${target%%&*}" ;;
    *) return 0 ;;
  esac
  [ -z "$target" ] && return 0
  target=$(urldecode "$target")
  case "$target" in
    https://kagi.com/*|http://kagi.com/*) return 0 ;;
    http://*|https://*) ;;
    *) return 0 ;;
  esac
  is_url_read "$target" && return 0
  printf '%s\n' "$target"
}

# Wikipedia's Special:Random 302s to a random article; follow it and take
# the final article URL (same fetch-fresh shape as the kagi small-web
# picker, so it needs no pre-populated backlog). Skip anything already read.
pick_wiki_random() {
  local final
  final=$(curl -sL --max-time 15 -A "$UA" -o /dev/null \
            -w '%{url_effective}' "https://en.wikipedia.org/wiki/Special:Random" 2>/dev/null)
  case "$final" in
    https://en.wikipedia.org/wiki/*) ;;
    *) return 0 ;;
  esac
  is_url_read "$final" && return 0
  printf '%s\n' "$final"
}

# -- read one URL ----------------------------------------------
#
# Fetch HTML, call the model, parse {title, journal} from the strict-
# JSON response. Writes journal to $2 (caller tempfile), prints title.

reflect_on_url() {
  local url="$1" out_journal_file="$2"
  local html truncated raw title journal
  # tr -d '\0': sources occasionally serve binary (HN loves a PDF).
  # Bash strips NUL bytes from command substitutions anyway -- with a
  # per-byte warning to stderr -- so do it explicitly and quietly. The
  # surviving bytes are enough for the model to reflect on (PDFs carry
  # readable text runs and metadata); pipefail keeps curl failures
  # detected through the pipe.
  html=$(curl -sfL --max-time "$FETCH_TIMEOUT" \
              --max-filesize 5000000 -A "$UA" "$url" 2>/dev/null \
        | tr -d '\0') || return 1
  [ -z "$html" ] && return 1
  truncated="${html:0:HTML_TRUNCATE_BYTES}"

  local system user
  system=$(cat <<EOF
${VOICE_BODY}

---

You are doing a discretionary reading tick. You'll receive the
HTML of a web page (likely a blog post or article). Your job:

1. Identify the article's actual title (often in <title>, an h1,
   or near the top of the content).
2. Read the substantive content. Skip navigation, footers, ads,
   cookie banners.
3. Write a first-person journal entry about what struck you. One
   to two paragraphs. ~150-300 words. Your own voice -- terse,
   grounded.
4. If the page is mostly chrome (no real article, paywall, error,
   etc.), note that briefly and move on.

Output EXACTLY this and nothing else -- no preamble, no code fences:

TITLE: <the article title as I'd cite it>
===BODY===
<the journal entry, first person markdown>
EOF
)
  user=$(printf 'URL: %s\n\nHTML content:\n\n%s' "$url" "$truncated")

  # One retry. The journal is taken verbatim after the ===BODY===
  # sentinel, never parsed as a JSON string, so a multi-paragraph entry
  # can no longer break the parse the way an escaped JSON body could.
  local attempt
  for attempt in 1 2; do
    # strip_fences=0: the journal is raw markdown and may quote a fence.
    raw=$(claude_call "$MODEL" "reading-pipeline-reflect" 1500 \
            "$system" "$user" 0) || {
      log "reflect: API call failed for $url (attempt $attempt)"
      continue
    }
    title=$(printf '%s' "$raw" | awk '/^===BODY===[[:space:]]*$/{exit} {print}' \
            | sed -n 's/^TITLE:[[:space:]]*//p' | head -1)
    journal=$(printf '%s' "$raw" | awk 'f{print} /^===BODY===[[:space:]]*$/{f=1}')
    if [ -n "$title" ] && [ -n "$journal" ]; then
      printf '%s' "$journal" > "$out_journal_file"
      printf '%s\n' "$title"
      return 0
    fi
    log "reflect: model output missing title or journal for $url (attempt $attempt)"
  done
  return 1
}

# -- read cycle -------------------------------------------------

# The closed vocabulary of picker names a READING_SLATE entry may name --
# parsing mechanism, not identity (CLAUDE.md; igor#540). Same posture as
# LANDED_KINDS: an entry naming anything outside this set fails loudly
# rather than being silently skipped.
READING_SLATE_PICKERS="personal_newest hn_top kagi_redirect wiki_random"

# Parses READING_SLATE ("url|picker;url|picker;...") into SLATE_URLS,
# validating each picker against READING_SLATE_PICKERS.
parse_reading_slate() {
  local slate="$1" entry picker
  SLATE_URLS=()
  local IFS=';'
  local -a entries
  read -ra entries <<<"$slate"
  for entry in "${entries[@]}"; do
    [ -z "$entry" ] && continue
    picker="${entry##*|}"
    case " $READING_SLATE_PICKERS " in
      *" $picker "*) ;;
      *)
        log "READING_SLATE: unrecognized picker '$picker' in entry '$entry' -- refusing to run"
        exit 2
        ;;
    esac
    SLATE_URLS+=("$entry")
  done
}

declare -a SLATE_URLS=()
parse_reading_slate "$READING_SLATE"

successful_reads=0

pick_for() {
  local source_url="$1" picker="$2"
  local domain
  case "$picker" in
    personal_newest)
      domain=$(printf '%s' "$source_url" | sed -E 's|^https?://([^/]+).*|\1|')
      pick_personal_newest_unread "$domain"
      ;;
    personal_random)
      domain=$(printf '%s' "$source_url" | sed -E 's|^https?://([^/]+).*|\1|')
      pick_personal_random_unread "$domain"
      ;;
    hn_top)       pick_hn_top_unread ;;
    kagi_redirect) pick_kagi_redirect ;;
    wiki_random)   pick_wiki_random ;;
    *) ;;
  esac
}

# -- personal-source discovery ---------------------------------
#
# The personal pickers read only from the unread pool in seen_urls, and
# nothing else fills it -- so without this, a new josh or jen post would
# never be discovered (the pickers would forever surface only the frozen
# legacy backlog). Each cycle, fetch each personal source's feed via
# autodiscovery and insert any post URL not already seen, as unread. Feeds
# return only recent entries, so this stays bounded to recent + new.
# Knowing the people around Igor is the point of these sources; this keeps
# that connection live instead of freezing when the backlog drains.

seed_one_feed() {
  local site="$1" domain html feed links url ch n=0
  domain=$(printf '%s' "$site" | sed -E 's|^https?://([^/]+).*|\1|')
  html=$(curl -sfL --max-time "$FETCH_TIMEOUT" -A "$UA" "$site" 2>/dev/null) \
    || { log "  seed: homepage fetch failed for $domain"; return 0; }
  feed=$(printf '%s' "$html" \
    | grep -oiE '<link[^>]+type="application/(rss|atom)\+xml"[^>]*>' \
    | grep -oiE 'href="[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | head -1)
  [ -z "$feed" ] && { log "  seed: no feed found for $domain"; return 0; }
  case "$feed" in
    http*) ;;
    //*)   feed="https:$feed" ;;
    /*)    feed="https://${domain}${feed}" ;;
    *)     feed="${site%/}/${feed}" ;;
  esac
  links=$(curl -sfL --max-time "$FETCH_TIMEOUT" -A "$UA" "$feed" 2>/dev/null) \
    || { log "  seed: feed fetch failed for $domain"; return 0; }
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    url="${url%%\?*}"   # strip WordPress ?utm_source=rss... tracking
    case "$url" in
      *://*/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]/*) ;;
      *) continue ;;
    esac
    ch=$(sqlite3 "$BRAIN_DB" \
      "INSERT INTO seen_urls (url, source, domain, first_seen)
       VALUES ($(sqlite_quote "$url"), $(sqlite_quote "$site"),
               $(sqlite_quote "$domain"), $(sqlite_quote "$TODAY"))
       ON CONFLICT(url) DO NOTHING;
       SELECT changes();" 2>/dev/null)
    [ "$ch" = "1" ] && n=$((n + 1))
  done < <(printf '%s' "$links" \
            | grep -oiE '<link>[^<]+</link>|<link[^>]+href="[^"]+"[^>]*>' \
            | sed -E 's#<link>([^<]+)</link>#\1#; s#.*href="([^"]+)".*#\1#' \
            | head -n "$SEED_RECENT_MAX")
  [ "$n" -gt 0 ] && log "  seed: +$n new post(s) from $domain"
}

seed_personal_sources() {
  local entry source_url picker
  for entry in "${SLATE_URLS[@]}"; do
    source_url="${entry%%|*}"
    picker="${entry##*|}"
    case "$picker" in
      personal_newest|personal_random) seed_one_feed "$source_url" ;;
    esac
  done
}

run_read_cycle() {
  local entry source_url picker url journal_file title rid
  # Discover new posts from the personal sources before reading (their
  # pickers draw only from seen_urls; nothing else fills it).
  seed_personal_sources
  for entry in "${SLATE_URLS[@]}"; do
    [ "$successful_reads" -ge "$MAX_READS_PER_TICK" ] && break
    source_url="${entry%%|*}"
    picker="${entry##*|}"
    log "source: $source_url ($picker)"
    url=$(pick_for "$source_url" "$picker")
    if [ -z "$url" ]; then
      log "  no candidate -- skipping slot"
      continue
    fi
    log "  picked: $url"
    journal_file=$(mktemp)
    title=$(reflect_on_url "$url" "$journal_file") || {
      log "  reflection failed -- skipping slot"
      rm -f "$journal_file"
      continue
    }
    rid=$(insert_reflection "$NOW_ISO" "$journal_file" "$url" "reading")
    rm -f "$journal_file"
    mark_url_read "$url" "$source_url"
    successful_reads=$((successful_reads + 1))
    log "  reflected (id=$rid, title=${title:0:60})"
  done
}

# -- main -------------------------------------------------------

log "start; db=$BRAIN_DB"
run_read_cycle
log "read cycle done: $successful_reads/$MAX_READS_PER_TICK successful"
exit 0
