#!/usr/bin/env bash
# tick.sh — claim one Agent-labeled Forgejo issue and work it.
#
# Usage: tick.sh <project-name>
#
# Loads $IGOR_HOME/projects/<project-name>.conf, finds the oldest
# claimable issue, creates a worktree, invokes Claude, then either
# opens a PR, posts a "no work" comment, or relies on the agent
# having already flipped the issue (report or blocked) itself.
#
# Exits 0 on success or no-work-found. Non-zero on configuration
# or infrastructure errors.

set -euo pipefail

# ── Paths and project ──────────────────────────────────────────

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${IGOR_STATE_DIR:-$HOME/.local/state/igor}"
PROJECT="${1:?usage: tick.sh <project-name>}"

CONF="$IGOR_HOME/projects/${PROJECT}.conf"
[ -f "$CONF" ] || { echo "tick: no conf at $CONF" >&2; exit 2; }

# Defaults
PR_BASE="main"
TICK_TIMEOUT="60m"
ENQUEUE_INTERVAL=""
ENQUEUE_CMD=""

# shellcheck source=/dev/null
. "$CONF"

: "${REPO_PATH:?REPO_PATH required in $CONF}"
: "${FORGEJO_REPO:?FORGEJO_REPO required in $CONF}"

# ── Secrets ────────────────────────────────────────────────────

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN must be set (via $IGOR_HOME/.env)}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set (via $IGOR_HOME/.env)}"
: "${FORGEJO_URL:?FORGEJO_URL must be set (via $IGOR_HOME/.env)}"

# ── Library ────────────────────────────────────────────────────

# shellcheck source=lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"

# ── Lock (one tick per project at a time) ──────────────────────

mkdir -p "$STATE_DIR/locks"
LOCK="$STATE_DIR/locks/${PROJECT}.lock"
exec 200>"$LOCK"
if ! flock -n 200; then
  echo "tick:$PROJECT already running — exiting" >&2
  exit 0
fi

# ── Logging helper ─────────────────────────────────────────────

log() { printf '[tick:%s] %s\n' "$PROJECT" "$*"; }

# ── Cleanup on exit ────────────────────────────────────────────

WORKTREE=""
ISSUE_NUMBER=""

cleanup() {
  local rc=$?
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    log "removing worktree $WORKTREE"
    (cd "$REPO_PATH" && git worktree remove "$WORKTREE" --force) 2>/dev/null || true
  fi
  if [ -n "$ISSUE_NUMBER" ]; then
    (cd "$REPO_PATH" && git branch -D "agent/${ISSUE_NUMBER}") 2>/dev/null || true
  fi
  exit $rc
}
trap cleanup EXIT

# ── Find work ──────────────────────────────────────────────────

ISSUE_JSON=$(forgejo_find_claimable "$FORGEJO_REPO" || true)
if [ -z "$ISSUE_JSON" ] || [ "$ISSUE_JSON" = "null" ] || [ "$ISSUE_JSON" = "empty" ]; then
  log "no claimable work"
  exit 0
fi

ISSUE_NUMBER=$(jq -r .number  <<<"$ISSUE_JSON")
ISSUE_TITLE=$(jq -r .title    <<<"$ISSUE_JSON")
ISSUE_BODY=$(jq -r '.body // ""' <<<"$ISSUE_JSON")
ISSUE_LABELS=$(jq -r '[.labels[].name] | join(", ")' <<<"$ISSUE_JSON")

log "claiming #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

# ── Claim ──────────────────────────────────────────────────────

forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" igor

# ── Worktree ───────────────────────────────────────────────────

mkdir -p "$STATE_DIR/worktrees"
WORKTREE="$STATE_DIR/worktrees/${PROJECT}-${ISSUE_NUMBER}"
if [ -e "$WORKTREE" ]; then
  log "stale worktree at $WORKTREE — aborting"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"
  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
    "Tick aborted: stale worktree from a previous run was present at \`$WORKTREE\`. Investigate and clear before retrying."
  exit 4
fi

cd "$REPO_PATH"
git fetch origin --prune
git worktree add -b "agent/${ISSUE_NUMBER}" "$WORKTREE" "origin/${PR_BASE}"

# ── Invoke Claude ──────────────────────────────────────────────

cd "$WORKTREE"

# Helpers (agent-block, etc.) need to be on PATH inside Claude's shell.
export PATH="$IGOR_HOME/bin:$PATH"

# Helpers also read these from env.
export ISSUE_NUMBER ISSUE_TITLE FORGEJO_REPO PR_BASE IGOR_HOME

USER_MSG=$(cat <<EOF
You are working Forgejo issue #${ISSUE_NUMBER} in ${FORGEJO_REPO}.

Title: ${ISSUE_TITLE}
Labels: ${ISSUE_LABELS}

Body:
${ISSUE_BODY}
EOF
)

log "invoking claude (timeout ${TICK_TIMEOUT})"
set +e
timeout --kill-after=30s "$TICK_TIMEOUT" \
  claude \
    --append-system-prompt "$(cat "$IGOR_HOME/AGENTS.md")" \
    --print "$USER_MSG"
CLAUDE_EXIT=$?
set -e
log "claude exited $CLAUDE_EXIT"

# ── Determine outcome ──────────────────────────────────────────

cd "$WORKTREE"
COMMITS=$(git rev-list --count "origin/${PR_BASE}..HEAD" 2>/dev/null || echo 0)

CURRENT=$(forgejo_get_issue "$FORGEJO_REPO" "$ISSUE_NUMBER")
ISSUE_STATE=$(jq -r .state <<<"$CURRENT")
HAS_BLOCKED=$(jq -r '[.labels[].name] | index("Status/Blocked") != null' <<<"$CURRENT")

if [ "$ISSUE_STATE" = "closed" ]; then
  log "outcome: report (issue closed by agent)"

elif [ "$HAS_BLOCKED" = "true" ]; then
  log "outcome: blocked (Status/Blocked applied by agent)"

elif [ "$COMMITS" -gt 0 ]; then
  log "outcome: PR ($COMMITS commit(s))"
  BRANCH="agent/${ISSUE_NUMBER}"
  git push -u origin "$BRANCH"

  PR_TITLE=$(git log -1 --pretty=%s)
  if [ -f .git/PR_BODY.md ]; then
    PR_BODY=$(cat .git/PR_BODY.md)
  else
    PR_BODY=$(git log "origin/${PR_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
  fi
  PR_BODY+=$'\n\nCloses #'"$ISSUE_NUMBER"

  forgejo_open_pr "$FORGEJO_REPO" "$BRANCH" "$PR_BASE" "$PR_TITLE" "$PR_BODY"
  log "PR opened"

else
  log "outcome: no work produced"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"
  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
    "Tick completed with no work produced and no blocker reported. Investigate. (claude exit: ${CLAUDE_EXIT})"
fi

# Cleanup runs via trap on exit.
exit 0
