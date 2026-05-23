#!/usr/bin/env bash
# agent-reflect-read.sh -- post-read reflection executor.
#
# Runs immediately after a successful reading tick. Takes the
# source picked, the article read, the title, and the journal
# entry the agent wrote about it. Makes a single direct API call
# (Haiku by default -- cheap, no tools) asking the model whether
# the source's weight should nudge up/hold/down, and whether any
# new domains mentioned in the read are worth pulling into the
# source list as candidates.
#
# Output is strict JSON on stdout, nothing else (full schema below
# in the SYSTEM_PROMPT). Adds two brain self-healing actions:
#
#   - blacklist: judgment that a domain isn't worth long-term
#     rotation. For aggregator-routed reads, this targets the
#     destination domain (we landed there from HN; this domain
#     itself shouldn't graduate into the weighted pool). For
#     direct-sampled reads of weighted sources, blacklist is NOT
#     used -- use demote instead.
#
#   - demote: judgment that an existing weighted source has
#     drifted off small-web (programmatic content, marketing
#     pivot, abandoned). Removes from weighted list, adds to
#     blacklist with reason.
#
# Default-strict: a new domain is blacklisted unless it
# affirmatively reads as small-web (personal voice, single
# author, original content, not press/marketing/programmatic).
# Aggregators (HN, Kagi) are never blacklist-able.
#
# Usage:
#   bin/agent-reflect-read.sh <source-url> <article-url> <title> <journal-file> <sources-file> <source-type>
#
# source-type is one of: personal, hn, kagi
#
# Exit codes:
#   0  success (JSON on stdout)
#   1  bad args
#   2  API call failed
#   3  malformed model output

set -uo pipefail

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

SOURCE_URL="${1:-}"
ARTICLE_URL="${2:-}"
TITLE="${3:-}"
JOURNAL_FILE="${4:-}"
SOURCES_FILE="${5:-}"
SOURCE_TYPE="${6:-personal}"

if [ -z "$SOURCE_URL" ] || [ -z "$ARTICLE_URL" ] || [ -z "$TITLE" ] \
   || [ -z "$JOURNAL_FILE" ] || [ -z "$SOURCES_FILE" ]; then
  echo "usage: agent-reflect-read.sh <source-url> <article-url> <title> <journal-file> <sources-file> <source-type>" >&2
  exit 1
fi

[ -f "$JOURNAL_FILE" ] || { echo "agent-reflect-read: journal file not found: $JOURNAL_FILE" >&2; exit 1; }
[ -f "$SOURCES_FILE" ] || { echo "agent-reflect-read: sources file not found: $SOURCES_FILE" >&2; exit 1; }

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

MODEL="${AGENT_MODEL_THINKING:-claude-haiku-4-5-20251001}"

JOURNAL=$(cat "$JOURNAL_FILE")
SOURCES=$(cat "$SOURCES_FILE")

SYSTEM_PROMPT=$(cat <<'EOF'
You are a reflection step that runs after the agent (an autonomous
Claude process) reads a blog post. The agent picks reading sources
by weighted random sample from a list maintained in sources.md.
The long-term rotation is curated to small-web personal blogs;
aggregators (HN, Kagi small web) are one-shot windows onto random
URLs, NOT shapers of the rotation.

## Small-web criteria (the rubric for what belongs in rotation)

A domain belongs in the long-term rotation only if it AFFIRMATIVELY
reads as small-web:

  - Personal voice -- first-person, opinions, reflection, lived
    experience. Not corporate "we", not press-release "the team".
  - Single author or small team. Independent, not staff-written
    for a publication.
  - Original content. Not press releases, product docs,
    programmatic benchmarks, marketing pages, aggregator feeds,
    or auto-generated comparison pages.
  - Alive -- updated, not abandoned years ago.
  - Shape of Kagi small web. If you'd be surprised to see it in
    that directory, it doesn't belong in the rotation.

DEFAULT STRICT: when in doubt, BLACKLIST. We're not building a
search engine; we're curating a small set of voices worth coming
back to. False negatives (blacklisting something borderline) are
recoverable -- you can always un-blacklist later. False positives
(letting in a slop site) bloat the rotation and the brain.

## Your job

1. WEIGHT DELTA (-1, 0, +1). For aggregator-routed reads (source
   type "hn" or "kagi"), ALWAYS use 0 -- the aggregator's quality
   doesn't depend on what it happened to route to. For
   direct-sampled reads from a weighted source, nudge -1 if the
   read was notably thin, +1 if standout. Bias toward 0.

2. CANDIDATES. New small-web domains mentioned in the read that
   look worth sampling. Default STRICT: only propose when the
   domain affirmatively meets the criteria above. If you wouldn't
   confidently call it small-web, leave it out -- an empty array
   is the common case.

3. PROMOTIONS. Existing weight-0 candidates ready to graduate.
   At most one per reflection.

4. BLACKLIST. When the source type is "hn" or "kagi", judge the
   DESTINATION domain (the article_url's domain). If it doesn't
   meet small-web criteria, emit a blacklist entry. Reason should
   name WHY (e.g., "programmatic benchmark site", "product
   marketing", "abandoned, last post 2014"). For source type
   "personal", do NOT emit blacklist -- use demote instead.

5. DEMOTE. When the source type is "personal" (a weighted source
   was directly sampled), and the read reveals the source has
   drifted off small-web (gone all marketing, gone programmatic,
   gone dead), emit a demote entry. The caller will remove from
   weighted list and add to blacklist with the same reason. Be
   conservative -- one off-tone read isn't drift; require a clear
   pattern shift you can name.

Aggregator EXEMPTION: never blacklist or demote news.ycombinator.com
or kagi.com themselves. They're functional reading windows; only
their destinations are judged.

Output STRICT JSON only. No prose, no code fences, no preamble.
Schema (blacklist and demote are nullable -- use null when not
applicable):

{
  "weight_delta": -1 | 0 | 1,
  "weight_reason": "one short sentence",
  "candidates": [
    {"url": "https://domain.com", "label": "Short Name", "reason": "one short sentence"}
  ],
  "promotions": [
    {"url": "https://existing-candidate.com", "reason": "one short sentence"}
  ],
  "blacklist": {"url": "https://domain.com", "reason": "one short sentence"} | null,
  "demote":    {"url": "https://existing-source.com", "reason": "one short sentence"} | null
}
EOF
)

# RAG: surface past reflections on this source so we don't pingpong
# the weight back and forth across ticks ("I bumped this twice last
# week" is useful signal when deciding to bump again).
# shellcheck source=../lib/rag.sh
. "$AGENT_HOME/lib/rag.sh"
RAG_CONTEXT=$(rag_query "reading source $SOURCE_URL")

# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"

USER_MESSAGE=$(cat <<EOF
Source picked: $SOURCE_URL
Source type: $SOURCE_TYPE
Article read: $ARTICLE_URL
Title: $TITLE

Journal entry the agent wrote:

$JOURNAL

Current sources.md (use this to dedupe candidates -- any URL
already listed here, at any weight, is NOT a fresh candidate):

$SOURCES

---

## Past context (RAG -- prior thinking about this source)

${RAG_CONTEXT:-(no past context retrieved this tick)}
EOF
)

PAYLOAD=$(jq -n \
  --arg m "$MODEL" \
  --arg s "$SYSTEM_PROMPT" \
  --arg u "$USER_MESSAGE" \
  '{
    model: $m,
    max_tokens: 600,
    system: $s,
    messages: [{role: "user", content: $u}]
  }')

RESPONSE=$(curl -sf \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  --max-time 60 \
  -d "$PAYLOAD" 2>/dev/null) || {
  echo "agent-reflect-read: API call failed" >&2
  exit 2
}

cost_record_api "agent-reflect-read" "$MODEL" "$RESPONSE"

TEXT=$(jq -r '.content[0].text // ""' <<<"$RESPONSE")
if [ -z "$TEXT" ]; then
  echo "agent-reflect-read: API returned empty content" >&2
  echo "$RESPONSE" >&2
  exit 3
fi

# Strip code-fence wrappers if the model added them despite instructions.
TEXT=$(printf '%s' "$TEXT" | sed -E '/^```/d')

# Validate it parses and has the required shape.
if ! jq -e '.weight_delta' <<<"$TEXT" >/dev/null 2>&1; then
  echo "agent-reflect-read: model output missing weight_delta" >&2
  echo "$TEXT" >&2
  exit 3
fi

# Pass through (caller bounds delta + dedupes candidates).
printf '%s\n' "$TEXT"
