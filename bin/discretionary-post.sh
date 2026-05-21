#!/usr/bin/env bash
# discretionary-post.sh -- harness-owned post tick executor.
#
# Picks a queued blog idea from brain/blog-ideas.md, drafts a full
# post via bin/agent-post.sh, writes the post file under
# src/posts/YYYY/, writes PR_BODY.md, and removes the used idea
# from blog-ideas.md so it doesn't get reshipped.
#
# Usage:
#   bin/discretionary-post.sh <worktree-path>
#
# Reads:
#   IGOR_BRAIN_PATH    path to local brain clone
#   ANTHROPIC_API_KEY  (via agent-post.sh)
#
# Writes (inside the worktree):
#   src/posts/YYYY/YYYY-MM-DD-<slug>.md   -- the post file
#   .igor/PR_BODY.md                       -- two-checklist PR body
#
# Writes (in brain):
#   blog-ideas.md  -- minus the used idea (so it won't reship)
#
# Exit codes:
#   0   success
#   1   bad args
#   2   no usable blog ideas in brain/blog-ideas.md
#   3   agent-post.sh failed
#   4   file write failed

set -uo pipefail

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "usage: discretionary-post.sh <worktree-path>" >&2
  exit 1
fi

BRAIN_PATH="${IGOR_BRAIN_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/brain}"
IDEAS_FILE="$BRAIN_PATH/blog-ideas.md"
PR_BODY_FILE="$WORKTREE/.igor/PR_BODY.md"

mkdir -p "$(dirname "$PR_BODY_FILE")"

# -- pick a blog idea ---------------------------------------------

if [ ! -f "$IDEAS_FILE" ]; then
  echo "discretionary-post: no blog-ideas.md found at $IDEAS_FILE" >&2
  exit 2
fi

# Each idea is a bullet-list entry, possibly with continuation
# lines (indented or following). Treat any "- " at column 0 as the
# start of an idea, gather until the next "- " or EOF.
#
# Strategy: number ideas, pick one at random, return its full
# text (header + continuation).
ideas_count=$(grep -cE '^- ' "$IDEAS_FILE" 2>/dev/null || echo 0)
if [ "$ideas_count" -le 0 ]; then
  echo "discretionary-post: blog-ideas.md is empty -- nothing to draft" >&2
  exit 2
fi

# Pick a random 1-indexed idea number
PICK=$((RANDOM % ideas_count + 1))

# Extract the picked idea: from the Nth `- ` line until the next
# `- ` line (or end of file). awk handles the multi-line case.
IDEA_TEXT=$(awk -v n="$PICK" '
  /^- / { count++; if (count == n) { in_idea = 1; print; next } if (in_idea) { in_idea = 0; exit } }
  in_idea { print }
' "$IDEAS_FILE")

if [ -z "$IDEA_TEXT" ]; then
  echo "discretionary-post: idea extraction returned empty (pick=$PICK / $ideas_count)" >&2
  exit 2
fi

echo "discretionary-post: picked idea $PICK / $ideas_count:" >&2
echo "$IDEA_TEXT" | sed 's/^/  /' >&2

# -- draft via agent-post -----------------------------------------

draft=$("$IGOR_HOME/bin/agent-post.sh" "$IDEA_TEXT") || {
  echo "discretionary-post: agent-post failed" >&2
  exit 3
}

TITLE=$(jq -r '.title // ""' <<<"$draft")
SLUG=$(jq -r '.slug // ""' <<<"$draft")
DESC=$(jq -r '.description // ""' <<<"$draft")
BODY=$(jq -r '.body // ""' <<<"$draft")
PR_BODY=$(jq -r '.pr_body // ""' <<<"$draft")
DATE_YMD=$(jq -r '.date // ""' <<<"$draft")
ISO=$(jq -r '.iso // ""' <<<"$draft")
TAGS_JSON=$(jq -c '.tags // []' <<<"$draft")

if [ -z "$TITLE" ] || [ -z "$SLUG" ] || [ -z "$BODY" ] || [ -z "$PR_BODY" ]; then
  echo "discretionary-post: agent-post returned incomplete draft" >&2
  exit 3
fi

# -- write the post file ------------------------------------------

YEAR=$(printf '%s' "$DATE_YMD" | cut -d- -f1)
POST_DIR="$WORKTREE/src/posts/$YEAR"
POST_FILE="$POST_DIR/${DATE_YMD}-${SLUG}.md"

mkdir -p "$POST_DIR" || {
  echo "discretionary-post: failed to mkdir $POST_DIR" >&2
  exit 4
}

# Convert tags JSON array to YAML inline array.
TAGS_YAML=$(jq -r '"[" + (map(tojson) | join(", ")) + "]"' <<<"$TAGS_JSON")

{
  printf -- '---\n'
  printf 'title: "%s"\n' "${TITLE//\"/\\\"}"
  printf 'description: "%s"\n' "${DESC//\"/\\\"}"
  printf 'date: %s\n' "$ISO"
  printf 'tags: %s\n' "$TAGS_YAML"
  printf -- '---\n\n'
  printf '%s\n' "$BODY"
} > "$POST_FILE" || {
  echo "discretionary-post: failed to write $POST_FILE" >&2
  exit 4
}
echo "discretionary-post: wrote post to $POST_FILE" >&2

# -- write PR_BODY.md ---------------------------------------------

printf '%s\n' "$PR_BODY" > "$PR_BODY_FILE" || {
  echo "discretionary-post: failed to write $PR_BODY_FILE" >&2
  exit 4
}
echo "discretionary-post: wrote PR body to $PR_BODY_FILE" >&2

# -- remove the used idea from blog-ideas.md ----------------------

# Delete the Nth `- ` block (header + continuations) from the
# file. Same awk logic as extraction, inverted (print everything
# EXCEPT the picked block).
tmp=$(mktemp)
awk -v n="$PICK" '
  /^- / { count++; if (count == n) { in_skip = 1; next } if (in_skip) { in_skip = 0 } }
  in_skip { next }
  { print }
' "$IDEAS_FILE" > "$tmp" && mv "$tmp" "$IDEAS_FILE"
echo "discretionary-post: removed used idea from blog-ideas.md" >&2

echo "discretionary-post: success" >&2
