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
# Strategy: the ideas list is priority-ordered (top = next up).
# A post-discretionary-tick reflection (bin/agent-reflect-ideas.py)
# shuffles ideas up/down based on freshness signals, so picking
# the top is "take the most timely idea right now". The old
# uniform-random sample was thrown away once the reflection loop
# landed -- random + reflective re-ordering would be working
# against each other.
# Helpers for dedupe-against-shipped scan.
#
# An idea is considered already-shipped if 2+ significant tokens
# from its title appear in any existing post filename under
# src/posts/. "Significant" = lowercase, >=4 chars, not a common
# stop-word. Slugs are derived from titles via kebab-case, so
# token-overlap on the filename is a robust proxy for "we already
# shipped a post on this idea" even when the slug isn't byte-equal
# to a naive slugify of the title.
#
# Examples:
#   "hand-written by the robot" -> tokens: hand, written, robot
#   matches: 2026-05-19-hand-written-by-the-robot.md (3/3 match)
#   "the security model you get for free" -> tokens: security,
#   model, free -> no shipped post matches
extract_title_from_idea() {
  printf '%s' "$1" | head -1 | grep -oE '"[^"]+"' | head -1 | sed 's/^"//; s/"$//'
}

title_significant_tokens() {
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 4' \
    | grep -vxE 'this|that|with|when|what|from|have|been|were|over|into|than|then|just|like|some|even|most|will|your|they|them|their|about|after|under|while|every|might|could|would|should|where|which'
}

# Returns 0 (dupe found) if any post file in src/posts/ matches
# 2+ significant tokens from the title. Echoes the matched filename
# on stdout for logging.
idea_is_dupe() {
  local title="$1"
  local posts_dir="$WORKTREE/src/posts"
  [ -d "$posts_dir" ] || return 1

  local tokens
  tokens=$(title_significant_tokens "$title")
  [ -z "$tokens" ] && return 1

  # Need at least 2 tokens to make the match meaningful; otherwise
  # a single-word title would false-positive everywhere.
  local token_count
  token_count=$(printf '%s\n' "$tokens" | wc -l)
  [ "$token_count" -lt 2 ] && return 1

  local post_file filename match_count tok matched_file
  while IFS= read -r post_file; do
    [ -z "$post_file" ] && continue
    filename=$(basename "$post_file" .md | tr 'A-Z' 'a-z')
    match_count=0
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      case "$filename" in
        *"$tok"*) match_count=$((match_count + 1)) ;;
      esac
    done <<<"$tokens"
    if [ "$match_count" -ge 2 ]; then
      printf '%s' "$(basename "$post_file")"
      return 0
    fi
  done < <(find "$posts_dir" -name '*.md' -type f 2>/dev/null)
  return 1
}

# Remove the Nth `- ` block from blog-ideas.md (in place).
remove_idea_at() {
  local n="$1"
  local tmp; tmp=$(mktemp)
  awk -v n="$n" '
    /^- / { count++; if (count == n) { in_skip = 1; next } if (in_skip) { in_skip = 0 } }
    in_skip { next }
    { print }
  ' "$IDEAS_FILE" > "$tmp" && mv "$tmp" "$IDEAS_FILE"
}

# Loop: scan the top of the stack, remove any dupes we find,
# stop at the first idea that doesn't match a shipped post.
# Cap iterations so a malformed ideas file can't loop forever.
PICK=1
IDEA_TEXT=""
DUPE_REMOVED=0
MAX_DUPE_SCAN=10
scan=0
while [ "$scan" -lt "$MAX_DUPE_SCAN" ]; do
  scan=$((scan + 1))
  ideas_count=$(grep -cE '^- ' "$IDEAS_FILE" 2>/dev/null || echo 0)
  if [ "$ideas_count" -le 0 ]; then
    echo "discretionary-post: blog-ideas.md is empty -- nothing to draft" >&2
    exit 2
  fi

  IDEA_TEXT=$(awk -v n="$PICK" '
    /^- / { count++; if (count == n) { in_idea = 1; print; next } if (in_idea) { in_idea = 0; exit } }
    in_idea { print }
  ' "$IDEAS_FILE")
  if [ -z "$IDEA_TEXT" ]; then
    echo "discretionary-post: idea extraction returned empty (pick=$PICK / $ideas_count)" >&2
    exit 2
  fi

  TITLE_FOR_DUPE=$(extract_title_from_idea "$IDEA_TEXT")
  if [ -z "$TITLE_FOR_DUPE" ]; then
    # Malformed idea (no quoted title); skip dupe check, take it as-is.
    break
  fi

  matched=$(idea_is_dupe "$TITLE_FOR_DUPE") && {
    echo "discretionary-post: idea '$TITLE_FOR_DUPE' looks like already-shipped post '$matched' -- removing from stack" >&2
    remove_idea_at "$PICK"
    DUPE_REMOVED=$((DUPE_REMOVED + 1))
    IDEA_TEXT=""
    continue
  }
  break
done

if [ -z "$IDEA_TEXT" ]; then
  echo "discretionary-post: scanned $scan idea(s), removed $DUPE_REMOVED dupe(s), nothing left to draft" >&2
  exit 2
fi

if [ "$DUPE_REMOVED" -gt 0 ]; then
  echo "discretionary-post: cleaned $DUPE_REMOVED already-shipped idea(s) from blog-ideas.md before picking" >&2
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
sed -i.bak -e 's/–/--/g' -e 's/—/--/g' "$POST_FILE" && rm -f "${POST_FILE}.bak"
echo "discretionary-post: wrote post to $POST_FILE" >&2

# -- write PR_BODY.md ---------------------------------------------

printf '%s\n' "$PR_BODY" > "$PR_BODY_FILE" || {
  echo "discretionary-post: failed to write $PR_BODY_FILE" >&2
  exit 4
}
sed -i.bak -e 's/–/--/g' -e 's/—/--/g' "$PR_BODY_FILE" && rm -f "${PR_BODY_FILE}.bak"
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

# -- post-tick ideas reflection ----------------------------------
#
# What Igor just wrote shifts what feels timely. Hand the post
# body to the reflection helper; it asks Haiku whether any
# remaining ideas should bubble up or sink down a slot. Bounded
# (max 3 moves, 1 slot each). Failures are silent -- the post
# already shipped.

if [ -x "$IGOR_HOME/bin/agent-reflect-ideas.py" ]; then
  python3 "$IGOR_HOME/bin/agent-reflect-ideas.py" \
    "$POST_FILE" "$IDEAS_FILE" 2>&1 \
    | sed 's/^/discretionary-post: ideas-reflection: /' >&2 \
    || true
fi

echo "discretionary-post: success" >&2
