#!/usr/bin/env bash
# site-work-block.sh -- the new directed-list-or-exit site-work
# executor.
#
# Replaces the discretionary site-work branch in tick.sh. STANDALONE
# -- not wired in yet; Phase 4 does that. Old discretionary paths
# stay live in tick.sh until then.
#
# Per invocation:
#
#   1. Roll a 10-sided die. 1-in-10 -> PLAY_TICK=1 (loose
#      "play" directive). Otherwise 0 (directed-list directive).
#      Forceable via the --play-tick / --no-play-tick flags or
#      the PLAY_TICK env var for testing.
#
#   2. Make a fresh worktree from the website's origin/master on a
#      new `agent/site-work-<ts>` branch.
#
#   3. Invoke Claude Code in that worktree with:
#        - The voice anchor (bin/lib/voice.md)
#        - The appropriate directive (site-work-directives.md OR
#          play-tick-directive.md)
#        - The repo's CLAUDE.md
#      No AGENTS.md -- Phase 5 retires it for non-issue-work
#      surfaces; this block is one such surface from the start.
#
#   4. After Claude exits: if commits landed AND .agent/PR_BODY.md
#      exists, push the branch + open a PR. On a play tick,
#      prepend the "this was a play tick" note to PR_BODY.md
#      before opening.
#
# Defaults to --dry-run: invokes Claude, observes what Claude does,
# but does NOT push or open a PR. Pass --live to opt in.
#
# Usage:
#   bin/site-work-block.sh [--website-path PATH] [--play-tick |
#     --no-play-tick] [--live]
#
# Required env:
#   ANTHROPIC_API_KEY  -- for Claude invocation
#   FORGEJO_URL        -- e.g. https://git.sherver.org
#   FORGEJO_TOKEN      -- for PR open
#   FORGEJO_HOST       -- e.g. git.sherver.org
#   BOT_USER           -- e.g. igor (resolved from token in tick.sh)
#
# Optional env:
#   AGENT_MODEL       -- default claude-sonnet-4-6
#   AGENT_STATE_DIR   -- default ~/.local/state/agent
#   AGENT_HOME        -- default <script-parent-dir>
#   AGENT_REPO_ROOT   -- default $AGENT_STATE_DIR/repos
#   WEBSITE_REPO      -- default $BOT_USER/website (Forgejo repo)
#   TICK_TIMEOUT      -- default 30m (Claude wall-clock cap)
#   PLAY_TICK         -- 0 or 1; if set, overrides the dice roll
#   FORGEJO_REVIEWER  -- optional, assignee on opened PR

set -uo pipefail

# -- env + libs ------------------------------------------------

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
AGENT_REPO_ROOT="${AGENT_REPO_ROOT:-$AGENT_STATE_DIR/repos}"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"
: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
: "${FORGEJO_HOST:?FORGEJO_HOST must be set}"
: "${BOT_USER:?BOT_USER must be set (resolved from token in tick.sh; export it before calling)}"

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
TICK_TIMEOUT="${TICK_TIMEOUT:-30m}"
WEBSITE_REPO="${WEBSITE_REPO:-${BOT_USER}/website}"
WEBSITE_PATH=""
LIVE=0
PLAY_TICK_OVERRIDE="${PLAY_TICK:-}"

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"

# -- args ------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --website-path)  WEBSITE_PATH="$2"; shift 2 ;;
    --live)          LIVE=1; shift ;;
    --play-tick)     PLAY_TICK_OVERRIDE=1; shift ;;
    --no-play-tick)  PLAY_TICK_OVERRIDE=0; shift ;;
    -h|--help)       sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *)               echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

WEBSITE_PATH="${WEBSITE_PATH:-$AGENT_REPO_ROOT/${BOT_USER}/website}"

# -- logging ---------------------------------------------------

log() { printf 'site-work-block: %s\n' "$*" >&2; }

# -- resolve play-tick -----------------------------------------

if [ -n "$PLAY_TICK_OVERRIDE" ]; then
  PLAY_TICK="$PLAY_TICK_OVERRIDE"
  log "PLAY_TICK forced to $PLAY_TICK via override"
else
  # 10-sided die: 1-in-10 chance of play
  if [ "$((RANDOM % 10))" -eq 0 ]; then
    PLAY_TICK=1
  else
    PLAY_TICK=0
  fi
  log "rolled PLAY_TICK=$PLAY_TICK"
fi

# -- load voice anchor + directive -----------------------------

VOICE_FILE="$AGENT_HOME/bin/lib/voice.md"
DIRECTIVE_FILE="$AGENT_HOME/bin/lib/site-work-directives.md"
[ "$PLAY_TICK" = "1" ] && DIRECTIVE_FILE="$AGENT_HOME/bin/lib/play-tick-directive.md"

if [ ! -f "$VOICE_FILE" ];     then log "voice anchor not found: $VOICE_FILE"; exit 2; fi
if [ ! -f "$DIRECTIVE_FILE" ]; then log "directive not found: $DIRECTIVE_FILE"; exit 2; fi

VOICE_BODY=$(cat "$VOICE_FILE")
DIRECTIVE_BODY=$(cat "$DIRECTIVE_FILE")

# -- website worktree setup ------------------------------------

if [ ! -d "$WEBSITE_PATH/.git" ]; then
  log "website worktree not found at $WEBSITE_PATH -- bootstrap not run?"
  exit 2
fi

BRANCH="agent/site-work-$(date +%Y%m%d-%H%M%S)"
WORKTREE="$AGENT_STATE_DIR/worktrees/site-work-$$"
mkdir -p "$AGENT_STATE_DIR/worktrees"

# Cleanup the worktree at exit no matter what.
# shellcheck disable=SC2064
trap "(cd '$WEBSITE_PATH' && git worktree remove --force '$WORKTREE') 2>/dev/null || rm -rf '$WORKTREE' 2>/dev/null || true" EXIT

(cd "$WEBSITE_PATH" && git fetch --prune origin) || {
  log "git fetch failed"
  exit 1
}
(cd "$WEBSITE_PATH" && git worktree add -B "$BRANCH" "$WORKTREE" origin/master) || {
  log "git worktree add failed"
  exit 1
}
mkdir -p "$WORKTREE/.agent"

# -- build the prompts ----------------------------------------

REPO_CLAUDE_MD=""
[ -f "$WORKTREE/CLAUDE.md" ] && REPO_CLAUDE_MD=$(cat "$WORKTREE/CLAUDE.md")

# System prompt: voice + repo conventions. No AGENTS.md.
SYSTEM_PROMPT=$(cat <<EOF
${VOICE_BODY}

---

${REPO_CLAUDE_MD}
EOF
)

# User message: the directive + a context paragraph.
USER_MSG=$(cat <<EOF
You're doing a site-work block on ${WEBSITE_REPO}. Working
directory: this worktree, branched fresh from origin/master.

${DIRECTIVE_BODY}

---

When you ship, write a one-or-two-paragraph .agent/PR_BODY.md
describing what changed and why. The harness commits any dirty
files outside .agent/ after you exit and uses your PR_BODY as
the PR body verbatim.

If nothing on the directive applies today, exit clean -- write
nothing, change nothing. The next block fires later.
EOF
)

# -- invoke Claude (mirror claude_run_with_cost pattern) -------

STREAM_LOG="$WORKTREE/.agent/claude-stream.jsonl"
DISPLAY_LOG="$WORKTREE/.agent/claude-output.log"
: > "$STREAM_LOG"; : > "$DISPLAY_LOG"

call_site="site-work"
[ "$PLAY_TICK" = "1" ] && call_site="site-work-play"

log "invoking Claude (call_site=$call_site, timeout=$TICK_TIMEOUT, model=$MODEL)"
cd "$WORKTREE"

set +e
set -o pipefail
timeout --kill-after=30s "$TICK_TIMEOUT" \
  claude --output-format stream-json --verbose --include-partial-messages \
    --model "$MODEL" \
    --append-system-prompt "$SYSTEM_PROMPT" \
    --settings "$AGENT_HOME/agent-settings.json" \
    --max-turns 50 \
    --print "$USER_MSG" 2>&1 \
  | tee "$STREAM_LOG" \
  | jq -r --unbuffered '
      if (try .type catch null) == "assistant" then
        (.message.content // [])[]
        | if .type == "text" then .text
          elif .type == "tool_use" then "[tool: \(.name)]"
          else empty
          end
      elif (try .type catch null) == "user" then
        (.message.content // [])[]
        | if .type == "tool_result" then "[tool_result]"
          else empty
          end
      else empty
      end
    ' 2>/dev/null \
  | tee "$DISPLAY_LOG"
CLAUDE_EXIT=${PIPESTATUS[0]}
set +o pipefail
set -e

cost_record_cli "$call_site" "$STREAM_LOG"
log "claude exited $CLAUDE_EXIT"

# -- process outcome ------------------------------------------

# Did Claude actually do work? Two signals, both required to ship:
#   (a) at least one commit OR dirty files outside .agent/
#   (b) .agent/PR_BODY.md exists and is non-empty

cd "$WORKTREE"
DIRTY_PATHS=$(git status --porcelain 2>/dev/null \
  | awk '$2 !~ /^\.agent\// { print $2 }')
COMMITS_AHEAD=$(git rev-list --count "origin/master..HEAD" 2>/dev/null || echo 0)
PR_BODY_FILE="$WORKTREE/.agent/PR_BODY.md"

if [ -z "$DIRTY_PATHS" ] && [ "$COMMITS_AHEAD" -eq 0 ]; then
  log "no changes -- claude exited without shipping (this is fine)"
  exit 0
fi

if [ ! -s "$PR_BODY_FILE" ]; then
  log "WARNING: changes detected but no PR_BODY.md written -- claude violated the directive"
  log "  dirty paths: $(echo "$DIRTY_PATHS" | tr '\n' ' ')"
  log "  commits ahead: $COMMITS_AHEAD"
  log "  not shipping; the directive requires a PR body"
  exit 0
fi

# Auto-commit any dirty paths outside .agent/, mirroring the
# harness pattern. Subject is the first line of PR_BODY.md or a
# generic fallback.
if [ -n "$DIRTY_PATHS" ]; then
  git add -A
  COMMIT_SUBJECT=$(head -1 "$PR_BODY_FILE" \
    | sed -E 's/^[*_# ]+//; s/[*_]+$//' \
    | head -c 72)
  [ -z "$COMMIT_SUBJECT" ] && COMMIT_SUBJECT="chore: site-work block"
  git commit --quiet -m "$COMMIT_SUBJECT" || {
    log "harness-commit failed"
    exit 1
  }
  log "harness-commit: $COMMIT_SUBJECT"
fi

# Prepend the play-tick note to PR_BODY.md.
if [ "$PLAY_TICK" = "1" ]; then
  tmp=$(mktemp)
  printf '**This was a play tick.** Reject without prejudice if the vibe is off.\n\n' > "$tmp"
  cat "$PR_BODY_FILE" >> "$tmp"
  mv "$tmp" "$PR_BODY_FILE"
  log "prepended play-tick note to PR_BODY.md"
fi

# -- push + open PR --------------------------------------------

PR_TITLE=$(head -1 "$PR_BODY_FILE" \
  | sed -E 's/^[*_# ]+//; s/[*_]+$//' \
  | head -c 72)
[ -z "$PR_TITLE" ] && PR_TITLE="chore: site-work block"

if [ "$LIVE" != "1" ]; then
  log "DRY-RUN: would push branch $BRANCH and open PR titled: $PR_TITLE"
  log "  PR body file: $PR_BODY_FILE"
  log "  (head -3 of PR body):"
  head -3 "$PR_BODY_FILE" | sed 's/^/    /' >&2
  exit 0
fi

git push -u origin "$BRANCH" || {
  log "git push failed"
  exit 1
}

PR_BODY_CONTENT=$(cat "$PR_BODY_FILE")
PR_NUM=$(forgejo_open_pr "$WEBSITE_REPO" "$BRANCH" "master" \
                          "$PR_TITLE" "$PR_BODY_CONTENT" \
                          "${FORGEJO_REVIEWER:-}")
if [ -z "$PR_NUM" ]; then
  log "PR open via Forgejo API returned empty; branch is pushed -- inspect manually"
  exit 1
fi
log "PR opened: #$PR_NUM"
