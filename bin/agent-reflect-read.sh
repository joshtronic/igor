#!/usr/bin/env bash
# agent-reflect-read.sh -- post-read reflection executor.
#
# Runs immediately after a successful reading tick. Takes the
# source picked, the article read, the title, and the journal
# entry Igor wrote about it. Makes a single direct API call
# (Haiku by default -- cheap, no tools) asking the model whether
# the source's weight should nudge up/hold/down, and whether any
# new domains mentioned in the read are worth pulling into the
# source list as candidates.
#
# Output is strict JSON on stdout, nothing else:
#
#   {
#     "weight_delta": -1 | 0 | 1,
#     "weight_reason": "one sentence",
#     "candidates": [
#       {"url": "https://...", "label": "Short Name", "reason": "..."}
#     ]
#   }
#
# Weight delta is bounded -- this script never proposes more than
# one step in either direction. The caller (discretionary-read.sh)
# enforces the floor (min weight 1, so a source never self-eliminates).
#
# Usage:
#   bin/agent-reflect-read.sh <source-url> <article-url> <title> <journal-file> <sources-file>
#
# Exit codes:
#   0  success (JSON on stdout)
#   1  bad args
#   2  API call failed
#   3  malformed model output

set -uo pipefail

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

SOURCE_URL="${1:-}"
ARTICLE_URL="${2:-}"
TITLE="${3:-}"
JOURNAL_FILE="${4:-}"
SOURCES_FILE="${5:-}"

if [ -z "$SOURCE_URL" ] || [ -z "$ARTICLE_URL" ] || [ -z "$TITLE" ] \
   || [ -z "$JOURNAL_FILE" ] || [ -z "$SOURCES_FILE" ]; then
  echo "usage: agent-reflect-read.sh <source-url> <article-url> <title> <journal-file> <sources-file>" >&2
  exit 1
fi

[ -f "$JOURNAL_FILE" ] || { echo "agent-reflect-read: journal file not found: $JOURNAL_FILE" >&2; exit 1; }
[ -f "$SOURCES_FILE" ] || { echo "agent-reflect-read: sources file not found: $SOURCES_FILE" >&2; exit 1; }

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

MODEL="${IGOR_MODEL_THINKING:-claude-haiku-4-5-20251001}"

JOURNAL=$(cat "$JOURNAL_FILE")
SOURCES=$(cat "$SOURCES_FILE")

SYSTEM_PROMPT=$(cat <<'EOF'
You are a reflection step that runs after Igor (an autonomous
Claude process) reads a blog post. Igor picks reading sources by
weighted random sample from a list maintained in sources.md. Your
job after each successful read:

1. Suggest a small adjustment to the source's weight: -1, 0, or +1.
   Bias toward 0 -- a single read isn't strong evidence. Only
   nudge when the read was genuinely standout (+1, "more like
   this please") or notably thin / off-target (-1, "less of this").
   Never propose a delta outside [-1, 1].

2. Suggest new source candidates -- domains that appeared in the
   read (linked, cited, or referenced) and look worth pulling into
   the rotation. Only propose a domain if ALL of these hold:
     - it was actually mentioned in the article or in Igor's journal
     - it is NOT already in sources.md (any weight)
     - it looks like personal / independent writing, not a press
       release, vendor page, social network, or aggregator
   The URL should be the homepage of the candidate domain
   (https://domain.com), not a specific post.
   Candidates land at weight 0 -- listed but not sampled. Be
   conservative; an empty candidates array is fine.

3. Suggest promotions -- existing weight-0 candidates that have
   earned a sample. Look at the "## Candidates (auto-discovered)"
   section of sources.md (if present). A candidate is ready to
   promote (weight 0 -> 1) when:
     - it shows up referenced or quoted in today's read in a way
       that suggests substance (not just a passing mention), OR
     - it's been sitting at 0 for a while and the reflection's
       prior reasoning lines (in past_context, if any) suggest
       it represents a real ongoing voice worth sampling.
   Promote at most one candidate per reflection -- this is gentle
   pool growth, not bulk activation. Empty promotions array is
   the common case; only emit one when you have concrete signal.

Output STRICT JSON only. No prose, no code fences, no preamble.
Schema:

{
  "weight_delta": -1 | 0 | 1,
  "weight_reason": "one short sentence",
  "candidates": [
    {"url": "https://domain.com", "label": "Short Name", "reason": "one short sentence"}
  ],
  "promotions": [
    {"url": "https://existing-candidate.com", "reason": "one short sentence"}
  ]
}
EOF
)

# RAG: surface past reflections on this source so we don't pingpong
# the weight back and forth across ticks ("I bumped this twice last
# week" is useful signal when deciding to bump again).
# shellcheck source=../lib/rag.sh
. "$IGOR_HOME/lib/rag.sh"
RAG_CONTEXT=$(rag_query "reading source $SOURCE_URL")

USER_MESSAGE=$(cat <<EOF
Source picked: $SOURCE_URL
Article read: $ARTICLE_URL
Title: $TITLE

Journal entry Igor wrote:

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
