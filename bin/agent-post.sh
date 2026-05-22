#!/usr/bin/env bash
# agent-post.sh -- harness-side post drafter.
#
# Takes a blog idea text and drafts a full post via a single direct
# API call to Sonnet (voice quality matters). Returns JSON containing
# everything the harness needs to write the post file, the YAML
# front matter, and PR_BODY.md.
#
# Usage:
#   bin/agent-post.sh "<blog idea text>"
#
# Outputs (stdout): JSON object
#   {
#     "title":       "lowercase imperative title",
#     "slug":        "kebab-case-slug",
#     "description": "<=155 chars",
#     "tags":        ["array", "of", "tag", "strings"],
#     "body":        "markdown body, starts at lede, no # H1",
#     "pr_body":     "two-checklist PR body"
#   }
#
# Exit codes:
#   0   success
#   1   bad args
#   2   API call failed
#   3   API returned malformed output

set -uo pipefail

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

IDEA="${1:-}"
if [ -z "$IDEA" ]; then
  echo "usage: agent-post.sh \"<blog idea text>\"" >&2
  exit 1
fi

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

MODEL="${IGOR_MODEL:-claude-sonnet-4-6}"

# Load identity and the website's CLAUDE.md (if available) for voice
# + format context. Both fall back gracefully if missing.
IDENTITY=""
BRAIN_PATH="${IGOR_BRAIN_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/brain}"
if [ -f "$BRAIN_PATH/identity.md" ]; then
  IDENTITY=$(cat "$BRAIN_PATH/identity.md")
fi

WEBSITE_CLAUDE=""
WEBSITE_PATH="${IGOR_WEBSITE_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/website}"
if [ -f "$WEBSITE_PATH/CLAUDE.md" ]; then
  WEBSITE_CLAUDE=$(cat "$WEBSITE_PATH/CLAUDE.md")
fi

TODAY=$(date +%Y-%m-%d)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

SYSTEM_PROMPT=$(cat <<EOF
${IDENTITY:+$IDENTITY

---

}You are drafting a blog post for igor.bot. The post should be in
your own voice, following the format and style rules from the
website's CLAUDE.md below.

${WEBSITE_CLAUDE:+--- BEGIN website CLAUDE.md ---
$WEBSITE_CLAUDE
--- END website CLAUDE.md ---

}Format requirements (these are STRICT):

- Title: lowercase typically (mood-driven), framed as a claim,
  question, or task. The first checklist item in PR_BODY.md must
  start with "feat:".
- Slug: kebab-case, derived from title, lowercase, no trailing
  punctuation.
- Description: <=155 chars. This is the meta description.
- Tags: array of short strings. Lowercase. May be empty if nothing
  fits.
- Body: starts AT THE LEDE. NO "# Title" h1 at the top. Layout
  renders the YAML title as the h1. The first line of the body is
  the first sentence of the post.
- Length: 600-900 words. Hard cap 1,200.
- One idea per post. Skimmable. Short paragraphs. H2s for
  sections, H3s sparingly.

Output STRICT JSON. No preamble. No code fences. Exactly this
shape:

{
  "title": "the post title",
  "slug": "kebab-case-slug",
  "description": "<=155 char meta description",
  "tags": ["tag1", "tag2"],
  "body": "the full markdown body, starts at the lede, no # heading",
  "pr_body": "## What this PR does\n\n- [x] feat: add post '<title>'\n\n## Test plan\n\n- [x] markdownlint passes\n- [ ] Manual: read it on the rendered site"
}
EOF
)

# RAG: surface past journal entries / posts / commits relevant to
# the idea so the post can build on prior thinking instead of
# re-litigating it. Best-effort; empty if rag stack unavailable.
# shellcheck source=../lib/rag.sh
. "$IGOR_HOME/lib/rag.sh"
RAG_CONTEXT=$(rag_query "$IDEA")

USER_MESSAGE=$(cat <<EOF
Today is ${TODAY}.

Blog idea (from brain/blog-ideas.md):

${IDEA}

Draft a full post on this idea. Be terse, grounded, in voice.

---

## Past context (RAG -- prior journals/posts/commits related to this idea)

${RAG_CONTEXT:-(no past context retrieved this tick)}
EOF
)

PAYLOAD=$(jq -n \
  --arg m "$MODEL" \
  --arg s "$SYSTEM_PROMPT" \
  --arg u "$USER_MESSAGE" \
  '{
    model: $m,
    max_tokens: 4000,
    system: $s,
    messages: [{role: "user", content: $u}]
  }')

RESPONSE=$(curl -sf \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  --max-time 180 \
  -d "$PAYLOAD" 2>/dev/null) || {
  echo "agent-post: API call failed" >&2
  exit 2
}

TEXT=$(jq -r '.content[0].text // ""' <<<"$RESPONSE")
if [ -z "$TEXT" ]; then
  echo "agent-post: API returned empty content" >&2
  echo "$RESPONSE" >&2
  exit 2
fi

# Strip code-fence wrappers if model added them despite instructions.
TEXT=$(printf '%s' "$TEXT" | sed -E '/^```/d')

# Validate the JSON parses and has the expected fields. pr_body is
# the field the model drops most often in practice -- it's the
# last, longest, and most structured chunk of the output, and
# every once in a while it just doesn't get emitted. Title and
# body are content only the model can write; pr_body is mechanical
# (a fixed two-checklist scaffold with the title interpolated), so
# we synthesize it when missing rather than killing the tick.
TITLE=$(jq -r '.title // ""' <<<"$TEXT" 2>/dev/null || echo "")
SLUG=$(jq -r '.slug // ""' <<<"$TEXT" 2>/dev/null || echo "")
DESC=$(jq -r '.description // ""' <<<"$TEXT" 2>/dev/null || echo "")
BODY=$(jq -r '.body // ""' <<<"$TEXT" 2>/dev/null || echo "")
PR_BODY=$(jq -r '.pr_body // ""' <<<"$TEXT" 2>/dev/null || echo "")

# Required fields with no fallback. Missing one is fatal.
missing=()
[ -z "$TITLE" ] && missing+=("title")
[ -z "$SLUG" ]  && missing+=("slug")
[ -z "$BODY" ]  && missing+=("body")

if [ "${#missing[@]}" -gt 0 ]; then
  echo "agent-post: model output missing required field(s): ${missing[*]}" >&2
  echo "$TEXT" >&2
  exit 3
fi

if [ -z "$PR_BODY" ]; then
  echo "agent-post: model dropped pr_body -- synthesizing from template" >&2
  PR_BODY=$(printf '## What this PR does\n\n- [x] feat: add post '\''%s'\''\n\n## Test plan\n\n- [x] markdownlint passes\n- [ ] Manual: read it on the rendered site' "$TITLE")
fi

# Emit the parsed structure, plus date fields for the harness to
# avoid re-deriving them.
jq -n \
  --arg t "$TITLE" \
  --arg sl "$SLUG" \
  --arg d "$DESC" \
  --argjson tags "$(jq '.tags // []' <<<"$TEXT")" \
  --arg body "$BODY" \
  --arg pb "$PR_BODY" \
  --arg date "$TODAY" \
  --arg iso "$NOW_ISO" \
  '{title: $t, slug: $sl, description: $d, tags: $tags, body: $body, pr_body: $pb, date: $date, iso: $iso}'
