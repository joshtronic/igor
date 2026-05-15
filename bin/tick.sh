#!/usr/bin/env bash
# tick.sh -- claim one Agent-labeled Forgejo issue from any known
# project and work it.
#
# Usage:
#   tick.sh             scan all projects, pick globally oldest claimable
#   tick.sh <project>   scope to one project (for debugging)
#
# Behavior:
#   1. Acquire global flock -- only one tick runs at a time.
#   2. Recovery -- any open issue assigned to $BOT_USER (orphaned from
#      a previous interrupted tick) gets a comment and is unassigned
#      so the next tick re-claims it.
#   3. Discovery -- query each project's Forgejo repo for the oldest
#      claimable issue (Agent-labeled, no assignee, not Status/Blocked).
#      Pick the globally oldest.
#   4. Claim, worktree, invoke Claude, classify outcome.
#
# Exits 0 on success or no-work-found. Non-zero on config/infra errors.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────

TICK_HOME="${TICK_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
TICK_STATE_DIR="${TICK_STATE_DIR:-$HOME/.local/state/tick}"
SCOPE_PROJECT="${1:-}"

# ── Secrets ────────────────────────────────────────────────────

if [ -f "$TICK_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$TICK_HOME/.env"
  set +a
fi
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN must be set (via $TICK_HOME/.env)}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set (via $TICK_HOME/.env)}"
: "${FORGEJO_URL:?FORGEJO_URL must be set (via $TICK_HOME/.env)}"
: "${BOT_USER:=agent}"

# ── Library ────────────────────────────────────────────────────

# shellcheck source=lib/forgejo.sh
. "$TICK_HOME/lib/forgejo.sh"

# ── Global lock (one tick at a time, across all projects) ─────

mkdir -p "$TICK_STATE_DIR"
LOCK="$TICK_STATE_DIR/lock"
exec 200>"$LOCK"
if ! flock -n 200; then
  echo "tick: another tick is running -- exiting" >&2
  exit 0
fi

log() { printf '[tick] %s\n' "$*"; }

# Title -> branch-safe slug. ASCII alphanumerics survive; everything
# else collapses to '-'. Capped at 50 chars, preferring to cut on a
# hyphen boundary. Empty for titles with no alphanumerics.
slugify() {
  local s
  s=$(printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  if [ ${#s} -gt 50 ]; then
    s="${s:0:50}"
    s="${s%-*}"
    s="${s%-}"
  fi
  printf '%s' "$s"
}

# Delete local agent branches for issue N: bare `agent/N` plus any
# `agent/N-<slug>` left over from a previous run (the title may have
# been edited since, so glob rather than match exactly).
cleanup_agent_branches() {
  local n="$1" repo="$2" refs
  refs=$(cd "$repo" && git for-each-ref --format='%(refname:short)' \
    "refs/heads/agent/${n}" "refs/heads/agent/${n}-*" 2>/dev/null) || return 0
  [ -z "$refs" ] && return 0
  (cd "$repo" && echo "$refs" | xargs git branch -D) >/dev/null 2>&1 || true
}

# ── Discover known projects ───────────────────────────────────

shopt -s nullglob
declare -a PROJECTS
if [ -n "$SCOPE_PROJECT" ]; then
  [ -f "$TICK_HOME/projects/${SCOPE_PROJECT}.conf" ] \
    || { echo "tick: no conf at $TICK_HOME/projects/${SCOPE_PROJECT}.conf" >&2; exit 2; }
  PROJECTS=("$SCOPE_PROJECT")
else
  for conf in "$TICK_HOME"/projects/*.conf; do
    PROJECTS+=("$(basename "$conf" .conf)")
  done
fi

if [ ${#PROJECTS[@]} -eq 0 ]; then
  log "no projects configured at $TICK_HOME/projects/"
  exit 0
fi

# ── Load a project's conf into P_* vars ───────────────────────
# Sets P_REPO_PATH, P_FORGEJO_REPO, P_PR_BASE, P_TICK_TIMEOUT.
# Returns 0 on success, 1 on missing required fields.

load_project_conf() {
  local project="$1"
  local conf="$TICK_HOME/projects/${project}.conf"
  [ -f "$conf" ] || return 1

  # Reset before sourcing
  REPO_PATH=""
  FORGEJO_REPO=""
  PR_BASE=""
  TICK_TIMEOUT=""

  # shellcheck source=/dev/null
  . "$conf"

  [ -n "$REPO_PATH" ]    || { echo "tick: $project missing REPO_PATH" >&2; return 1; }
  [ -n "$FORGEJO_REPO" ] || { echo "tick: $project missing FORGEJO_REPO" >&2; return 1; }

  P_REPO_PATH="$REPO_PATH"
  P_FORGEJO_REPO="$FORGEJO_REPO"
  P_PR_BASE="${PR_BASE:-master}"
  P_TICK_TIMEOUT="${TICK_TIMEOUT:-60m}"
  return 0
}

# ── Recovery: clear orphaned $BOT_USER assignments ────────────

log "recovery sweep ($BOT_USER across ${#PROJECTS[@]} project(s))"
for project in "${PROJECTS[@]}"; do
  load_project_conf "$project" || continue
  ORPHANS=$(forgejo_find_assigned "$P_FORGEJO_REPO" "$BOT_USER" || echo "[]")
  ORPHAN_COUNT=$(jq 'length' <<<"$ORPHANS")
  [ "$ORPHAN_COUNT" -gt 0 ] || continue

  while read -r n; do
    [ -z "$n" ] && continue
    log "recovery: ${project}#${n} orphaned, re-queueing"
    forgejo_comment "$P_FORGEJO_REPO" "$n" \
      "Previous tick was interrupted before completion. Re-queueing -- the next tick will pick this up."
    forgejo_unassign_all "$P_FORGEJO_REPO" "$n"

    # Best-effort cleanup of leftover worktree / branch.
    wt="$TICK_STATE_DIR/worktrees/${project}-${n}"
    if [ -d "$wt" ]; then
      (cd "$P_REPO_PATH" && git worktree remove "$wt" --force) 2>/dev/null || rm -rf "$wt"
    fi
    cleanup_agent_branches "$n" "$P_REPO_PATH"
  done < <(jq -r '.[].number' <<<"$ORPHANS")
done

# ── Discovery: find globally oldest claimable ─────────────────

WINNER=""
WINNER_PROJECT=""
WINNER_CREATED=""

for project in "${PROJECTS[@]}"; do
  load_project_conf "$project" || continue
  ISSUE=$(forgejo_find_claimable "$P_FORGEJO_REPO" || true)
  [ -n "$ISSUE" ] && [ "$ISSUE" != "null" ] && [ "$ISSUE" != "empty" ] || continue
  CREATED=$(jq -r '.created_at' <<<"$ISSUE")
  if [ -z "$WINNER" ] || [[ "$CREATED" < "$WINNER_CREATED" ]]; then
    WINNER="$ISSUE"
    WINNER_PROJECT="$project"
    WINNER_CREATED="$CREATED"
  fi
done

if [ -z "$WINNER" ]; then
  log "no claimable work across any project"
  exit 0
fi

# Reload the winner's conf to repopulate P_* canonically.
load_project_conf "$WINNER_PROJECT"
PROJECT="$WINNER_PROJECT"
REPO_PATH="$P_REPO_PATH"
FORGEJO_REPO="$P_FORGEJO_REPO"
PR_BASE="$P_PR_BASE"
TICK_TIMEOUT="$P_TICK_TIMEOUT"

ISSUE_NUMBER=$(jq -r .number <<<"$WINNER")
ISSUE_TITLE=$(jq -r .title <<<"$WINNER")
ISSUE_BODY=$(jq -r '.body // ""' <<<"$WINNER")
ISSUE_LABELS=$(jq -r '[.labels[].name] | join(", ")' <<<"$WINNER")

SLUG=$(slugify "$ISSUE_TITLE")
if [ -n "$SLUG" ]; then
  BRANCH="agent/${ISSUE_NUMBER}-${SLUG}"
else
  BRANCH="agent/${ISSUE_NUMBER}"
fi

log "claiming ${PROJECT}#${ISSUE_NUMBER}: ${ISSUE_TITLE}"
log "branch: ${BRANCH}"

# ── Cleanup on exit (set before worktree creation) ────────────

WORKTREE=""

cleanup() {
  local rc=$?
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    log "removing worktree $WORKTREE"
    (cd "$REPO_PATH" && git worktree remove "$WORKTREE" --force) 2>/dev/null || true
  fi
  if [ -n "${ISSUE_NUMBER:-}" ]; then
    cleanup_agent_branches "$ISSUE_NUMBER" "$REPO_PATH"
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── Claim ─────────────────────────────────────────────────────

forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER"

# ── Worktree ──────────────────────────────────────────────────

mkdir -p "$TICK_STATE_DIR/worktrees"
WORKTREE="$TICK_STATE_DIR/worktrees/${PROJECT}-${ISSUE_NUMBER}"

# Recovery should have cleared any stale path; this is a belt-and-braces check.
if [ -e "$WORKTREE" ]; then
  log "stale worktree at $WORKTREE -- aborting"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"
  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
    "Tick aborted: stale worktree from a previous run was present at \`$WORKTREE\`. Investigate and clear before retrying."
  exit 4
fi

cd "$REPO_PATH"
git fetch origin --prune
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${PR_BASE}"

# ── Invoke Claude ─────────────────────────────────────────────

cd "$WORKTREE"

# Helpers (agent-block.sh etc.) on PATH and aware of context.
export PATH="$TICK_HOME/bin:$PATH"
export ISSUE_NUMBER ISSUE_TITLE FORGEJO_REPO PR_BASE TICK_HOME

USER_MSG=$(cat <<EOF
You are working Forgejo issue #${ISSUE_NUMBER} in ${FORGEJO_REPO}.

Title: ${ISSUE_TITLE}
Labels: ${ISSUE_LABELS}

Body:
${ISSUE_BODY}
EOF
)

log "invoking claude (timeout ${TICK_TIMEOUT})"
CLAUDE_LOG="$WORKTREE/.git/claude-output.log"
set +e
timeout --kill-after=30s "$TICK_TIMEOUT" \
  claude \
    --append-system-prompt "$(cat "$TICK_HOME/AGENTS.md")" \
    --settings "$TICK_HOME/agent-settings.json" \
    --max-turns 50 \
    --print "$USER_MSG" 2>&1 | tee "$CLAUDE_LOG"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e
log "claude exited $CLAUDE_EXIT"

# ── Determine outcome ─────────────────────────────────────────

cd "$WORKTREE"
COMMITS=$(git rev-list --count "origin/${PR_BASE}..HEAD" 2>/dev/null || echo 0)

CURRENT=$(forgejo_get_issue "$FORGEJO_REPO" "$ISSUE_NUMBER")
ISSUE_STATE=$(jq -r .state <<<"$CURRENT")
HAS_BLOCKED=$(jq -r '[.labels[].name] | index("Status/Blocked") != null' <<<"$CURRENT")

if [ "$ISSUE_STATE" = "closed" ]; then
  # OUTCOME: report
  log "outcome: report (issue closed by agent)"

elif [ "$HAS_BLOCKED" = "true" ]; then
  # OUTCOME: blocked
  log "outcome: blocked (Status/Blocked applied by agent)"

elif [ "$COMMITS" -gt 0 ]; then
  # OUTCOME: pr
  log "outcome: PR ($COMMITS commit(s))"
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
  # OUTCOME: noop
  log "outcome: no work produced"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"

  TAIL="(no output captured)"
  [ -s "$CLAUDE_LOG" ] && TAIL=$(tail -c 4000 "$CLAUDE_LOG")

  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
"Tick completed with no work produced and no blocker reported. Investigate. (claude exit: ${CLAUDE_EXIT})

<details><summary>last bytes of claude output</summary>

\`\`\`
${TAIL}
\`\`\`
</details>"
fi

# Cleanup runs via trap on exit.
exit 0
