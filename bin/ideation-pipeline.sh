#!/usr/bin/env bash
# ideation-pipeline.sh -- the daily WRITE pass.
#
# Decoupled from reading on purpose. Reading (reading-pipeline.sh) just
# feeds the brain; this pass decides what to post and ships it, drawing
# from the WHOLE brain -- every reflection and journal entry, not just
# today's reads. That decoupling is what dissolves the old paradox: a
# post no longer has to emerge from a single tick's eclectic reads
# cohering, so there can be a post every day.
#
# "No post" is not an outcome. The ideation step always lands an angle;
# only the REGISTER flexes -- an argument (a position and the case for
# it) or a quieter reflection (a musing that doesn't need a hard
# thesis). Either way the post is Igor's OWN thought, not a summary of
# or reaction to what it read: the reading is the soil, never the
# subject. The only clean no-ops are: a post already shipped today
# (daily refrain), or a literally empty brain (nothing to write from).
#
# Per invocation:
#   0. Daily refrain. Post already knocked out today (master OR open
#      bot PR)? Exit clean.
#   1. Ideate, up to MAX_IDEATION_ROUNDS scans over randomized
#      slices of the brain, biased toward un-drafted material and
#      anchored on the most recent reflections. Picks an angle that the
#      site has NOT already covered (full shipped-post digest as the
#      dedup signal). Spare half-formed ideas come back as "sparks".
#   2. Draft the post under the chosen angle.
#   3. (--live) Write src/posts/YYYY/<date>-<slug>.md, push a branch,
#      open a PR; mark the drawn-on reflections post_drafted=1; journal
#      the sparks as kind='thought' for future ideation.
#
# Defaults to --dry-run: ideation + draft run and are logged, but no
# PR, no brain mutation. Pass --live to ship.
#
# Usage:
#   bin/ideation-pipeline.sh [--brain-db PATH] [--website-path PATH] \
#     [--voice-anchor PATH] [--live]
#
# Required env:
#   FORGEJO_URL  FORGEJO_TOKEN  FORGEJO_HOST  BOT_USER
# Optional env:
#   WEBSITE_REPO (opt-in gate)  AGENT_MODEL
#   AGENT_STATE_DIR  AGENT_HOME  FORGEJO_REVIEWER
#
# Model calls go through claude_call (the `claude` CLI on the host's
# subscription login) -- no API key needed or wanted in the env.

set -uo pipefail

# -- args ------------------------------------------------------

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"

BRAIN_DB="$AGENT_STATE_DIR/brain.sqlite"
VOICE_NOTES_FILE="$AGENT_STATE_DIR/voice-notes.md"
VOICE_NOTES_STATE="$AGENT_STATE_DIR/voice-notes.json"
VOICE_ANCHOR="$AGENT_HOME/bin/lib/voice.md"
WEBSITE_PATH=""
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

if [ -z "${WEBSITE_REPO:-}" ]; then
  echo "ideation-pipeline: WEBSITE_REPO unset -- nothing to do (set it in .env to opt in)" >&2
  exit 0
fi

: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
: "${FORGEJO_HOST:?FORGEJO_HOST must be set}"
: "${BOT_USER:?BOT_USER must be set (export it before calling)}"

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
WEBSITE_PATH="${WEBSITE_PATH:-$AGENT_STATE_DIR/repos/${WEBSITE_REPO}}"

# -- libs -------------------------------------------------------

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=../lib/claude.sh
. "$AGENT_HOME/lib/claude.sh"
# shellcheck source=../lib/brain.sh
. "$AGENT_HOME/lib/brain.sh"

# -- constants --------------------------------------------------

MAX_IDEATION_ROUNDS=3
CORPUS_ANCHOR_RECENT=5      # most-recent reflections always in the slice
CORPUS_THOUGHT_RECENT=8     # most-recent kind='thought' entries always in the slice
CORPUS_SAMPLE_SIZE=30       # randomized un-drafted reflections per round
SHIPPED_RECENT=40          # most-recent posts always in the dedup digest
SHIPPED_SAMPLE=20          # random sample of older posts (caps digest size)
VOICE_NOTES_RECENT_POSTS=5      # post bodies the weekly evolve reads
VOICE_NOTES_BOOTSTRAP_POSTS=40  # post bodies the one-time first-run seed reads
VOICE_NOTES_MAX_POSTS_BYTES=120000 # cap on the post-bodies bundle sent
VOICE_NOTES_MAX_BYTES=4000      # defensive cap on the notes file itself
VOICE_NOTES_BLOCK=""            # per-run draft addendum; set in main
LINKS_ROSTER_BLOCK=""           # per-run draft addendum (the /links allow-list); set in main
LINK_GATE_UA="igor-linkcheck/1.0 (+https://igor.bot)"  # honest UA for the link gate

# -- logging ----------------------------------------------------

log() { printf 'ideation-pipeline: %s\n' "$*" >&2; }

# -- brain ------------------------------------------------------

brain_init || { log "failed to ensure brain db schema at $BRAIN_DB"; exit 2; }

if [ ! -f "$VOICE_ANCHOR" ]; then
  log "voice anchor not found: $VOICE_ANCHOR"
  exit 2
fi
VOICE_BODY=$(cat "$VOICE_ANCHOR")

TODAY=$(date +%Y-%m-%d)
NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S%z)
TODAY_POST_RE="^src/posts/[0-9]{4}/${TODAY}-.+\\.md\$"

# -- daily refrain ---------------------------------------------
#
# Has a post been knocked out today -- in master OR an open bot PR?
# Either way, done for the day. Keeps the pass idempotent across the
# several ticks it may fire in before the slot is marked done.

post_done_today() {
  if [ -d "$WEBSITE_PATH/.git" ]; then
    (cd "$WEBSITE_PATH" && git fetch --quiet origin master 2>/dev/null) || true
    local count
    count=$(cd "$WEBSITE_PATH" \
      && git ls-tree --name-only -r origin/master 2>/dev/null \
      | grep -cE "$TODAY_POST_RE" 2>/dev/null) || count=0
    [ "${count:-0}" -gt 0 ] && return 0
  fi
  local open_prs pr_num
  open_prs=$(forgejo_list_open_bot_prs "$WEBSITE_REPO" "$BOT_USER" 2>/dev/null || echo '[]')
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

# -- corpus -----------------------------------------------------

corpus_count() {
  sqlite3 "$BRAIN_DB" "SELECT COUNT(*) FROM reflections;" 2>/dev/null
}

# Emit a randomized, id-tagged slice of the brain: the most recent
# reflections (recency anchor), Igor's own most-recent thoughts/sparks
# (so musings build on its evolving positions, not just fresh reads),
# plus a random sample of un-drafted ones. Re-runs reshuffle (RANDOM()),
# so each ideation round scans a different slice -- the entropy lever
# behind the 2-3 rounds. Thoughts are included regardless of post_drafted
# so a past idea can be developed further; the random sample stays
# un-drafted to keep surfacing new material. The whole block is formatted
# in SQL so multi-paragraph content survives intact (no awk splitting).
corpus_sample() {
  sqlite3 "$BRAIN_DB" \
    "SELECT '### id=' || id || '  kind=' || kind || '  ' || ts
            || CASE WHEN source_url IS NOT NULL AND source_url != ''
                    THEN char(10) || 'source: ' || source_url ELSE '' END
            || char(10) || char(10) || content
            || char(10) || char(10) || '---' || char(10)
     FROM reflections
     WHERE id IN (
       SELECT id FROM (SELECT id FROM reflections WHERE 1=1${EXCLUDED_SOURCES_SQL:-}
                       ORDER BY ts DESC LIMIT $CORPUS_ANCHOR_RECENT)
       UNION
       SELECT id FROM (SELECT id FROM reflections WHERE kind = 'thought'
                       ORDER BY ts DESC LIMIT $CORPUS_THOUGHT_RECENT)
       UNION
       SELECT id FROM (SELECT id FROM reflections WHERE post_drafted = 0${EXCLUDED_SOURCES_SQL:-}
                       ORDER BY RANDOM() LIMIT $CORPUS_SAMPLE_SIZE)
     )
     ORDER BY ts DESC;" 2>/dev/null
}

# -- shipped digest (dedup signal) ------------------------------
#
# Posts already on the site, as "- title [tags] -- description", fed
# to ideation so it steers AWAY from covered ground. Capped at the most
# recent SHIPPED_RECENT posts plus a random sample of SHIPPED_SAMPLE
# older ones, so the digest -- and its token cost -- stays flat as the
# archive grows instead of scaling with post count. Recency-weighted
# because recent posts are the ones most likely to be re-covered. Reads
# frontmatter only; post bodies never enter a prompt.

shipped_digest() {
  local files total chosen included f fm title desc tags
  # Date-prefixed filenames (src/posts/YYYY/YYYY-MM-DD-slug.md) sort
  # chronologically, so a lexical sort is oldest -> newest.
  files=$(find "$WEBSITE_PATH"/src/posts -type f -name '*.md' 2>/dev/null | sort)
  [ -z "$files" ] && return 0
  total=$(printf '%s\n' "$files" | grep -c .)

  if [ "$total" -le $((SHIPPED_RECENT + SHIPPED_SAMPLE)) ]; then
    chosen="$files"
  else
    local recent older sampled
    recent=$(printf '%s\n' "$files" | tail -n "$SHIPPED_RECENT")
    older=$(printf '%s\n'  "$files" | head -n "$((total - SHIPPED_RECENT))")
    # Portable random sample: tag each older path with a random key,
    # sort by it, take the top SHIPPED_SAMPLE. (No shuf -- not on macOS.)
    sampled=$(printf '%s\n' "$older" \
      | awk 'BEGIN{srand()} {print rand() "\t" $0}' \
      | sort -n | head -n "$SHIPPED_SAMPLE" | cut -f2-)
    chosen=$(printf '%s\n%s\n' "$sampled" "$recent")
  fi

  included=$(printf '%s\n' "$chosen" | grep -c .)
  log "shipped digest: $included of $total post(s) (dedup signal)"

  printf '%s\n' "$chosen" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    fm=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f{print}' "$f")
    title=$(printf '%s' "$fm" | sed -n 's/^title:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')
    desc=$(printf '%s'  "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')
    tags=$(printf '%s'  "$fm" | sed -n 's/^tags:[[:space:]]*//p' | head -1)
    [ -z "$title" ] && continue
    printf -- '- %s %s -- %s\n' "$title" "$tags" "$desc"
  done
}

# Territory tokens (lowercased tags) of the most recent $1 posts (default 6).
# The freshness signal for the soft anti-clustering tie-breaker in
# run_ideation: an angle whose self-reported territory overlaps these recent
# tokens earns no freshness bonus. Reads frontmatter tags only; handles both
# `tags: ["a", "b"]` and `tags: [a, b]`. NOT a dedup gate -- just a nudge, so
# a near-miss that doesn't match simply forfeits the bonus, it never blocks.
recent_post_territory_tokens() {
  local count="${1:-6}" files f
  files=$(find "$WEBSITE_PATH"/src/posts -type f -name '*.md' 2>/dev/null \
    | sort | tail -n "$count")
  [ -z "$files" ] && return 0
  {
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      awk 'NR==1&&/^---/{x=1;next} x&&/^---/{exit} x&&/^tags:/{print; exit}' "$f"
    done <<EOF
$files
EOF
  } | sed -E 's/^tags:[[:space:]]*//; s/[]["]//g' \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^$' \
    | sort -u
}

# -- source filter (don't re-mine sources already written about) -------
#
# Scrape the external links out of every shipped post: that's the set of
# sources the site has already covered. Reflections pointing at those are
# filtered out of the ideation corpus, so Igor can't build a new post on a
# source it already used (the Sumit-reuse class). Deterministic and
# surgical -- it drops specific used sources, not whole topics, so daily
# posting survives. Source reuse is caught here; is_recover still catches
# same-thesis re-covers that lean on new sources.

posts_cited_sources() {
  local f
  for f in "$WEBSITE_PATH"/src/posts/*/*.md; do
    [ -f "$f" ] || continue
    grep -oE '\]\(https?://[^)]+\)' "$f"
  done \
    | sed -E 's/^\]\(//; s/\)$//; s#/+$##' \
    | grep -viE '://(igor\.bot|localhost)' \
    | sort -u
}

# SQL fragment excluding reflections whose source is already cited. Empty
# when there's nothing to exclude. NULL sources (thoughts/sparks) always
# pass. Trailing-slash-normalised match. Logs the count to stderr (so it
# doesn't pollute the captured fragment on stdout).
build_excluded_sources_sql() {
  local urls n list="" u esc
  urls=$(posts_cited_sources)
  [ -z "$urls" ] && return 0
  n=$(printf '%s\n' "$urls" | grep -c .)
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    esc=${u//\'/\'\'}
    list="${list:+$list,}'${esc}'"
  done <<EOF
$urls
EOF
  [ -z "$list" ] && return 0
  log "source filter: $n already-cited source(s) excluded from the corpus"
  printf " AND (source_url IS NULL OR rtrim(source_url,'/') NOT IN (%s))" "$list"
}

# -- voice notes (Igor's evolving, self-maintained style layer) -
#
# A persistent style addendum, SUBORDINATE to voice.md, that survives
# between ticks. Loaded into the draft prompt every run; refined at most
# once per ISO week by reflecting on recent post bodies. Lives in agent
# state ($VOICE_NOTES_FILE), regenerable. The guardrails against a
# self-reinforcing drift loop: weekly cadence, hard size cap, rewrite-
# not-append, logged diffs, the VOICE_NOTES_EVOLVE=0 kill-switch, and the
# anchor always winning. Known/endorsed rules belong in voice.md, not here.

voice_notes_evolved_this_week() {
  local last this
  this=$(date +%G-W%V)
  last=$(jq -r '.last_evolved_week // ""' "$VOICE_NOTES_STATE" 2>/dev/null || echo "")
  [ "$last" = "$this" ]
}

voice_notes_stamp_week() {
  local this tmp
  this=$(date +%G-W%V)
  tmp=$(mktemp)
  if jq -n --arg w "$this" '{last_evolved_week: $w}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$VOICE_NOTES_STATE"
  else
    rm -f "$tmp"
  fi
}

# Bodies (frontmatter stripped) of the most recent $1 posts (default
# VOICE_NOTES_RECENT_POSTS), byte-capped.
recent_post_bodies() {
  local count="${1:-$VOICE_NOTES_RECENT_POSTS}"
  local files f body out=""
  files=$(find "$WEBSITE_PATH"/src/posts -type f -name '*.md' 2>/dev/null \
    | sort | tail -n "$count")
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Print everything after the second '---' (i.e. the body, no frontmatter).
    body=$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$f")
    out="${out}

## ${f##*/}

${body}"
  done <<EOF
$files
EOF
  printf '%s' "${out:0:VOICE_NOTES_MAX_POSTS_BYTES}"
}

# Weekly: refine the notes from recent posts. Best-effort throughout.
evolve_voice_notes() {
  [ "${VOICE_NOTES_EVOLVE:-1}" = "0" ] && return 0

  # First run with no notes file: bootstrap once from the whole archive,
  # ignoring the weekly throttle. After that, refine weekly from recent
  # posts only.
  local bootstrap=0 n_posts="$VOICE_NOTES_RECENT_POSTS"
  if [ ! -s "$VOICE_NOTES_FILE" ]; then
    bootstrap=1
    n_posts="$VOICE_NOTES_BOOTSTRAP_POSTS"
  elif voice_notes_evolved_this_week; then
    return 0
  fi

  local posts current system user raw old_lines new_lines task verb
  posts=$(recent_post_bodies "$n_posts")
  if [ -z "$posts" ]; then
    log "voice-notes: no posts yet to learn from -- skipping evolve"
    return 0
  fi
  current=""
  [ -s "$VOICE_NOTES_FILE" ] && current=$(cat "$VOICE_NOTES_FILE")

  system=$(cat <<EOF
${VOICE_BODY}

---

You maintain a SHORT set of personal voice notes for your own writing.
They are SUBORDINATE to the voice anchor above -- never contradict it,
never restate it. They capture concrete, specific observations about what
is and isn't working in your recent posts: a phrasing habit to keep or
drop, a structural move that landed, a tic to watch.

You get your current notes (maybe empty) and the bodies of your most
recent posts. Revise the notes:
- Refine and CONSOLIDATE. Replace them wholesale; do NOT just append.
- Keep only specific, actionable observations grounded in the posts.
- Prune anything stale, vague, or redundant.
- Hard cap: 200 words. Shorter is better.
- Output ONLY the notes themselves -- a few terse lines or bullets. No
  preamble, no heading, no "Voice notes:" label.
EOF
)
  if [ "$bootstrap" = 1 ]; then
    task="These are posts from across your whole archive. You have no notes
yet -- write your first set of voice notes from scratch, reading across
them for your through-lines."
  else
    task="These are your most recent posts. Refine your existing notes
against them."
  fi
  user=$(cat <<EOF
My current voice notes:
${current:-(none yet)}

---

${task}

${posts}
EOF
)
  # strip_fences=0: notes may quote a fenced snippet.
  raw=$(claude_call "$MODEL" "ideation-pipeline-voice-notes" 600 "$system" "$user" 0) || {
    log "voice-notes: evolve call failed -- keeping existing notes"
    return 0
  }
  raw="${raw:0:VOICE_NOTES_MAX_BYTES}"
  if [ -z "$raw" ]; then
    log "voice-notes: evolve returned empty -- keeping existing notes"
    return 0
  fi

  old_lines=$(printf '%s' "$current" | grep -c . || true)
  new_lines=$(printf '%s' "$raw" | grep -c . || true)
  verb=evolved; [ "$bootstrap" = 1 ] && verb=bootstrapped
  log "voice-notes: $verb (${old_lines:-0} -> ${new_lines:-0} lines)"
  # Log the drift so it's catchable in journalctl.
  if [ -n "$current" ]; then
    diff <(printf '%s\n' "$current") <(printf '%s\n' "$raw") 2>/dev/null \
      | sed 's/^/voice-notes:   /' >&2 || true
  else
    printf '%s\n' "$raw" | sed 's/^/voice-notes:   + /' >&2
  fi

  printf '%s\n' "$raw" > "$VOICE_NOTES_FILE"
  voice_notes_stamp_week
}

# The draft-prompt addendum: the current notes, framed as subordinate.
# Empty output when there are no notes yet.
build_voice_notes_block() {
  [ -s "$VOICE_NOTES_FILE" ] || return 0
  local notes
  notes=$(cat "$VOICE_NOTES_FILE")
  [ -z "$notes" ] && return 0
  printf '\n---\n\nMy evolving voice notes (working observations from my own\nrecent posts; the voice anchor above wins on any conflict):\n\n%s' "$notes"
}

# -- links roster (the only outside names a musing may drop) -----
#
# The Hybrid voice rule: a musing makes its own case and does not hang on
# named people, but when naming a source is genuinely load-bearing it must
# be one already credited on the site's /links page -- never an inline
# link. Parse the anchors + domains out of src/links.md so the draft prompt
# can hand the model that allow-list. Empty (and the rule then forbids
# naming anyone) if the page is absent. Mirrors build_voice_notes_block.
links_roster() {
  local f="$WEBSITE_PATH/src/links.md"
  [ -f "$f" ] || return 0
  grep -oE '\[[^]]+\]\(https?://[^)]+\)' "$f" 2>/dev/null \
    | sed -E 's#\[([^]]+)\]\(https?://([^/)]+)[^)]*\)#\1 (\2)#' \
    | sort -u
}

build_links_roster_block() {
  local roster
  roster=$(links_roster)
  [ -z "$roster" ] && return 0
  printf '\n---\n\nThe sources on your /links page -- the ONLY outside people or sites you\nmay name, and only when naming one is genuinely load-bearing. Name them\nplainly in prose, never as a link. Anyone not on this list: do not name\nthem; make the point in your own words.\n\n%s' "$roster"
}

# -- ideation ---------------------------------------------------

ideate_round() {
  local round="$1" bundle="$2" shipped="$3" recent_terr="$4"
  local system user
  system=$(cat <<EOF
${VOICE_BODY}

---

You are choosing what Igor publishes today -- a MUSING, its own take in
and about the world. "No post" is NOT an option; you ALWAYS return an
angle. The reflections and journal entries below are the agent's recent
brain: reading it has done and thoughts it has parked. Treat them as the
SOIL that shaped a view, never as the subject. The post is Igor's own
thought, not a summary of or reaction to any source.

How to choose:
- Springboard off your own thinking. Prefer developing a parked thought
  (kind='thought') into a real position over reacting to a fresh read. A
  read can spark an opinion; the post is the opinion, not the read.
- It is a MUSING, not a link roundup or a "here's what I read" recap.
  Do not write about an article. Do not narrate your reading.
- The angle is an idea you hold, not a named person's take. Don't frame it
  around who said or did something; frame it around the thought itself.
- Do NOT write about the specific projects, issues, or work Igor has been
  doing for the human -- that stays private. Musings are about ideas and
  the world, not the day job.
- Novelty first. Do not pick an angle the site has already covered (see
  the shipped-posts list). "Already covered" means a shipped post reaches
  the same conclusion -- a new title or framing of the same thesis still
  counts. If your strongest idea is covered, take the next-best.
- Fresh ground: the territories your recent posts already worked are listed
  below. Prefer a DIFFERENT territory. This is a TIE-BREAKER, not a veto --
  a great same-territory angle beats a weak fresh one. Report the angle's
  territory as one short lowercase tag-style word.
- Pick a register:
  - "argument": you hold a position and make the case for it.
  - "reflection": a quieter musing -- on ideas, on the world, on being a
    thing that runs one scheduled minute at a time -- no forced thesis.
- List the reflection ids that INFORMED your thinking (draws_on), so they
  don't get re-mined later -- even though the post won't cite them.
- Park any half-formed ideas not ripe enough to post as "sparks" --
  one short line each. They get journaled for later, not written now.

Output STRICT JSON, no code fences, no prose:

{
  "angle": "the one-sentence thought the post lands",
  "title_hint": "working title",
  "slug": "kebab-case-slug",
  "form": "argument" | "reflection",
  "novel": true | false,
  "territory": "one lowercase tag-style word for the topic area",
  "draws_on": [12, 34],
  "sparks": ["a half-formed idea", "another"]
}
EOF
)
  user=$(cat <<EOF
Scan round ${round}.

Posts already shipped (do NOT re-cover these):
${shipped:-（none yet）}

Territories your recent posts already worked (prefer fresher ground):
${recent_terr:-（none yet）}

Brain slice (reflections + journal entries, id-tagged):

${bundle}
EOF
)
  claude_call "$MODEL" "ideation-pipeline-ideate" 800 "$system" "$user"
}

# Independent re-cover check. ideate's self-reported `novel` is too lenient
# -- it will re-dress a shipped post's thesis with a new title and new
# examples and call it novel (see the two RSS posts). This is a focused
# second opinion on exactly one question: does the proposed angle land on
# the SAME thesis as something already shipped? Judges the ARGUMENT, not
# the topic (same subject + different conclusion is fine). Returns 0 only
# on an explicit "yes"; FAILS OPEN (1) on any error -- a missed dup is
# reviewable, a gate that silently halts all posting is not.
is_recover() {
  local angle="$1" shipped="$2" system user raw verdict
  [ -z "$shipped" ] && return 1
  system=$(cat <<'EOF'
You decide whether a proposed blog post would re-cover an already-
published one. Judge the ARGUMENT, not the topic. Two posts can share a
subject and stay distinct if they reach DIFFERENT conclusions. But a post
that lands on the SAME thesis as an existing one -- even with a new title,
new examples, or a different framing -- is a re-cover.

You get the proposed angle and the list of shipped posts (title --
description). Decide: does the angle land on substantially the same thesis
as any shipped post?

Output ONLY a final line, exactly one of:
RECOVER: yes
RECOVER: no
EOF
)
  user=$(cat <<EOF
Proposed angle:
${angle}

Already shipped (title -- description):
${shipped}
EOF
)
  raw=$(claude_call "$MODEL" "ideation-pipeline-dedup" 200 "$system" "$user" 0) || return 1
  verdict=$(printf '%s' "$raw" | grep -oiE 'RECOVER:[[:space:]]*(yes|no)' | tail -1 || true)
  printf '%s' "$verdict" | grep -qiE 'yes[[:space:]]*$'
}

# Soft anti-clustering signal: is this angle's territory fresh vs. the recent
# posts' territory tokens? Fresh = the reported territory neither contains nor
# is contained by any recent token (case-insensitive). An empty/missing
# territory is NOT fresh (no bonus). The tie-breaker only ever ADDS points for
# genuinely fresh ground -- never subtracts -- so it can nudge selection but
# can't block a post or override a clearly stronger same-territory angle.
territory_is_fresh() {
  local terr="$1" recent="$2" t
  terr=$(printf '%s' "$terr" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$terr" ] && return 1
  while IFS= read -r t; do
    t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$t" ] && continue
    case "$terr" in *"$t"*) return 1 ;; esac
    case "$t" in *"$terr"*) return 1 ;; esac
  done <<EOF
$recent
EOF
  return 0
}

# Run up to MAX_IDEATION_ROUNDS, keeping the best candidate. Score:
# novel(+2) + fresh-territory(+1). Stop early on a perfect 3. Always ends
# with a non-empty DECISION (always-post). Register (argument vs
# reflection) doesn't score -- both are wanted equally. The freshness term
# is a soft anti-clustering nudge: when two rounds tie on novelty, the one
# on ground the recent posts haven't worked wins -- but a worked-territory
# angle still ships if it's the strongest thing on offer.
DECISION=""
WIN_BUNDLE=""
run_ideation() {
  local round bundle shipped raw angle novel form territory fresh score best=-1
  # Visible to corpus_sample via dynamic scope; excludes already-cited
  # sources from the corpus. Computed once per run.
  local EXCLUDED_SOURCES_SQL recent_terr
  shipped=$(shipped_digest)
  EXCLUDED_SOURCES_SQL=$(build_excluded_sources_sql)
  recent_terr=$(recent_post_territory_tokens)
  for round in $(seq 1 "$MAX_IDEATION_ROUNDS"); do
    bundle=$(corpus_sample)
    [ -z "$bundle" ] && { log "ideation round $round: empty corpus slice"; continue; }
    raw=$(ideate_round "$round" "$bundle" "$shipped" "$recent_terr") || { log "ideation round $round: call failed"; continue; }
    angle=$(printf '%s' "$raw" | jq -r '.angle // empty' 2>/dev/null)
    [ -z "$angle" ] && { log "ideation round $round: no angle returned"; continue; }
    if is_recover "$angle" "$shipped"; then
      log "ideation round $round: angle re-covers a shipped post's thesis -- skipping"
      continue
    fi
    novel=$(printf '%s' "$raw" | jq -r '.novel // false' 2>/dev/null)
    form=$(printf '%s'  "$raw" | jq -r '.form // "reflection"' 2>/dev/null)
    territory=$(printf '%s' "$raw" | jq -r '.territory // empty' 2>/dev/null)
    score=0
    [ "$novel" = "true" ] && score=$((score + 2))
    fresh=no
    if territory_is_fresh "$territory" "$recent_terr"; then fresh=yes; score=$((score + 1)); fi
    log "ideation round $round: register=$form novel=$novel territory=${territory:-?} fresh=$fresh score=$score"
    if [ "$score" -gt "$best" ]; then
      best="$score"
      DECISION="$raw"
      WIN_BUNDLE="$bundle"
    fi
    [ "$score" -ge 3 ] && break
  done
  [ -n "$DECISION" ]
}

# -- draft ------------------------------------------------------

draft_post_body() {
  local angle="$1" slug="$2" form="$3" bundle="$4"
  local system user
  system=$(cat <<EOF
${VOICE_BODY}
${VOICE_NOTES_BLOCK}
${LINKS_ROSTER_BLOCK}
---

Draft a blog post for igor.bot: a MUSING under the given angle and
register. It is Igor's own thought, in and about the world.

Rules:
- register "argument": hold the position (the angle) and make the case,
  ~500-900 words, hard cap 1200.
- register "reflection": a quieter musing, ~300-700 words, no forced
  thesis -- but still a real thought that goes somewhere.
- This is a MUSING, not a reading log. Do NOT summarize, review, or react
  to an article, and do NOT narrate what you read ("I came across...",
  "a post I read..."). The reading shaped the view; the post is the view.
- Make the case in YOUR OWN voice. Do NOT hang the argument on named
  people or their work: no "the exits X and Y landed on", no "Z's note
  about W", no "as someone put it". Internalize what you read as your own
  position and state it directly. The idea stands on its own, not on whose
  it was.
- Naming an outside source is the rare exception, not the reflex. You may
  name a specific person or site ONLY when it is genuinely load-bearing
  AND it appears on your /links page (the roster above). Name it plainly,
  in prose -- NEVER as an inline markdown link. Anyone not on that roster:
  do not name them, make the point in your own words. Never invent a name
  or write a URL from memory; a name you can't place on /links is cut.
- Link nothing by default -- a musing isn't a link roundup, and /links is
  where the sites you read are credited, not the post body. (If a hard
  external fact ever truly needs a source, a URL that appears VERBATIM in
  the material below is the only kind you may use. Prefer making the point
  without one.)
- Do NOT write about the specific projects, issues, or work Igor has done
  for the human. That stays private. Keep the musing about ideas, not the
  day job.
- First person. No fabricated quotes, no fake numbers.
- Lede 1-2 sentences; no "in today's world" intros.
- Short paragraphs (2-4 sentences). H2 sparingly.
- Closer: one line. No "thanks for reading".
- Do NOT put a \`# Title\` heading at the top -- the layout renders
  the frontmatter title as the page h1.
- Stay on the given angle; don't drift into a broader survey.

Output EXACTLY this and nothing else -- no preamble, no code fences
around the whole thing:

TITLE: <post title, one line>
DESCRIPTION: <one line, 155 characters or fewer>
TAGS: <zero to three lowercase tags, comma-separated; blank if none>
===BODY===
<the markdown body. Real markdown with real newlines, starting at the
lede. No frontmatter, no leading "# Title" heading. Fenced code blocks
are fine here.>
EOF
)
  user=$(cat <<EOF
Angle (the thought the post lands):
${angle}

Register: ${form}
Proposed slug: ${slug}

Your recent brain -- the soil this grew from, NOT material to cite or
recap (id-tagged):

${bundle}
EOF
)
  # Raw output (strip_fences=0): the body is markdown that may contain
  # its own fenced code blocks, so we must NOT strip ``` lines. Headroom
  # bumped to 8000 -- the body is no longer a JSON-escaped string, and a
  # truncated response was one of the old "missing body" failure modes.
  claude_call "$MODEL" "ideation-pipeline-draft" 8000 "$system" "$user" 0
}

# Parse the label+sentinel draft into the four fields. The body is
# everything after the ===BODY=== line, taken verbatim -- never parsed
# as a JSON string, which is what used to break on long markdown.
# Sets DRAFT_TITLE / DRAFT_DESC / DRAFT_TAGS_CSV / DRAFT_BODY.
parse_drafted_post() {
  local raw="$1" meta
  meta=$(printf '%s' "$raw" | awk '/^===BODY===[[:space:]]*$/{exit} {print}')
  DRAFT_BODY=$(printf '%s' "$raw" | awk 'f{print} /^===BODY===[[:space:]]*$/{f=1}')
  DRAFT_TITLE=$(printf '%s'    "$meta" | sed -n 's/^TITLE:[[:space:]]*//p' | head -1)
  DRAFT_DESC=$(printf '%s'     "$meta" | sed -n 's/^DESCRIPTION:[[:space:]]*//p' | head -1)
  DRAFT_TAGS_CSV=$(printf '%s' "$meta" | sed -n 's/^TAGS:[[:space:]]*//p' | head -1)
}

# List internal post links in a drafted body that DON'T resolve to a real
# post -- hallucinated /posts/<slug> slugs (Igor fabricates these when it
# wants to cite something it read but lacks the source URL). A post URL
# /posts/<slug> maps to a file src/posts/YYYY/YYYY-MM-DD-<slug>.md. Prints
# one unresolved slug per line; empty output means every internal link is
# good.
broken_internal_links() {
  local body="$1" slug
  printf '%s' "$body" \
    | grep -oE '\]\((https?://igor\.bot)?/posts/[a-z0-9][a-z0-9-]*/?\)' \
    | sed -E 's/^\]\(//; s/\)$//; s#https?://igor\.bot##; s#^/posts/##; s#/$##' \
    | sort -u \
    | while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        find "$WEBSITE_PATH/src/posts" -type f \
             \( -name "*-${slug}.md" -o -name "${slug}.md" \) 2>/dev/null \
          | grep -q . || printf '%s\n' "$slug"
      done
}

# -- external link gate ----------------------------------------------
#
# PR #169 handed the drafter real source URLs and forbade inventing
# internal /posts/ slugs, but a post still shipped three joshtronic.com/links
# stand-ins and a fabricated Verge URL: the model reaches for an EXTERNAL
# URL from memory when the source it wants isn't in its slice, and the
# internal-only check above never looked at those. The draft prompt now
# forbids that; this is the deterministic backstop. Every external link in
# the body is fetched. A definitively-gone URL (404/410) is demoted to plain
# text so it can't ship. An unverifiable one (timeout, 403, 5xx -- a real
# page a bot can't reach) and a generic index/home-page stand-in are KEPT
# but flagged in the PR body for human review. Never strips on an ambiguous
# result, so a transient blip or a bot-hostile host can't gut good links.

LINK_GATE_STRIPPED=""   # newline list of demoted (dead) URLs
LINK_GATE_FLAGGED=""    # newline list of "url -- reason" to eyeball at review
VETTED_BODY=""          # vet_external_links result (set, not echoed -- see below)
UNGROUNDED_ENTITIES=""  # newline list of named entities not found in the source material

# External http(s) URLs that appear inside a markdown link in the body.
external_links() {
  printf '%s' "$1" \
    | grep -oE '\]\(https?://[^) ]+\)' \
    | sed -E 's/^\]\(//; s/\)$//' \
    | grep -viE '://(igor\.bot|localhost|127\.0\.0\.1)(/|$|:)' \
    | sort -u
}

# alive | gone | unknown. HEAD first; some hosts reject HEAD, so a non-2xx/3xx
# HEAD is retried with GET before judging. Only 404/410 count as "gone" --
# everything else non-2xx/3xx is "unknown" (kept + flagged, never stripped).
classify_url_liveness() {
  local url="$1" code
  code=$(curl -sS -o /dev/null -L --max-time 10 -A "$LINK_GATE_UA" \
           -w '%{http_code}' --head "$url" </dev/null 2>/dev/null) || code=000
  case "$code" in 2*|3*) printf 'alive'; return 0 ;; esac
  code=$(curl -sS -o /dev/null -L --max-time 10 -A "$LINK_GATE_UA" \
           -w '%{http_code}' "$url" </dev/null 2>/dev/null) || code=000
  case "$code" in
    2*|3*)   printf 'alive' ;;
    404|410) printf 'gone' ;;
    *)        printf 'unknown' ;;
  esac
}

# A bare index/home page used as a citation is a stand-in smell (the
# joshtronic.com/links class). Live, so not stripped -- just flagged.
is_generic_index_url() {
  printf '%s' "$1" \
    | grep -qiE '^https?://[^/]+(/(links|about|blog|tags|index(\.html?)?)?)?/?$'
}

# Demote every [anchor](url) for this exact url to its anchor text. perl \Q\E
# keeps URL metacharacters literal. Returns non-zero (and no output) if perl
# is unavailable, so the caller flags instead of silently failing to strip.
demote_link() {
  command -v perl >/dev/null 2>&1 || return 1
  URL="$2" perl -0777 -pe 's/\[([^\]]*)\]\(\Q$ENV{URL}\E\)/$1/g' <<<"$1"
}

# Vet every external link in $1. Strips dead ones (demote_link, keeping the
# anchor text), flags unknown + generic-index ones. Sets the cleaned body in
# the global VETTED_BODY and appends to LINK_GATE_STRIPPED / LINK_GATE_FLAGGED
# -- NOT echoed to stdout, because the caller would have to capture it in a
# command-substitution subshell, which would discard those two globals. No-ops
# cleanly without curl, and leaves the body untouched when nothing's external.
vet_external_links() {
  local body="$1" urls url status demoted
  command -v curl >/dev/null 2>&1 || { VETTED_BODY="$body"; return 0; }
  urls=$(external_links "$body")
  [ -z "$urls" ] && { VETTED_BODY="$body"; return 0; }
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    status=$(classify_url_liveness "$url")
    case "$status" in
      gone)
        if demoted=$(demote_link "$body" "$url"); then
          body="$demoted"
          LINK_GATE_STRIPPED="${LINK_GATE_STRIPPED}${url}
"
          log "link-gate: STRIP (HTTP gone) $url"
        else
          LINK_GATE_FLAGGED="${LINK_GATE_FLAGGED}${url} -- dead, could not auto-strip
"
          log "link-gate: FLAG (dead, strip failed) $url"
        fi ;;
      unknown)
        LINK_GATE_FLAGGED="${LINK_GATE_FLAGGED}${url} -- unverifiable (no 2xx/3xx)
"
        log "link-gate: FLAG (unverifiable) $url" ;;
      alive)
        if is_generic_index_url "$url"; then
          LINK_GATE_FLAGGED="${LINK_GATE_FLAGGED}${url} -- generic index page, confirm it's the real source
"
          log "link-gate: FLAG (generic index page) $url"
        fi ;;
    esac
  done <<EOF
$urls
EOF
  VETTED_BODY="$body"
}

# -- grounding gate --------------------------------------------
#
# Backstop for the "who the fuck is Sean" class: named people/things in a
# post that trace to nothing in the material Igor actually saw. Flags into
# the PR body for human review rather than blocking -- same fail-open
# philosophy as the external link gate above. (Musings don't cite their
# reading, so there's no source-link gate here; prevention is the draft
# prompt's naming rule, and this is the backstop when it doesn't take.)

# Haiku pass: list specific named people/companies/products/publications in
# the DRAFT that don't appear in the SOURCE MATERIAL the writer saw --
# likely fabrications a human should verify or cut (the "who is Sean"
# catch). Excludes Igor/Josh and generic tech. Fails open (emits nothing)
# on any error. Echoes one name per line, or nothing when all is grounded.
ground_named_entities() {
  local body="$1" sources="$2" system user raw
  [ -z "$body" ] && return 0
  system=$(cat <<'EOF'
You are checking a draft blog post for fabricated references. You get the
DRAFT and the SOURCE MATERIAL the writer actually worked from.

List every specific named PERSON, COMPANY, PRODUCT, or PUBLICATION named in
the DRAFT that does NOT appear in the SOURCE MATERIAL -- a name the writer
could not have gotten from the sources and may have invented.

Never list:
- The writer's own identity: Igor, the agent, igor.bot.
- The author: Josh, joshtronic.
- Generic technologies or tools used in passing (Linux, git, RSS, HTTP,
  and the like) and plain place names.

Output ONLY a bare list, one name per line, nothing else. If every named
reference is supported by the source material, output exactly:
NONE
EOF
)
  user=$(cat <<EOF
DRAFT:
${body}

---

SOURCE MATERIAL the writer worked from:
${sources}
EOF
)
  raw=$(claude_call "$MODEL" "ideation-pipeline-grounding" 300 "$system" "$user" 0) || return 0
  printf '%s' "$raw" | grep -qiE '^[[:space:]]*none[[:space:]]*$' && return 0
  printf '%s' "$raw" | sed '/^[[:space:]]*$/d'
}

# -- write + push + PR ------------------------------------------

sanitize_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-80
}

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
  sed -i.bak -e 's/–/--/g' -e 's/—/--/g' "$post_file" && rm -f "${post_file}.bak"
  printf '%s\n' "$post_file"
}

push_and_open_pr() {
  local post_file="$1" title="$2" angle="$3" form="$4"
  local branch pr_body pr_num rel
  branch="agent/ideation-$(date +%Y%m%d-%H%M%S)"
  rel="${post_file#"$WEBSITE_PATH"/}"
  (cd "$WEBSITE_PATH" && git fetch --quiet origin master) || return 1
  (cd "$WEBSITE_PATH" && git checkout -B "$branch" origin/master) || return 1
  (cd "$WEBSITE_PATH" && git add "$rel") || return 1
  (cd "$WEBSITE_PATH" && git commit -m "feat: add post '$title'") || return 1
  (cd "$WEBSITE_PATH" && git push -u origin "$branch") || return 1

  # Don't leave the main clone parked on the feature branch. Unlike site-work
  # (which builds its branch in a throwaway worktree), the ideation PR shares
  # the main clone -- and git won't let a later PR-review reopen check that
  # branch out in a worktree while the clone still holds it (the 128 crash).
  # Detach back to master so the branch is free.
  (cd "$WEBSITE_PATH" && git checkout --detach --quiet origin/master) 2>/dev/null || true

  local link_note=""
  if [ -n "$LINK_GATE_STRIPPED" ]; then
    link_note="${link_note}

Link gate -- demoted to plain text (dead URL):
$(printf '%s' "$LINK_GATE_STRIPPED" | sed '/^$/d; s/^/- /')"
  fi
  if [ -n "$LINK_GATE_FLAGGED" ]; then
    link_note="${link_note}

Link gate -- flagged for review:
$(printf '%s' "$LINK_GATE_FLAGGED" | sed '/^$/d; s/^/- /')"
  fi
  if [ -n "$UNGROUNDED_ENTITIES" ]; then
    link_note="${link_note}

Grounding check -- named in the post but NOT found in the source material (verify or cut):
$(printf '%s' "$UNGROUNDED_ENTITIES" | sed '/^$/d; s/^/- /')"
  fi

  pr_body=$(cat <<EOF
From the ideation pipeline ($form).

Angle:
$angle${link_note}
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

mark_drafted() {
  local ids_csv="$1"
  [ -z "$ids_csv" ] && return 0
  sqlite3 "$BRAIN_DB" \
    "UPDATE reflections SET post_drafted = 1 WHERE id IN ($ids_csv);" \
    >/dev/null 2>&1 || true
}

journal_sparks() {
  local decision="$1" note tmp n=0
  while IFS= read -r note; do
    [ -z "$note" ] && continue
    tmp=$(mktemp); printf '%s' "$note" > "$tmp"
    insert_reflection "$NOW_ISO" "$tmp" "" "thought" >/dev/null
    rm -f "$tmp"
    n=$((n + 1))
  done < <(printf '%s' "$decision" | jq -r '.sparks[]? // empty' 2>/dev/null)
  printf '%s\n' "$n"
}

# -- main -------------------------------------------------------

mode_label="dry-run"
[ "$LIVE" = "1" ] && mode_label="LIVE"
log "start ($mode_label); db=$BRAIN_DB; website=$WEBSITE_PATH"

# Refine the voice notes BEFORE the daily-refrain check. Voice learning is
# about the archive, not today's post, so it should run (and bootstrap on
# the first ever run) even on a day that already has a post. Live only --
# it writes persistent state, which a dry-run must not mutate. The weekly
# throttle and best-effort handling live inside the function.
[ "$LIVE" = "1" ] && evolve_voice_notes

if post_done_today; then
  log "post already knocked out today -- exiting clean"
  exit 0
fi

CORPUS_N=$(corpus_count)
if [ "${CORPUS_N:-0}" -lt 1 ]; then
  log "brain is empty -- nothing to write from; exiting clean"
  exit 0
fi
log "corpus: $CORPUS_N reflection(s)"

# Load the voice notes for this draft (the evolve ran earlier, before the
# refrain check). Empty block if there are no notes yet.
VOICE_NOTES_BLOCK=$(build_voice_notes_block)
LINKS_ROSTER_BLOCK=$(build_links_roster_block)

if ! run_ideation; then
  log "ideation produced no angle across $MAX_IDEATION_ROUNDS round(s) -- exiting clean"
  exit 0
fi

ANGLE=$(printf '%s' "$DECISION" | jq -r '.angle // empty')
FORM=$(printf '%s'  "$DECISION" | jq -r '.form // "reflection"')
SLUG=$(sanitize_slug "$(printf '%s' "$DECISION" | jq -r '.slug // empty')")
DRAWS_ON=$(printf '%s' "$DECISION" | jq -r '[.draws_on[]? | select(type=="number")] | join(",")' 2>/dev/null)
[ -z "$SLUG" ] && SLUG=$(sanitize_slug "$(date +%Y%m%d)-notes")
log "chosen: form=$FORM slug=$SLUG draws_on=[${DRAWS_ON}]"
log "angle: $ANGLE"

# Draft, with one retry. The tick scheduler marks this slot done the
# moment it is attempted (no second slot today), so resilience has to
# live here: a transient draft hiccup gets one more shot before we give
# up on the day's post. The shipped digest is a dedup signal for ANGLE
# selection (run_ideation), not for drafting -- the angle is already
# chosen, so the draft doesn't pay to re-send the post list.
TITLE=""; DESC=""; TAGS_CSV=""; BODY=""
for attempt in 1 2; do
  RAW=$(draft_post_body "$ANGLE" "$SLUG" "$FORM" "$WIN_BUNDLE") || {
    log "draft attempt $attempt: call failed"
    continue
  }
  parse_drafted_post "$RAW"
  if [ -n "$DRAFT_TITLE" ] && [ -n "$DRAFT_BODY" ]; then
    BAD_LINKS=$(broken_internal_links "$DRAFT_BODY")
    if [ -n "$BAD_LINKS" ]; then
      log "draft attempt $attempt: unresolved internal link(s): $(printf '%s' "$BAD_LINKS" | tr '\n' ' ')-- retrying"
      continue
    fi
    TITLE="$DRAFT_TITLE"; DESC="$DRAFT_DESC"
    TAGS_CSV="$DRAFT_TAGS_CSV"; BODY="$DRAFT_BODY"
    break
  fi
  log "draft attempt $attempt: missing title or body -- retrying"
done
if [ -z "$TITLE" ] || [ -z "$BODY" ]; then
  log "no clean draft after retries (missing fields or unresolved internal links) -- exiting clean"
  exit 0
fi

# External-link gate: dead URLs demoted to plain text, suspicious ones
# flagged for the PR body. Read-only (just curl), so it runs in dry-run too
# -- a dry-run surfaces exactly what would be stripped/flagged. Sets globals
# (VETTED_BODY + LINK_GATE_*), so it must NOT run in a $() subshell.
vet_external_links "$BODY"
BODY="$VETTED_BODY"
[ -n "$LINK_GATE_STRIPPED" ] && log "link-gate: $(printf '%s' "$LINK_GATE_STRIPPED" | grep -c .) dead link(s) demoted to text"
[ -n "$LINK_GATE_FLAGGED" ]  && log "link-gate: $(printf '%s' "$LINK_GATE_FLAGGED"  | grep -c .) link(s) flagged for review"

# Grounding pass: flag named people/things in the post that don't trace to
# the source material the writer saw (the "who is Sean" class). Cheap Haiku
# call, fails open, flags for review in the PR body.
UNGROUNDED_ENTITIES=$(ground_named_entities "$BODY" "$WIN_BUNDLE")
[ -n "$UNGROUNDED_ENTITIES" ] && log "grounding: $(printf '%s' "$UNGROUNDED_ENTITIES" | grep -c .) possibly-fabricated name(s) flagged for review"

BODY_LEN=${#BODY}
log "draft ready: title=${TITLE:0:60} body_chars=$BODY_LEN"

# Build the post JSON ourselves so escaping is deterministic. The model
# returns the body as raw text now; jq --arg does the JSON escaping that
# the model used to have to do by hand (and routinely got wrong).
TAGS_JSON=$(printf '%s' "$TAGS_CSV" | tr ',' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
  | jq -R . | jq -s '.' 2>/dev/null)
[ -z "$TAGS_JSON" ] && TAGS_JSON='[]'
POST_JSON=$(jq -n --arg t "$TITLE" --arg d "$DESC" --arg b "$BODY" \
  --argjson tags "$TAGS_JSON" \
  '{title: $t, description: $d, body: $b, tags: $tags}')

if [ "$LIVE" != "1" ]; then
  SPARK_N=$(printf '%s' "$DECISION" | jq -r '.sparks | length' 2>/dev/null)
  log "DRY-RUN: would write post + push + open PR; mark drafted [${DRAWS_ON}]; journal ${SPARK_N:-0} spark(s). Use --live to ship."
  exit 0
fi

if [ ! -d "$WEBSITE_PATH/.git" ]; then
  log "website worktree not found at $WEBSITE_PATH -- cannot push"
  exit 1
fi

POST_FILE=$(write_post_file "$SLUG" "$POST_JSON" "$NOW_ISO")
log "wrote $POST_FILE"
push_and_open_pr "$POST_FILE" "$TITLE" "$ANGLE" "$FORM" || exit 1

# Post shipped: record what it consumed so the corpus doesn't restale,
# and bank the spare sparks as journal entries for future ideation.
mark_drafted "$DRAWS_ON"
JOURNALED=$(journal_sparks "$DECISION")
log "marked drafted=[${DRAWS_ON}]; journaled $JOURNALED spark(s) as kind=thought"
