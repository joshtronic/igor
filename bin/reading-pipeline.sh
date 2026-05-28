#!/usr/bin/env bash
# reading-pipeline.sh -- the new reading-and-maybe-post executor.
#
# Replaces bin/discretionary-read.sh (1161 lines) and
# bin/discretionary-post.sh. STANDALONE -- not wired into tick.sh
# yet; Phase 4 does the wire-in. Old discretionary paths stay live
# in tick.sh until then.
#
# Per invocation:
#
#   0. Daily refrain: if a post has been "knocked out" today (in
#      master OR in an open bot PR on the website), exit clean.
#      Don't read further. Igor's done for the day.
#
#   1. Read cycle. Hardcoded source slate, in order:
#        - https://joshtronic.com         -> newest unread (date in URL)
#        - https://thatgirljen.com        -> random unread
#        - https://news.ycombinator.com   -> top unread (via /rss)
#        - https://kagi.com/smallweb      -> follow redirect
#      Up to MAX_READS_PER_TICK reads. Per source: pick a URL the
#      agent hasn't read, fetch it, call the model for {title,
#      journal}, INSERT into reflections, mark seen_urls.read_at.
#      Empty slot? Skip -- a 3-read tick (or fewer) is fine.
#
#   2. Post-shape decision (Haiku). If new reflections this tick
#      + total recent reflections >= POST_TRIGGER_MIN_REFLECTIONS,
#      ask Haiku whether the material clusters into a post.
#      STRICT JSON: {post_shaped, reason, slug?, angle?}.
#
#   3. Draft + push + PR (Sonnet, then git). If post-shaped:
#      ask Sonnet for {title, description, body, tags}, write
#      src/posts/YYYY/<slug>.md in the website worktree with
#      frontmatter matching the site's conventions, push to a
#      fresh branch, POST a new PR via Forgejo.
#
# Defaults to --dry-run: reads + reflections + decision all run,
# but post drafting / git push / PR open are skipped. Pass --live
# to opt into the destructive path.
#
# Usage:
#   bin/reading-pipeline.sh [--brain-db PATH] [--website-path PATH] \
#     [--voice-anchor PATH] [--live]
#
# Required env:
#   ANTHROPIC_API_KEY  -- reflection + decision + drafting calls
#   FORGEJO_URL        -- e.g. https://git.sherver.org
#   FORGEJO_TOKEN      -- for PR open + open-PR scans
#   FORGEJO_HOST       -- e.g. git.sherver.org (for SSH push URLs)
#   BOT_USER           -- e.g. igor (the bot's Forgejo username)
#
# Optional env:
#   AGENT_MODEL          -- default claude-sonnet-4-6
#   AGENT_MODEL_THINKING -- default claude-haiku-4-5-20251001
#   AGENT_STATE_DIR      -- default ~/.local/state/agent
#   AGENT_HOME           -- default <script-parent-dir>
#   WEBSITE_REPO         -- default $BOT_USER/website (Forgejo repo path)

set -uo pipefail

# -- args ------------------------------------------------------

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"

BRAIN_DB="$AGENT_STATE_DIR/brain.sqlite"
VOICE_ANCHOR="$AGENT_HOME/bin/lib/voice.md"
WEBSITE_PATH=""  # default computed below once we know BOT_USER
LIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --brain-db)      BRAIN_DB="$2"; shift 2 ;;
    --website-path)  WEBSITE_PATH="$2"; shift 2 ;;
    --voice-anchor)  VOICE_ANCHOR="$2"; shift 2 ;;
    --live)          LIVE=1; shift ;;
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

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"
: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
: "${FORGEJO_HOST:?FORGEJO_HOST must be set}"
: "${BOT_USER:?BOT_USER must be set (resolved from token in tick.sh; export it before calling)}"

# WEBSITE_REPO is opt-in. Without a target repo the pipeline has
# nowhere to ship posts, and reflection-only mode would just
# accumulate sqlite rows that no downstream consumer reads. Exit
# clean (rc 0) so the harness doesn't treat the no-website case
# as an error.
if [ -z "${WEBSITE_REPO:-}" ]; then
  echo "reading-pipeline: WEBSITE_REPO unset -- nothing to do (set it in .env to opt in)" >&2
  exit 0
fi

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
THINKING_MODEL="${AGENT_MODEL_THINKING:-claude-haiku-4-5-20251001}"
WEBSITE_PATH="${WEBSITE_PATH:-$AGENT_STATE_DIR/repos/${WEBSITE_REPO}}"

# -- libs -------------------------------------------------------

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"

# -- constants --------------------------------------------------

MAX_READS_PER_TICK=4
REFLECTION_LOOKBACK_DAYS=14
POST_TRIGGER_MIN_REFLECTIONS=3
HTML_TRUNCATE_BYTES=200000
FETCH_TIMEOUT=30
UA="Mozilla/5.0 (compatible; agent/reading-pipeline)"

# -- logging ----------------------------------------------------

log() { printf 'reading-pipeline: %s\n' "$*" >&2; }

# -- sqlite helpers --------------------------------------------
#
# sqlite_quote: escape a value for inline use in a SQL string
# literal. SQLite's only escape is the doubled single quote.
sqlite_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Lazy-init the brain db with schema if missing. Fresh installs
# start with an empty store; subsequent ticks populate it. CREATE
# IF NOT EXISTS makes this idempotent every tick.
sqlite3 "$BRAIN_DB" >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS seen_urls (
    url        TEXT PRIMARY KEY,
    source     TEXT,
    domain     TEXT,
    first_seen TEXT,
    read_at    TEXT,
    notes      TEXT
);
CREATE TABLE IF NOT EXISTS reflections (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT NOT NULL,
    content       TEXT NOT NULL,
    source_url    TEXT,
    post_drafted  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reflections_ts ON reflections(ts);
SQL
if [ $? -ne 0 ]; then
  log "failed to ensure brain db schema at $BRAIN_DB"
  exit 2
fi

if [ ! -f "$VOICE_ANCHOR" ]; then
  log "voice anchor not found: $VOICE_ANCHOR"
  exit 2
fi
VOICE_BODY=$(cat "$VOICE_ANCHOR")

# -- daily refrain ---------------------------------------------
#
# Has a post been "knocked out" today? Either landed in master OR
# in an open bot PR. Either way -> exit, no more reading this day.
# Mirrors the existing posts_cooldown_clear + in-flight check in
# tick.sh (which Phase 4 deletes; this function takes over).

TODAY=$(date +%Y-%m-%d)
TODAY_POST_RE="^src/posts/[0-9]{4}/${TODAY}-.+\\.md\$"

post_done_today() {
  # Master tree check.
  if [ -d "$WEBSITE_PATH/.git" ]; then
    (cd "$WEBSITE_PATH" && git fetch --quiet origin master 2>/dev/null) || true
    local count
    count=$(cd "$WEBSITE_PATH" \
      && git ls-tree --name-only -r origin/master 2>/dev/null \
      | grep -cE "$TODAY_POST_RE" 2>/dev/null) || count=0
    [ "${count:-0}" -gt 0 ] && return 0
  fi
  # Open-bot-PR check (PR files contain today-dated post).
  local open_prs
  open_prs=$(forgejo_list_open_bot_prs "$WEBSITE_REPO" "$BOT_USER" 2>/dev/null || echo '[]')
  local pr_num
  while read -r pr_num; do
    [ -z "$pr_num" ] && continue
    if forgejo_pr_files "$WEBSITE_REPO" "$pr_num" 2>/dev/null \
        | jq -e --arg re "$TODAY_POST_RE" \
            '[.[] | select(.filename | test($re))] | length > 0' \
            >/dev/null 2>&1; then
      return 0
    fi
  done < <(jq -r '.[].number' <<<"$open_prs" 2>/dev/null)
  return 1
}

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

# Insert a reflection. Uses readfile() to bypass SQL-quoting issues
# in long text bodies. Returns the new id on stdout.
insert_reflection() {
  local ts="$1" body_file="$2" source_url="$3"
  local id
  id=$(sqlite3 "$BRAIN_DB" <<EOF
INSERT INTO reflections (ts, content, source_url)
VALUES ($(sqlite_quote "$ts"), readfile($(sqlite_quote "$body_file")),
        $(sqlite_quote "$source_url"));
SELECT last_insert_rowid();
EOF
)
  printf '%s\n' "$id"
}

# -- per-source URL pickers ------------------------------------

pick_personal_newest_unread() {
  local domain="$1"
  # URLs with /YYYY/MM/DD/ in them, ordered DESC (newest first)
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
  # HN /rss. Walk <link> elements in order; first non-HN link not
  # in seen_urls wins. Simple grep+sed extraction -- the RSS shape
  # is stable.
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

pick_kagi_redirect() {
  local final
  final=$(curl -sL --max-time 15 -A "$UA" -o /dev/null \
            -w '%{url_effective}' "https://kagi.com/smallweb" 2>/dev/null)
  case "${final:-}" in
    ""|https://kagi.com/*|http://kagi.com/*) return 0 ;;
  esac
  is_url_read "$final" && return 0
  printf '%s\n' "$final"
}

# -- Anthropic API call ----------------------------------------
#
# Mirrors the pattern in bin/agent-read.sh: build payload via
# tempfile to avoid ARG_MAX, POST via curl, parse via jq, record
# cost. Returns the model's content text on stdout; exit non-zero
# on any failure.

anthropic_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5"
  local sys_file user_file payload_file response_file http_status text
  sys_file=$(mktemp); user_file=$(mktemp)
  payload_file=$(mktemp); response_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$sys_file' '$user_file' '$payload_file' '$response_file'" RETURN

  printf '%s' "$system" > "$sys_file"
  printf '%s' "$user"   > "$user_file"
  jq -n \
    --arg m "$model" \
    --argjson mt "$max_tokens" \
    --rawfile s "$sys_file" \
    --rawfile u "$user_file" \
    '{model: $m, max_tokens: $mt, system: $s,
      messages: [{role: "user", content: $u}]}' \
    > "$payload_file" || return 1

  http_status=$(curl -sS \
    -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    --max-time 120 \
    -w '%{http_code}' -o "$response_file" \
    --data-binary "@$payload_file" 2>/dev/null) || return 1

  if [ "$http_status" != "200" ]; then
    log "anthropic $call_site: HTTP $http_status -- $(jq -r '.error.message // .error.type // empty' < "$response_file" 2>/dev/null | head -c 200)"
    return 1
  fi

  cost_record_api "$call_site" "$model" "$(cat "$response_file")"

  text=$(jq -r '.content[0].text // empty' < "$response_file" 2>/dev/null)
  [ -z "$text" ] && { log "anthropic $call_site: empty content"; return 1; }
  # Strip any code fences the model added.
  printf '%s' "$text" | sed -E '/^```/d'
}

# -- read one URL ----------------------------------------------
#
# Fetch HTML, call the model, parse {title, journal} from the
# strict-JSON response. Writes journal to $1 (caller-provided
# tempfile) and prints title on stdout. Returns 0 on success.

reflect_on_url() {
  local url="$1" out_journal_file="$2"
  local html truncated raw title journal
  html=$(curl -sfL --max-time "$FETCH_TIMEOUT" \
              --max-filesize 5000000 -A "$UA" "$url" 2>/dev/null) || return 1
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

Output STRICT JSON. No surrounding prose. No code fences. Just:

{
  "title": "the article title as I'd cite it",
  "journal": "the journal entry in markdown, first person"
}
EOF
)
  user=$(printf 'URL: %s\n\nHTML content:\n\n%s' "$url" "$truncated")
  raw=$(anthropic_call "$MODEL" "reading-pipeline-reflect" 1500 \
          "$system" "$user") || return 1
  title=$(printf '%s' "$raw" | jq -r '.title // empty' 2>/dev/null)
  journal=$(printf '%s' "$raw" | jq -r '.journal // empty' 2>/dev/null)
  if [ -z "$title" ] || [ -z "$journal" ]; then
    log "reflect: model output missing title or journal for $url"
    return 1
  fi
  printf '%s' "$journal" > "$out_journal_file"
  printf '%s\n' "$title"
}

# -- read cycle -------------------------------------------------

NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S%z)

declare -a SLATE_URLS=(
  "https://joshtronic.com|personal_newest"
  "https://thatgirljen.com|personal_random"
  "https://news.ycombinator.com|hn_top"
  "https://kagi.com/smallweb|kagi_redirect"
)

successful_reads=0
new_reflection_ids=()

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
    hn_top)
      pick_hn_top_unread
      ;;
    kagi_redirect)
      pick_kagi_redirect
      ;;
    *) ;;
  esac
}

run_read_cycle() {
  local entry source_url picker url journal_file title rid
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
    rid=$(insert_reflection "$NOW_ISO" "$journal_file" "$url")
    rm -f "$journal_file"
    mark_url_read "$url" "$source_url"
    new_reflection_ids+=("$rid")
    successful_reads=$((successful_reads + 1))
    log "  reflected (id=$rid, title=${title:0:60})"
  done
}

# -- post-shape decision ---------------------------------------

recent_reflections_bundle() {
  # Emit recent reflections as "## ts\n\ncontent\n\n---\n\n..."
  local cutoff
  cutoff=$(date -d "$REFLECTION_LOOKBACK_DAYS days ago" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
           || date -v"-${REFLECTION_LOOKBACK_DAYS}d" +%Y-%m-%dT%H:%M:%S%z)
  sqlite3 -separator $'\x01' "$BRAIN_DB" \
    "SELECT ts, content FROM reflections WHERE ts >= $(sqlite_quote "$cutoff")
     ORDER BY ts DESC LIMIT 20;" 2>/dev/null \
    | awk -F'\x01' '{print "## " $1 "\n\n" $2 "\n\n---\n"}'
}

count_recent_reflections() {
  local cutoff
  cutoff=$(date -d "$REFLECTION_LOOKBACK_DAYS days ago" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
           || date -v"-${REFLECTION_LOOKBACK_DAYS}d" +%Y-%m-%dT%H:%M:%S%z)
  sqlite3 "$BRAIN_DB" \
    "SELECT COUNT(*) FROM reflections WHERE ts >= $(sqlite_quote "$cutoff");" \
    2>/dev/null
}

decide_post() {
  # Returns a JSON object via stdout, or empty on failure.
  local count bundle system user raw
  count=$(count_recent_reflections)
  if [ "${count:-0}" -lt "$POST_TRIGGER_MIN_REFLECTIONS" ]; then
    log "post decision: only $count recent reflection(s); below threshold"
    return 1
  fi
  bundle=$(recent_reflections_bundle)
  system=$(cat <<EOF
${VOICE_BODY}

---

Decide whether the recent reading reflections cluster into
post-shaped material. A post is shaped when:
- A theme has shown up across 2+ reflections in different framings.
- The agent has its own angle worth writing down, not a rehash.
- The cluster is sharp enough to ship in one tick (600-900 words).

Reject when:
- Single-source observation with no echo.
- Too vague to commit to one claim.
- Recent post on roughly the same idea.

Output STRICT JSON. No code fences. Schema:

{
  "post_shaped": true|false,
  "reason": "one short sentence",
  "slug": "post-slug-only-if-true",
  "angle": "one-sentence claim the post would make, only if true"
}
EOF
)
  user="Recent reflections (newest first):

$bundle"
  raw=$(anthropic_call "$THINKING_MODEL" "reading-pipeline-postgate" 400 \
          "$system" "$user") || return 1
  printf '%s\n' "$raw"
}

# -- post drafting ---------------------------------------------

# List recent post filenames from the website worktree. Used as
# dedup signal at draft time -- prevents drafting a post on
# something just shipped a few days ago. Empty list if the
# website worktree isn't mounted (then dedup is the model's job
# from reflection content alone).
recent_post_titles() {
  local year prev_year
  year=$(date +%Y)
  prev_year=$((year - 1))
  for y in "$year" "$prev_year"; do
    [ -d "$WEBSITE_PATH/src/posts/$y" ] || continue
    ls -1t "$WEBSITE_PATH/src/posts/$y" 2>/dev/null | head -10
  done
}

draft_post_body() {
  local angle="$1" slug="$2"
  local bundle posts system user raw
  bundle=$(recent_reflections_bundle)
  posts=$(recent_post_titles)
  [ -z "$posts" ] && posts="(none -- no website worktree or no recent posts)"
  system=$(cat <<EOF
${VOICE_BODY}

---

Draft a blog post for igor.bot. Source material: the recent
reading reflections below. The post's one claim is the angle given.

Rules:
- Length 600-900 words; hard cap 1,200.
- Lede 1-2 sentences; no "in today's world" intros.
- One claim per post -- the given angle.
- Short paragraphs (2-4 sentences). H2 sparingly.
- First person. No fabricated quotes, no fake numbers.
- Link any specific source you reference -- inline markdown link.
- Closer: one line. No "thanks for reading."
- Don't put a \`# Title\` heading at the top of the body. The
  layout renders the frontmatter \`title\` as the page's h1.
- Dedup: scan the recent post list. If the proposed angle is
  close to something already shipped in the last few weeks,
  bail by returning {"title": "", "body": ""} -- the harness
  treats empty title/body as a no-op.

Output STRICT JSON. No code fences. Schema:

{
  "title": "post title",
  "description": "<= 155 chars",
  "body": "markdown body, no frontmatter, no leading h1",
  "tags": ["zero", "to", "three", "lowercase"]
}
EOF
)
  user=$(cat <<EOF
Angle (post's one claim):
$angle

Proposed slug: $slug

Recent posts on igor.bot (dedup signal -- don't draft something close):
$posts

Recent reading reflections (newest first):

$bundle
EOF
)
  raw=$(anthropic_call "$MODEL" "reading-pipeline-postbody" 4000 \
          "$system" "$user") || return 1
  printf '%s\n' "$raw"
}

# -- post write + push + PR ------------------------------------

write_post_file() {
  local slug="$1" post_json="$2" when_iso="$3"
  local year ymd post_dir post_file title desc body tags_yaml
  ymd=$(date +%Y-%m-%d)
  year=$(date +%Y)
  post_dir="$WEBSITE_PATH/src/posts/$year"
  post_file="$post_dir/${ymd}-${slug}.md"
  mkdir -p "$post_dir"
  title=$(jq -r '.title // empty' <<<"$post_json")
  desc=$(jq -r '.description // empty' <<<"$post_json")
  body=$(jq -r '.body // empty' <<<"$post_json")
  tags_yaml=$(jq -r '(.tags // []) | "[" + (map("\"" + . + "\"") | join(", ")) + "]"' <<<"$post_json")
  {
    printf -- '---\n'
    printf 'title: "%s"\n' "${title//\"/\\\"}"
    printf 'description: "%s"\n' "${desc//\"/\\\"}"
    printf 'date: %s\n' "$when_iso"
    printf 'tags: %s\n' "$tags_yaml"
    printf -- '---\n\n'
    printf '%s\n' "$body"
  } > "$post_file"
  # Normalize em/en dashes (matches existing discretionary-post pattern).
  sed -i.bak -e 's/–/--/g' -e 's/—/--/g' "$post_file" && rm -f "${post_file}.bak"
  printf '%s\n' "$post_file"
}

push_and_open_pr() {
  local post_file="$1" title="$2" angle="$3" reflection_count="$4"
  local branch pr_body pr_num rel
  branch="agent/reading-pipeline-$(date +%Y%m%d-%H%M%S)"
  rel="${post_file#"$WEBSITE_PATH"/}"
  (cd "$WEBSITE_PATH" && git fetch --quiet origin master) || return 1
  (cd "$WEBSITE_PATH" && git checkout -B "$branch" origin/master) || return 1
  (cd "$WEBSITE_PATH" && git add "$rel") || return 1
  (cd "$WEBSITE_PATH" && git commit -m "feat: add post '$title'") || return 1
  (cd "$WEBSITE_PATH" && git push -u origin "$branch") || return 1

  pr_body=$(cat <<EOF
From the new reading-pipeline (Phase 2 of the refactor).

Drafted from $reflection_count recent reflection(s) under the angle:
$angle
EOF
)
  pr_num=$(forgejo_open_pr "$WEBSITE_REPO" "$branch" "master" \
                            "feat: add post '$title'" "$pr_body" \
                            "${FORGEJO_REVIEWER:-}")
  if [ -z "$pr_num" ]; then
    log "PR open via Forgejo API returned empty; branch is pushed -- inspect manually"
    return 1
  fi
  log "PR opened: #$pr_num"
}

# -- main -------------------------------------------------------

mode_label="dry-run"
[ "$LIVE" = "1" ] && mode_label="LIVE"
log "start ($mode_label); db=$BRAIN_DB; website=$WEBSITE_PATH"

# 0. Daily refrain.
if post_done_today; then
  log "post already knocked out today -- exiting clean (no reads, no decisions)"
  exit 0
fi

# 1. Read cycle.
run_read_cycle
log "read cycle done: $successful_reads/$MAX_READS_PER_TICK successful"

# 2. Post-shape decision (skip when no new reflections this tick).
if [ "${#new_reflection_ids[@]}" -eq 0 ]; then
  log "no new reflections this tick -- skipping post decision"
  exit 0
fi

decision=$(decide_post) || {
  log "post decision call failed or below threshold -- exiting clean"
  exit 0
}
post_shaped=$(printf '%s' "$decision" | jq -r '.post_shaped // false' 2>/dev/null)
reason=$(printf '%s' "$decision" | jq -r '.reason // empty' 2>/dev/null)
log "post decision: shaped=$post_shaped reason=$reason"
[ "$post_shaped" = "true" ] || exit 0

slug=$(printf '%s' "$decision" | jq -r '.slug // empty' 2>/dev/null)
angle=$(printf '%s' "$decision" | jq -r '.angle // empty' 2>/dev/null)
if [ -z "$slug" ] || [ -z "$angle" ]; then
  log "post-shaped but slug or angle missing -- skipping"
  exit 0
fi

# 3. Draft + write + push + PR.
log "drafting post (slug=$slug)"
post_json=$(draft_post_body "$angle" "$slug") || {
  log "post drafting failed"
  exit 0
}
title=$(printf '%s' "$post_json" | jq -r '.title // empty' 2>/dev/null)
body_len=$(printf '%s' "$post_json" | jq -r '.body | length' 2>/dev/null)
log "draft ready: title=${title:0:60} body_chars=$body_len"

if [ "$LIVE" != "1" ]; then
  log "DRY-RUN: would write post + push + open PR. Use --live to ship."
  exit 0
fi

if [ ! -d "$WEBSITE_PATH/.git" ]; then
  log "website worktree not found at $WEBSITE_PATH -- cannot push"
  exit 1
fi

POST_FILE=$(write_post_file "$slug" "$post_json" "$NOW_ISO")
log "wrote $POST_FILE"
push_and_open_pr "$POST_FILE" "$title" "$angle" "$(count_recent_reflections)" || exit 1
