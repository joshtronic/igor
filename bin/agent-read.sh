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

MODEL="${IGOR_MODEL:-claude-sonnet-4-6}"

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
# is plenty for any real blog post. Bash substring instead of
# `printf | head -c` -- the pipe SIGPIPEs printf when HTML is
# bigger than the head limit, which fires on every read of a
# medium+ article and clutters journalctl. Substring is
# subprocess-free.
HTML="${HTML:0:200000}"

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

# RAG: surface past journal entries / posts / commits related to the
# URL's domain or title (extracted post-fetch). Best-effort.
# shellcheck source=../lib/rag.sh
. "$IGOR_HOME/lib/rag.sh"
RAG_CONTEXT=$(rag_query "$URL")

# Build the JSON payload via files, not --arg. Truncated HTML can
# be ~200KB; passing that as a command-line argument blows past
# ARG_MAX on smaller-stack systems with "Argument list too long".
# --rawfile reads the contents as a literal string and embeds it
# correctly in the JSON.
USER_MSG_FILE=$(mktemp)
SYSTEM_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$USER_MSG_FILE" "$SYSTEM_FILE" "$PAYLOAD_FILE" "$RESPONSE_FILE" 2>/dev/null' EXIT
{
  printf 'URL: %s\n\nHTML content:\n\n%s\n\n' "$URL" "$HTML"
  printf '\n---\n\n## Past context (RAG -- prior reads/journals related to this URL)\n\n'
  printf '%s\n' "${RAG_CONTEXT:-(no past context retrieved this tick)}"
} > "$USER_MSG_FILE"
printf '%s' "$SYSTEM_PROMPT" > "$SYSTEM_FILE"

jq -n \
  --arg m "$MODEL" \
  --rawfile s "$SYSTEM_FILE" \
  --rawfile u "$USER_MSG_FILE" \
  '{
    model: $m,
    max_tokens: 1500,
    system: $s,
    messages: [{role: "user", content: $u}]
  }' > "$PAYLOAD_FILE" || {
  echo "agent-read: failed to build request payload for $URL" >&2
  exit 3
}

# Capture HTTP status + curl exit separately so failures point at
# something actionable ("HTTP 529" vs "curl exit 22") instead of
# the generic "API call failed".
RESPONSE_FILE=$(mktemp)
HTTP_STATUS=$(curl -sS \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -w '%{http_code}' \
  -o "$RESPONSE_FILE" \
  --data-binary "@$PAYLOAD_FILE" 2>/tmp/agent-read-curl-err.$$)
CURL_EXIT=$?

if [ "$CURL_EXIT" -ne 0 ]; then
  CURL_ERR=$(cat /tmp/agent-read-curl-err.$$ 2>/dev/null | head -1)
  rm -f /tmp/agent-read-curl-err.$$ 2>/dev/null
  echo "agent-read: curl failed for $URL (exit $CURL_EXIT): $CURL_ERR" >&2
  exit 3
fi
rm -f /tmp/agent-read-curl-err.$$ 2>/dev/null

if [ "$HTTP_STATUS" != "200" ]; then
  ERR_DETAIL=$(jq -r '.error.message // .error.type // empty' < "$RESPONSE_FILE" 2>/dev/null | head -c 200)
  echo "agent-read: API returned HTTP $HTTP_STATUS for $URL${ERR_DETAIL:+ -- $ERR_DETAIL}" >&2
  exit 3
fi

RESPONSE=$(cat "$RESPONSE_FILE")

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
