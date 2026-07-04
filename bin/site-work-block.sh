#!/usr/bin/env bash
# site-work-block.sh -- the weekly site-work pass, and the /now refresh.
#
# Invoked by tick.sh's Igor cascade. Each call runs ONE directive's
# worth of work: either SITE-WORK (a weekly pass over the site --
# bugs, small features, restructures, a touch of polish) or NOW (the
# weekly refresh of the /now page from a digest of the week). The
# caller picks which via --directive.
#
# Per invocation:
#
#   1. Make a fresh worktree from the website's origin/master on
#      a new `agent/site-work-<ts>` branch.
#
#   2. Invoke Claude Code in that worktree with:
#        - The voice anchor (bin/lib/voice.md)
#        - The directive (site-work-directive.md or
#          now-directive.md)
#        - The repo's CLAUDE.md
#      No AGENTS.md -- non-issue-work surface.
#
#   3. After Claude exits: if commits landed AND .agent/PR_BODY.md
#      exists, push the branch + open a PR.
#
# Defaults to --dry-run: invokes Claude, observes what Claude
# does, but does NOT push or open a PR. Pass --live to opt in.
#
# Usage:
#   bin/site-work-block.sh --directive {site-work|now}
#                          [--website-path PATH] [--live]
#
# Required env:
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
#   WEBSITE_REPO      -- REQUIRED. Forgejo repo path (e.g.
#                        joshtronic/igor.bot). Unset = no website
#                        work; the block exits clean.
#   TICK_TIMEOUT      -- default 30m (Claude wall-clock cap)
#   FORGEJO_REVIEWER  -- optional, requested reviewer on opened PR
#
# Exit codes (the caller uses these to decide whether to mark the
# slot done for the day):
#   0  slot handled -- PR opened, OR Claude cleanly decided there
#      was nothing to do. Either way the slot is "spent" for today.
#   1  runtime error after Claude ran (commit/push/PR-open failed).
#      Work may be lost; caller should NOT mark the slot done.
#   2  setup error (bad args, missing files, bad worktree path).
#      Caller should NOT mark the slot done.

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

: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
: "${FORGEJO_HOST:?FORGEJO_HOST must be set}"
: "${BOT_USER:?BOT_USER must be set (resolved from token in tick.sh; export it before calling)}"

# WEBSITE_REPO is opt-in. The site-work block has no purpose
# without a target repo. Exit clean so the harness doesn't treat
# the no-website case as an error.
if [ -z "${WEBSITE_REPO:-}" ]; then
  echo "site-work-block: WEBSITE_REPO unset -- nothing to do (set it in .env to opt in)" >&2
  exit 0
fi

MODEL="${AGENT_MODEL:-claude-sonnet-4-6}"
TICK_TIMEOUT="${TICK_TIMEOUT:-30m}"
# Scope cap for the site-work directive: refuse to ship a pass whose
# diff exceeds this many changed lines. Keeps the weekly pass from
# becoming a rewrite. /now is a single page and exempt.
SITE_WORK_DIFF_CAP="${SITE_WORK_DIFF_CAP:-250}"
WEBSITE_PATH=""
LIVE=0
DIRECTIVE=""

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=../lib/claude.sh
. "$AGENT_HOME/lib/claude.sh"
# shellcheck source=../lib/security-gate.sh
. "$AGENT_HOME/lib/security-gate.sh"

# -- args ------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --directive)     DIRECTIVE="$2"; shift 2 ;;
    --website-path)  WEBSITE_PATH="$2"; shift 2 ;;
    --live)          LIVE=1; shift ;;
    -h|--help)       sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *)               echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$DIRECTIVE" in
  site-work|now) ;;
  "")  echo "site-work-block: --directive {site-work|now} is required" >&2; exit 2 ;;
  *)   echo "site-work-block: unknown directive '$DIRECTIVE' (want site-work|now)" >&2; exit 2 ;;
esac

WEBSITE_PATH="${WEBSITE_PATH:-$AGENT_REPO_ROOT/${WEBSITE_REPO}}"

# -- logging ---------------------------------------------------

log() { printf 'site-work-block: %s\n' "$*" >&2; }

# -- load voice anchor + directive -----------------------------

VOICE_FILE="$AGENT_HOME/bin/lib/voice.md"
DIRECTIVE_FILE="$AGENT_HOME/bin/lib/${DIRECTIVE}-directive.md"

if [ ! -f "$VOICE_FILE" ];     then log "voice anchor not found: $VOICE_FILE"; exit 2; fi
if [ ! -f "$DIRECTIVE_FILE" ]; then log "directive not found: $DIRECTIVE_FILE"; exit 2; fi

VOICE_BODY=$(cat "$VOICE_FILE")
DIRECTIVE_BODY=$(cat "$DIRECTIVE_FILE")

# -- website worktree setup ------------------------------------

if [ ! -d "$WEBSITE_PATH/.git" ]; then
  log "website worktree not found at $WEBSITE_PATH -- bootstrap not run?"
  exit 2
fi

BRANCH="agent/${DIRECTIVE}-$(date +%Y%m%d-%H%M%S)"
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

# The /now pass is handed a digest of the last week (reading +
# thoughts + recent posts), built by tick.sh and passed via
# NOW_DIGEST, so the page is grounded in what actually happened
# rather than guessed. Empty digest or non-now directive -> no
# section.
DIGEST_SECTION=""
if [ "$DIRECTIVE" = "now" ] && [ -n "${NOW_DIGEST:-}" ]; then
  DIGEST_SECTION=$(cat <<EOF


---

## Digest of the last week (your memory of what happened)

${NOW_DIGEST}
EOF
)
fi

# User message: the directive + a context paragraph.
USER_MSG=$(cat <<EOF
You're running the ${DIRECTIVE} pass on ${WEBSITE_REPO}. Working
directory: this worktree, branched fresh from origin/master.

${DIRECTIVE_BODY}${DIGEST_SECTION}

---

The harness commits any dirty files outside .agent/ after you
exit and uses your PR_BODY as the PR body verbatim.

If nothing on the directive applies, exit clean -- write nothing,
change nothing. Don't force a change.
EOF
)

# -- invoke Claude --------------------------------------------

DISPLAY_LOG="$WORKTREE/.agent/claude-output.log"
call_site="site-work-${DIRECTIVE}"

log "invoking Claude (call_site=$call_site, timeout=$TICK_TIMEOUT, model=$MODEL)"
cd "$WORKTREE"

set +e
claude_run_with_cost "$call_site" "$DISPLAY_LOG" "$TICK_TIMEOUT" \
  --model "$MODEL" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --settings "$AGENT_HOME/agent-settings.json" \
  --max-turns "${AGENT_MAX_TURNS:-50}" \
  --print "$USER_MSG"
CLAUDE_EXIT=$?
set -e

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

# Derive the commit subject / PR title from the first "What this
# PR does" checklist item (the directive requires this shape).
# Runs regardless of whether Claude committed directly or left
# dirty files, so PR_TITLE is always set. Falls back to a safe
# default if the item is missing or unparseable.
COMMIT_SUBJECT=$(pr_body_first_item "$PR_BODY_FILE")
if [ -z "$COMMIT_SUBJECT" ]; then
  log "warning: PR_BODY.md missing '## What this PR does' first item -- using fallback subject"
  COMMIT_SUBJECT="chore: site-work ${DIRECTIVE} slot"
elif ! looks_like_conventional_commit "$COMMIT_SUBJECT"; then
  log "warning: PR_BODY.md first item missing conventional-commit prefix -- prepending 'chore: '"
  COMMIT_SUBJECT="chore: $COMMIT_SUBJECT"
fi
COMMIT_SUBJECT=$(printf '%s' "$COMMIT_SUBJECT" | head -c 72)
PR_TITLE="$COMMIT_SUBJECT"

# Auto-commit any dirty paths outside .agent/ (Claude may have
# left changes uncommitted). If Claude already committed
# directly, DIRTY_PATHS is empty and this is a no-op.
if [ -n "$DIRTY_PATHS" ]; then
  git add -A
  git commit --quiet -m "$COMMIT_SUBJECT" || {
    log "harness-commit failed"
    exit 1
  }
  log "harness-commit: $COMMIT_SUBJECT"
fi

# -- scope cap (site-work) -------------------------------------
#
# Refuse to ship a site-work pass whose diff is too large -- that's
# the line between "a weekly pass" and "a rewrite". /now is a single
# page and exempt. Over the cap: log, don't ship, exit 0 (the slot
# is spent; a human can pick the work up). Applies in dry-run too so
# the cap is visible before going live.
if [ "$DIRECTIVE" = "site-work" ]; then
  CHANGED_LINES=$(git diff --shortstat "origin/master..HEAD" 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
  CHANGED_LINES=${CHANGED_LINES:-0}
  if [ "$CHANGED_LINES" -gt "$SITE_WORK_DIFF_CAP" ]; then
    log "scope cap: ${CHANGED_LINES} changed lines > ${SITE_WORK_DIFF_CAP} cap -- refusing to ship this pass (a human can pick it up)"
    exit 0
  fi
  log "scope: ${CHANGED_LINES} changed lines (cap ${SITE_WORK_DIFF_CAP})"
fi

# -- push + open PR --------------------------------------------

if [ "$LIVE" != "1" ]; then
  log "DRY-RUN: would push branch $BRANCH and open PR titled: $PR_TITLE"
  log "  PR body file: $PR_BODY_FILE"
  log "  (head -3 of PR body):"
  head -3 "$PR_BODY_FILE" | sed 's/^/    /' >&2
  exit 0
fi

# Security gate before shipping. No issue/PR exists yet, so a block is
# surfaced to the operator in the log and the change is simply not
# shipped (the slot still counts as spent -- re-running would just
# re-flag it). The agent's own pass is the fix-early line; this is the
# unskippable one.
if SEC_FINDINGS=$(security_gate "$WORKTREE" "master" "security-gate-site-work"); then
  :
else
  log "SECURITY GATE BLOCKED -- not pushing this ${DIRECTIVE} change. Findings:"
  printf '%s\n' "$SEC_FINDINGS" | sed 's/^/  /' >&2
  exit 0
fi

git push -u origin "$BRANCH" || {
  log "git push failed"
  exit 1
}

PR_BODY_CONTENT=$(cat "$PR_BODY_FILE")
PR_NUM=$(forgejo_open_pr "$WEBSITE_REPO" "$BRANCH" "master" \
                          "$PR_TITLE" "$PR_BODY_CONTENT")
if [ -z "$PR_NUM" ]; then
  log "PR open via Forgejo API returned empty; branch is pushed -- inspect manually"
  exit 1
fi
log "PR opened: #$PR_NUM"
