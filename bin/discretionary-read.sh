#!/usr/bin/env bash
# discretionary-read.sh -- harness-owned reading tick executor.
#
# Replaces the "claude code does a shape-c reading tick" path with
# a direct API call. Discovers a URL, fetches + journals via
# bin/agent-read.sh, writes the journal file the brain commit
# flow expects, and appends the URL to the reading log.
#
# Usage:
#   bin/discretionary-read.sh <worktree-path>
#
# Reads:
#   IGOR_BRAIN_PATH    path to local brain clone
#   ANTHROPIC_API_KEY  (via agent-read.sh)
#
# Writes:
#   <worktree>/.igor/IGOR_JOURNAL.md  (picked up by the brain
#                                      commit flow in tick.sh)
#   $BRAIN_PATH/memories/reading/log.md (URL appended under today)
#
# Exit codes:
#   0   success
#   1   bad args / config
#   2   URL discovery failed (no candidates found)
#   3   agent-read.sh failed
#   4   journal write failed

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
  echo "usage: discretionary-read.sh <worktree-path>" >&2
  exit 1
fi

BRAIN_PATH="${IGOR_BRAIN_PATH:-${IGOR_STATE_DIR:-$HOME/.local/state/igor}/repos/igor/brain}"
LOG_FILE="$BRAIN_PATH/memories/reading/log.md"
JOURNAL_FILE="$WORKTREE/.igor/IGOR_JOURNAL.md"

# Discovery source: joshtronic.com/links. Igor already curates his
# reading from this page in practice. Configurable via env so
# different sources can be tested.
DISCOVERY_URL="${IGOR_READING_DISCOVERY_URL:-https://joshtronic.com/links/}"

mkdir -p "$(dirname "$JOURNAL_FILE")"

# -- discover candidate URL ---------------------------------------

discovery_html=$(curl -sfL \
  --max-time 15 \
  -A "Mozilla/5.0 (compatible; Igor/1.0; +https://igor.bot)" \
  "$DISCOVERY_URL" 2>/dev/null) || {
  echo "discretionary-read: discovery fetch failed for $DISCOVERY_URL" >&2
  exit 2
}

# Extract http(s) URLs from anchor tags. Exclude self-references,
# image/asset URLs, and common social/CDN domains that aren't real
# reading targets.
candidates=$(printf '%s' "$discovery_html" \
  | grep -oE 'href="https?://[^"]+"' \
  | sed -E 's/^href="//; s/"$//' \
  | grep -vE 'joshtronic\.com' \
  | grep -vE 'twitter\.com|x\.com|facebook\.com|linkedin\.com|github\.com/(login|signup)' \
  | grep -vE '\.(jpg|jpeg|png|gif|svg|ico|css|js|pdf|xml)(\?|$)' \
  | sort -u)

if [ -z "$candidates" ]; then
  echo "discretionary-read: no candidate URLs in discovery page" >&2
  exit 2
fi

# Filter out URLs already in the reading log (anywhere, any date).
fresh=""
while IFS= read -r url; do
  [ -z "$url" ] && continue
  if [ -f "$LOG_FILE" ] && grep -qF "$url" "$LOG_FILE" 2>/dev/null; then
    continue
  fi
  fresh+="$url"$'\n'
done <<<"$candidates"

if [ -z "$(printf '%s' "$fresh" | grep .)" ]; then
  echo "discretionary-read: every candidate URL is already in the reading log" >&2
  exit 2
fi

# Pick one at random.
URL=$(printf '%s' "$fresh" | grep . | shuf -n 1)
echo "discretionary-read: selected $URL" >&2

# -- call agent-read ---------------------------------------------

read_output=$("$IGOR_HOME/bin/agent-read.sh" "$URL") || {
  echo "discretionary-read: agent-read failed for $URL" >&2
  exit 3
}

TITLE=$(jq -r '.title // ""' <<<"$read_output")
JOURNAL=$(jq -r '.journal // ""' <<<"$read_output")

if [ -z "$JOURNAL" ]; then
  echo "discretionary-read: agent-read returned empty journal" >&2
  exit 3
fi

# -- write journal -----------------------------------------------

printf '%s\n' "$JOURNAL" > "$JOURNAL_FILE" || {
  echo "discretionary-read: failed to write $JOURNAL_FILE" >&2
  exit 4
}
echo "discretionary-read: wrote journal entry to $JOURNAL_FILE" >&2

# -- append to reading log ---------------------------------------

# Try to extract the source domain for the log entry's left-hand
# label. Fall back to the full URL if parsing fails.
domain=$(printf '%s' "$URL" \
  | sed -E 's|^https?://([^/]+).*|\1|' \
  | sed -E 's|^www\.||')

# Compose log entry: "- domain.com -- "Title" -- URL"
entry="- ${domain} -- \"${TITLE}\" -- ${URL}"

today=$(date +%Y-%m-%d)
mkdir -p "$(dirname "$LOG_FILE")"

# Ensure log file + today's heading exist, then append.
if [ ! -f "$LOG_FILE" ]; then
  cat > "$LOG_FILE" <<HDR
# Reading log

A dated list of things I've read. The harness appends to this on
every harness-driven reading tick. Takeaways and reflections live
in the journal entry from the tick I read it.

HDR
fi

if ! grep -qF "## $today" "$LOG_FILE"; then
  printf '\n## %s\n\n' "$today" >> "$LOG_FILE"
fi

# Idempotent append -- skip if exact entry already present (handles
# crash-retry within a tick; the URL-not-in-log check above handles
# the broader cross-tick case).
if ! grep -qF "$entry" "$LOG_FILE"; then
  printf '%s\n' "$entry" >> "$LOG_FILE"
fi

echo "discretionary-read: appended to reading log -> $entry" >&2
echo "discretionary-read: success" >&2
