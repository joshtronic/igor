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
# only the FORM flexes -- a synthesis essay when reflections genuinely
# rhyme, a lighter honest "what I read / thought about" notes post when
# they don't. The only clean no-ops are: a post already shipped today
# (daily refrain), or a literally empty brain (nothing to write from).
#
# Per invocation:
#   0. Daily refrain. Post already knocked out today (master OR open
#      bot PR)? Exit clean.
#   1. Ideate (Haiku), up to MAX_IDEATION_ROUNDS scans over randomized
#      slices of the brain, biased toward un-drafted material and
#      anchored on the most recent reflections. Picks an angle that the
#      site has NOT already covered (full shipped-post digest as the
#      dedup signal). Spare half-formed ideas come back as "sparks".
#   2. Draft (Sonnet) the post under the chosen angle.
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
#   ANTHROPIC_API_KEY  FORGEJO_URL  FORGEJO_TOKEN  FORGEJO_HOST  BOT_USER
# Optional env:
#   WEBSITE_REPO (opt-in gate)  AGENT_MODEL  AGENT_MODEL_THINKING
#   AGENT_STATE_DIR  AGENT_HOME  FORGEJO_REVIEWER

set -uo pipefail

# -- args ------------------------------------------------------

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"

BRAIN_DB="$AGENT_STATE_DIR/brain.sqlite"
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

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

if [ -z "${WEBSITE_REPO:-}" ]; then
  echo "ideation-pipeline: WEBSITE_REPO unset -- nothing to do (set it in .env to opt in)" >&2
  exit 0
fi

: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
: "${FORGEJO_HOST:?FORGEJO_HOST must be set}"
: "${BOT_USER:?BOT_USER must be set (export it before calling)}"

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
THINKING_MODEL="${AGENT_MODEL_THINKING:-claude-haiku-4-5-20251001}"
WEBSITE_PATH="${WEBSITE_PATH:-$AGENT_STATE_DIR/repos/${WEBSITE_REPO}}"

# -- libs -------------------------------------------------------

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=../lib/brain.sh
. "$AGENT_HOME/lib/brain.sh"

# -- constants --------------------------------------------------

MAX_IDEATION_ROUNDS=3
CORPUS_ANCHOR_RECENT=5      # most-recent reflections always in the slice
CORPUS_SAMPLE_SIZE=30       # randomized un-drafted reflections per round

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
# reflections (recency anchor) plus a random sample of un-drafted ones.
# Re-runs reshuffle (RANDOM()), so each ideation round scans a
# different slice -- that's the entropy lever and the "2-3 rounds".
# The whole block is formatted in SQL so multi-paragraph content
# survives intact (no awk line-splitting).
corpus_sample() {
  sqlite3 "$BRAIN_DB" \
    "SELECT '### id=' || id || '  kind=' || kind || '  ' || ts
            || char(10) || char(10) || content
            || char(10) || char(10) || '---' || char(10)
     FROM reflections
     WHERE id IN (
       SELECT id FROM (SELECT id FROM reflections ORDER BY ts DESC LIMIT $CORPUS_ANCHOR_RECENT)
       UNION
       SELECT id FROM (SELECT id FROM reflections WHERE post_drafted = 0
                       ORDER BY RANDOM() LIMIT $CORPUS_SAMPLE_SIZE)
     )
     ORDER BY ts DESC;" 2>/dev/null
}

# -- shipped digest (dedup signal) ------------------------------
#
# Every post already on the site, as "- title [tags] -- description".
# Fed to ideation so it steers AWAY from covered ground. Small site,
# so we include all of it; revisit if the archive ever gets large.

shipped_digest() {
  local f fm title desc tags
  for f in "$WEBSITE_PATH"/src/posts/*/*.md; do
    [ -f "$f" ] || continue
    fm=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f{print}' "$f")
    title=$(printf '%s' "$fm" | sed -n 's/^title:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')
    desc=$(printf '%s'  "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')
    tags=$(printf '%s'  "$fm" | sed -n 's/^tags:[[:space:]]*//p' | head -1)
    [ -z "$title" ] && continue
    printf -- '- %s %s -- %s\n' "$title" "$tags" "$desc"
  done
}

# -- ideation ---------------------------------------------------

ideate_round() {
  local round="$1" bundle="$2" shipped="$3"
  local system user
  system=$(cat <<EOF
${VOICE_BODY}

---

You are choosing what igor.bot publishes today. "No post" is NOT an
option -- you ALWAYS return an angle. Draw from the reading reflections
and journal entries below: this is the agent's whole recent brain, not
one day's reads.

How to choose:
- The post may connect a recent read to an older one, or springboard
  off a single spark. Reflections do NOT all need to share a theme.
- Novelty first. Do not pick an angle the site has already covered
  (see the shipped-posts list). If your strongest idea is already
  covered there, pick the next-best uncovered one.
- Choose a form:
  - "synthesis": 2+ reflections genuinely rhyme into one claim worth
    600-900 words.
  - "notes": they don't rhyme -- ship an honest, lighter roundup of
    what was read/thought, no manufactured thesis. Still a real post.
- List the reflection ids the angle actually draws on (draws_on).
- Park any half-formed ideas not ripe enough to post as "sparks" --
  one short line each. They get journaled for later, not written now.

Output STRICT JSON, no code fences, no prose:

{
  "angle": "the one-sentence claim the post makes",
  "title_hint": "working title",
  "slug": "kebab-case-slug",
  "form": "synthesis" | "notes",
  "novel": true | false,
  "draws_on": [12, 34],
  "sparks": ["a half-formed idea", "another"]
}
EOF
)
  user=$(cat <<EOF
Scan round ${round}.

Posts already shipped (do NOT re-cover these):
${shipped:-（none yet）}

Brain slice (reflections + journal entries, id-tagged):

${bundle}
EOF
)
  anthropic_call "$THINKING_MODEL" "ideation-pipeline-ideate" 800 "$system" "$user"
}

# Run up to MAX_IDEATION_ROUNDS, keeping the best candidate. Score:
# novel(+2) + synthesis(+1). Stop early on a perfect 3. Always ends
# with a non-empty DECISION (always-post).
DECISION=""
WIN_BUNDLE=""
run_ideation() {
  local round bundle shipped raw angle novel form score best=-1
  shipped=$(shipped_digest)
  for round in $(seq 1 "$MAX_IDEATION_ROUNDS"); do
    bundle=$(corpus_sample)
    [ -z "$bundle" ] && { log "ideation round $round: empty corpus slice"; continue; }
    raw=$(ideate_round "$round" "$bundle" "$shipped") || { log "ideation round $round: call failed"; continue; }
    angle=$(printf '%s' "$raw" | jq -r '.angle // empty' 2>/dev/null)
    [ -z "$angle" ] && { log "ideation round $round: no angle returned"; continue; }
    novel=$(printf '%s' "$raw" | jq -r '.novel // false' 2>/dev/null)
    form=$(printf '%s'  "$raw" | jq -r '.form // "notes"' 2>/dev/null)
    score=0
    [ "$novel" = "true" ] && score=$((score + 2))
    [ "$form" = "synthesis" ] && score=$((score + 1))
    log "ideation round $round: form=$form novel=$novel score=$score"
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
  local angle="$1" slug="$2" form="$3" bundle="$4" shipped="$5"
  local system user
  system=$(cat <<EOF
${VOICE_BODY}

---

Draft a blog post for igor.bot under the given angle and form.

Rules:
- form "synthesis": one claim (the angle), 600-900 words, hard cap 1200.
- form "notes": an honest roundup, 300-600 words, no forced thesis.
- Lede 1-2 sentences; no "in today's world" intros.
- Short paragraphs (2-4 sentences). H2 sparingly.
- First person. No fabricated quotes, no fake numbers.
- Link any specific source you reference -- inline markdown link.
- Closer: one line. No "thanks for reading".
- Do NOT put a \`# Title\` heading at the top -- the layout renders
  the frontmatter title as the page h1.
- Do not re-cover anything in the "already shipped" list; find your
  own ground.

Output STRICT JSON, no code fences. Schema:

{
  "title": "post title",
  "description": "<= 155 chars",
  "body": "markdown body, no frontmatter, no leading h1",
  "tags": ["zero", "to", "three", "lowercase"]
}
EOF
)
  user=$(cat <<EOF
Angle (the post's one claim):
${angle}

Form: ${form}
Proposed slug: ${slug}

Posts already shipped (don't re-cover):
${shipped:-（none yet）}

Brain slice (source material, id-tagged):

${bundle}
EOF
)
  anthropic_call "$MODEL" "ideation-pipeline-draft" 4000 "$system" "$user"
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

  pr_body=$(cat <<EOF
From the ideation pipeline ($form).

Angle:
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

if ! run_ideation; then
  log "ideation produced no angle across $MAX_IDEATION_ROUNDS round(s) -- exiting clean"
  exit 0
fi

ANGLE=$(printf '%s' "$DECISION" | jq -r '.angle // empty')
FORM=$(printf '%s'  "$DECISION" | jq -r '.form // "notes"')
SLUG=$(sanitize_slug "$(printf '%s' "$DECISION" | jq -r '.slug // empty')")
DRAWS_ON=$(printf '%s' "$DECISION" | jq -r '[.draws_on[]? | select(type=="number")] | join(",")' 2>/dev/null)
[ -z "$SLUG" ] && SLUG=$(sanitize_slug "$(date +%Y%m%d)-notes")
log "chosen: form=$FORM slug=$SLUG draws_on=[${DRAWS_ON}]"
log "angle: $ANGLE"

SHIPPED=$(shipped_digest)
POST_JSON=$(draft_post_body "$ANGLE" "$SLUG" "$FORM" "$WIN_BUNDLE" "$SHIPPED") || {
  log "post drafting failed -- exiting clean"
  exit 0
}
TITLE=$(printf '%s' "$POST_JSON" | jq -r '.title // empty' 2>/dev/null)
BODY_LEN=$(printf '%s' "$POST_JSON" | jq -r '.body | length' 2>/dev/null)
if [ -z "$TITLE" ] || [ "${BODY_LEN:-0}" -lt 1 ]; then
  log "draft missing title or body -- exiting clean"
  exit 0
fi
log "draft ready: title=${TITLE:0:60} body_chars=$BODY_LEN"

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
