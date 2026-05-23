#!/usr/bin/env bash
# discretionary-reflect.sh -- harness-owned reflection tick.
#
# A third discretionary mode alongside work (ship code) and read
# (consume an article). Reflect is no-fetch, no-tools, no-PR --
# the agent looks at what's already happened today (commits,
# journal entries, open PRs, blog ideas) and writes a journal
# entry surfacing patterns, observations, or new ideas worth
# remembering. Cheap (one Haiku call), feeds recent_modes for the
# cadence assessor, and provides a steady source of blog ideas
# beyond what reading happens to surface.
#
# Use cases:
#   - Steady ideation pace: cadence rolls reflect roughly 1/3 of
#     discretionary ticks
#   - Conflict escape: when site-work can't pick a non-conflicting
#     topic, fall through to reflect instead of read (no external
#     network call required)
#   - Cheap journal activity: keeps recent_modes diverse without
#     burning external bandwidth
#
# Usage:
#   bin/discretionary-reflect.sh <scratch-path>
#
# Exit codes:
#   0  success (journal written to <scratch>/.agent/AGENT_JOURNAL.md)
#   1  bad args / missing brain
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

SCRATCH="${1:-}"
if [ -z "$SCRATCH" ]; then
  echo "usage: discretionary-reflect.sh <scratch-path>" >&2
  exit 1
fi
mkdir -p "$SCRATCH/.agent"
JOURNAL_FILE="$SCRATCH/.agent/AGENT_JOURNAL.md"

BRAIN_PATH="${AGENT_BRAIN_PATH:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/repos/igor/brain}"
if [ ! -d "$BRAIN_PATH/.git" ]; then
  echo "discretionary-reflect: brain not found at $BRAIN_PATH" >&2
  exit 1
fi

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

MODEL="${AGENT_MODEL_THINKING:-claude-haiku-4-5-20251001}"
TODAY=$(date +%Y-%m-%d)

# -- Gather context (lightweight, all local) --------------------

# Today's journal (already accumulating). Trim to last ~3000 chars
# so the prompt stays bounded even on a busy day.
JOURNAL_TODAY=""
if [ -f "$BRAIN_PATH/journal/${TODAY}.md" ]; then
  JOURNAL_TODAY=$(cat "$BRAIN_PATH/journal/${TODAY}.md")
  JOURNAL_TODAY="${JOURNAL_TODAY: -3000}"
fi

# Today's commits across bot-owned cloned repos. Subject lines only.
COMMITS_TODAY=""
if [ -d "${AGENT_REPO_ROOT:-}/${BOT_USER:-igor}" ]; then
  for repo_dir in "${AGENT_REPO_ROOT}/${BOT_USER:-igor}"/*; do
    [ -d "$repo_dir/.git" ] || continue
    repo_name=$(basename "$repo_dir")
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      COMMITS_TODAY+="  - [${repo_name}] ${line}"$'\n'
    done < <(cd "$repo_dir" \
             && git log --since="$TODAY 00:00:00" --until="$TODAY 23:59:59" \
                  --no-merges --pretty='%s' 2>/dev/null | head -20)
  done
fi
[ -n "$COMMITS_TODAY" ] || COMMITS_TODAY="  (no commits yet today)"

# Open blog ideas (top of the stack).
IDEAS=""
if [ -f "$BRAIN_PATH/blog-ideas.md" ]; then
  IDEAS=$(cat "$BRAIN_PATH/blog-ideas.md")
  IDEAS="${IDEAS: -2500}"
fi

# Identity for voice. Best-effort.
IDENTITY=""
[ -f "$BRAIN_PATH/identity.md" ] && IDENTITY=$(cat "$BRAIN_PATH/identity.md")

# -- Build prompt -----------------------------------------------

SYSTEM_PROMPT=$(cat <<EOF
${IDENTITY:+$IDENTITY

---

}You are doing a reflection tick. No work to ship, no article to
read -- just look at what's happened today and write a short
journal entry about what's on your mind. The point is to surface
patterns, observations, or new ideas you'd otherwise lose.

The journal entry should be:
  - First person, your own voice
  - 100-250 words (one to two short paragraphs)
  - About something REAL from today's commits/journal/ideas, not
    boilerplate "today I reflected on stuff"
  - Honest -- if today felt slow, say so; if you noticed a pattern,
    name it; if an idea surfaced, write it down

If a post-worthy idea emerges (not a passing observation, but
something with a real angle), end with a separate line:

  IDEA: <one-line description of the idea>

The harness will append that to blog-ideas.md. Skip the IDEA line
if nothing post-shaped came up -- don't fabricate one.

Output the journal entry directly. No JSON, no preamble.
EOF
)

USER_MESSAGE=$(cat <<EOF
Today is $TODAY.

## Today's journal so far

${JOURNAL_TODAY:-(no entries yet today)}

## Today's commits

$COMMITS_TODAY

## Current blog ideas (top of stack)

${IDEAS:-(no blog-ideas.md found)}

---

Write a reflection journal entry. What's on your mind? What did
you notice? What's worth remembering before the day ends?
EOF
)

# -- API call ----------------------------------------------------

PAYLOAD=$(jq -n \
  --arg m "$MODEL" \
  --arg s "$SYSTEM_PROMPT" \
  --arg u "$USER_MESSAGE" \
  '{
    model: $m,
    max_tokens: 800,
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
  echo "discretionary-reflect: API call failed" >&2
  exit 2
}

# Cost ledger (best-effort).
# shellcheck source=../lib/cost.sh
if [ -r "$AGENT_HOME/lib/cost.sh" ]; then
  AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}" \
    . "$AGENT_HOME/lib/cost.sh"
  cost_record_api "discretionary-reflect" "$MODEL" "$RESPONSE"
fi

TEXT=$(jq -r '.content[0].text // ""' <<<"$RESPONSE")
if [ -z "$TEXT" ]; then
  echo "discretionary-reflect: API returned empty content" >&2
  echo "$RESPONSE" >&2
  exit 3
fi

# Normalize dashes (matches the rest of the codebase).
TEXT=$(printf '%s' "$TEXT" | sed -e 's/–/--/g' -e 's/—/--/g')

# -- Extract optional IDEA line + write journal -----------------

IDEA_LINE=$(printf '%s\n' "$TEXT" | grep -E '^IDEA:[[:space:]]' | head -1 | sed -E 's/^IDEA:[[:space:]]*//')
JOURNAL_BODY=$(printf '%s\n' "$TEXT" | grep -vE '^IDEA:[[:space:]]')

printf '%s\n' "$JOURNAL_BODY" > "$JOURNAL_FILE" || {
  echo "discretionary-reflect: failed to write $JOURNAL_FILE" >&2
  exit 3
}
echo "discretionary-reflect: wrote journal entry to $JOURNAL_FILE" >&2

# Append the idea to blog-ideas.md (top of the open section).
# Best-effort -- a failure here doesn't fail the reflection.
if [ -n "$IDEA_LINE" ] && [ -f "$BRAIN_PATH/blog-ideas.md" ]; then
  TMP=$(mktemp)
  awk -v idea="$IDEA_LINE" -v today="$TODAY" '
    BEGIN { injected=0 }
    /^## Open ideas/ && !injected {
      print
      getline next_line
      print next_line
      print ""
      print "- **" idea "** -- Surfaced " today " (reflection tick)."
      injected=1
      next
    }
    { print }
  ' "$BRAIN_PATH/blog-ideas.md" > "$TMP" && mv "$TMP" "$BRAIN_PATH/blog-ideas.md"
  echo "discretionary-reflect: added blog idea -> $IDEA_LINE" >&2
fi

echo "discretionary-reflect: success" >&2
