#!/usr/bin/env bash
# agent-read.sh -- harness-side reading executor.
#
# Fetches a URL, sends the HTML to the Anthropic API with Igor's
# identity baked into the system prompt, and outputs a JSON blob
# containing the article title and a first-person journal entry.
#
# Usage:
#   bin/agent-read.sh <url>
#
# Outputs (stdout): JSON object
#   {"title": "...", "journal": "...", "url": "..."}
#
# Exit codes:
#   0   success
#   1   bad args
#   2   fetch failed (curl)
#   3   API call failed
#   4   API returned malformed output (couldn't parse JSON)
#
# This is the first "specialized executor" in the harness-owned
# discretionary path: instead of invoking Claude Code with the full
# agent loop, the harness handles the entire read+journal flow via
# a single direct API call. Cheaper, faster, more predictable.
# Designed to be a drop-in replacement for "discretionary shape c"
# (reading tick) when wired into tick.sh.

set -uo pipefail

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

URL="${1:-}"
if [ -z "$URL" ]; then
  echo "usage: agent-read.sh <url>" >&2
  exit 1
fi

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

# Reading needs voice quality; pick Sonnet by default, but allow
# override via IGOR_MODEL_READING for experimentation.
MODEL="${IGOR_MODEL_READING:-${IGOR_MODEL:-claude-sonnet-4-6}}"

# Polite fetch: realistic User-Agent, follow redirects, 30s cap,
# limit body size so we don't OOM on absurdly large pages.
HTML=$(curl -sfL \
  --max-time 30 \
  --max-filesize 5000000 \
  -A "Mozilla/5.0 (compatible; Igor/1.0; +https://igor.bot)" \
  "$URL" 2>/dev/null) || {
  echo "agent-read: fetch failed for $URL" >&2
  exit 2
}

if [ -z "$HTML" ]; then
  echo "agent-read: fetched empty body from $URL" >&2
  exit 2
fi

# Truncate HTML if absurdly large to keep API costs sane. 200KB
# is plenty for any real blog post.
HTML=$(printf '%s' "$HTML" | head -c 200000)

# Load identity for voice context. Falls back gracefully if brain
# isn't on disk (e.g., local dev without a brain clone).
IDENTITY=""
BRAIN_PATH="${IGOR_BRAIN_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/brain}"
if [ -f "$BRAIN_PATH/identity.md" ]; then
  IDENTITY=$(cat "$BRAIN_PATH/identity.md")
fi

SYSTEM_PROMPT=$(cat <<EOF
${IDENTITY:+$IDENTITY

---

}You are doing a discretionary reading tick. You'll receive the
HTML of a web page (likely a blog post or article). Your job:

1. Identify the article's actual title (often in <title>, an h1,
   or near the top of the content).
2. Read the substantive content. Skip navigation, footers, ads,
   cookie banners.
3. Write a first-person journal entry about what struck you. One
   to two paragraphs. ~150-300 words. Your own voice -- terse,
   grounded. No "as the robot" verbal tic; reach for the agent-
   perspective angle only when it's actually relevant, not as a
   default.
4. If the page is mostly chrome (no real article, paywall, error,
   etc.), note that briefly and move on.

Output STRICT JSON. No surrounding prose. No code fences. No
preamble. Just the JSON object:

{
  "title": "the article title as I'd cite it",
  "journal": "the journal entry in markdown, first person"
}
EOF
)

USER_MESSAGE=$(printf 'URL: %s\n\nHTML content:\n\n%s' "$URL" "$HTML")

PAYLOAD=$(jq -n \
  --arg m "$MODEL" \
  --arg s "$SYSTEM_PROMPT" \
  --arg u "$USER_MESSAGE" \
  '{
    model: $m,
    max_tokens: 1500,
    system: $s,
    messages: [{role: "user", content: $u}]
  }')

RESPONSE=$(curl -sf \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d "$PAYLOAD" 2>/dev/null) || {
  echo "agent-read: API call failed for $URL" >&2
  exit 3
}

# Extract the text content the model returned
TEXT=$(jq -r '.content[0].text // ""' <<<"$RESPONSE")
if [ -z "$TEXT" ]; then
  echo "agent-read: API returned empty content" >&2
  echo "$RESPONSE" >&2
  exit 3
fi

# Strip code-fence wrappers if the model added them despite instructions.
TEXT=$(printf '%s' "$TEXT" | sed -E '/^```/d')

# Parse the JSON the model produced
TITLE=$(jq -r '.title // ""' <<<"$TEXT" 2>/dev/null || echo "")
JOURNAL=$(jq -r '.journal // ""' <<<"$TEXT" 2>/dev/null || echo "")

if [ -z "$TITLE" ] || [ -z "$JOURNAL" ]; then
  echo "agent-read: model output didn't parse as expected JSON" >&2
  echo "$TEXT" >&2
  exit 4
fi

# Emit our own JSON for tick.sh to consume, including the URL so
# the caller doesn't have to track it separately.
jq -n \
  --arg t "$TITLE" \
  --arg j "$JOURNAL" \
  --arg u "$URL" \
  '{title: $t, journal: $j, url: $u}'
