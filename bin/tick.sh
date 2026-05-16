#!/usr/bin/env bash
# tick.sh -- discover and work one Agent-labeled Forgejo issue across
# every repo the bot user has push access to. One invocation = one tick.
#
# Usage: tick.sh
#
# Behavior:
#   1. Acquire global flock -- only one Igor at a time.
#   2. Resolve bot identity from Forgejo (whoami).
#   3. Recovery -- any open issue still assigned to the bot from a
#      previous interrupted tick gets a comment and is unassigned so
#      the next tick re-claims it.
#   4. Discovery -- list every repo the bot has push access to, find
#      the globally oldest claimable issue across them.
#   5. Claim, clone-if-needed, preflight (CLAUDE.md present), worktree,
#      invoke Claude, classify outcome.
#
# Exits 0 on success or no-work-found. Non-zero on config/infra errors.

set -euo pipefail

# -- Paths ------------------------------------------------------

IGOR_HOME="${IGOR_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
IGOR_STATE_DIR="${IGOR_STATE_DIR:-$HOME/.local/state/igor}"
IGOR_REPO_ROOT="$IGOR_STATE_DIR/repos"

# -- Secrets ----------------------------------------------------

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set (via $IGOR_HOME/.env)}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set (via $IGOR_HOME/.env)}"
: "${FORGEJO_URL:?FORGEJO_URL must be set (via $IGOR_HOME/.env)}"
: "${IGOR_MODEL:?IGOR_MODEL must be set (via $IGOR_HOME/.env)}"
IGOR_TIMEOUT="${IGOR_TIMEOUT:-60m}"
FORGEJO_SSH_HOST="${FORGEJO_SSH_HOST:-$(echo "$FORGEJO_URL" | sed -E 's|^[a-z]+://([^/:]+).*|\1|')}"

# -- Library ----------------------------------------------------

# shellcheck source=lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"
# shellcheck source=lib/repo-checks.sh
. "$IGOR_HOME/lib/repo-checks.sh"

# -- Resolve bot identity --------------------------------------

BOT_USER=$(forgejo_whoami)
[ -n "$BOT_USER" ] || {
  echo "igor: failed to resolve bot user from $FORGEJO_URL/api/v1/user" >&2
  exit 3
}

# -- Global lock (one tick at a time) --------------------------

mkdir -p "$IGOR_STATE_DIR"
LOCK="$IGOR_STATE_DIR/lock"
exec 200>"$LOCK"
if ! flock -n 200; then
  echo "igor: another tick is running -- exiting" >&2
  exit 0
fi

log() { printf '[igor] %s\n' "$*"; }

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

# Local clone path: nests by owner under the harness state dir.
# Lives in state (not in ~/Code) because these are harness-managed
# working copies, distinct from any interactive clones the operator
# keeps in their own workspace.
repo_path_for() { echo "$IGOR_REPO_ROOT/$1"; }

# Idempotent clone-if-missing. Creates the owner subdir as needed.
ensure_repo_local() {
  local repo="$1" local_path
  local_path=$(repo_path_for "$repo")
  if [ ! -d "$local_path/.git" ]; then
    log "bootstrap: cloning $repo to $local_path"
    mkdir -p "$(dirname "$local_path")"
    git clone "git@${FORGEJO_SSH_HOST}:${repo}.git" "$local_path"
  fi
}

# -- Discretionary-work state (tier 2 cooldown) ----------------
#
# Tracks per-repo "last maintained" timestamps so we don't run
# maintenance on the same repo every empty tick. Lives at
# $IGOR_STATE_DIR/discretionary-state.json. Regenerable -- losing
# it just makes every repo eligible again.

discretionary_state_file() { echo "$IGOR_STATE_DIR/discretionary-state.json"; }

maintenance_last_run() {
  local repo="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r --arg r "$repo" '.maintenance[$r] // ""' "$state_file" 2>/dev/null || echo ""
}

maintenance_mark_done() {
  local repo="$1" state_file tmp ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg r "$repo" --arg t "$ts" \
    '.maintenance //= {} | .maintenance[$r] = $t' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Eligible if never run or last run >= random(5,7) days ago. Random
# rolls per check (not per-repo-persistent) so cadence drifts off
# clockwork patterns naturally.
maintenance_eligible() {
  local repo="$1" last cooldown_days last_epoch now age_days
  last=$(maintenance_last_run "$repo")
  [ -z "$last" ] && return 0
  cooldown_days=$(( 5 + RANDOM % 3 ))
  last_epoch=$(date -u -d "$last" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%s 2>/dev/null \
    || echo 0)
  now=$(date -u +%s)
  age_days=$(( (now - last_epoch) / 86400 ))
  [ "$age_days" -ge "$cooldown_days" ]
}

# Worktree key: slash-free, unique per repo+issue.
worktree_key() { printf '%s-%s' "${1//\//_}" "$2"; }

# Build a "Dependencies changed" section from the diff. Empty output
# when no manifest/lockfile files changed. Trust boundary: the harness
# writes this, not Claude -- a thing under review must not be able to
# omit its own audit trail.
build_deps_section() {
  local base="$1" pattern files f counts
  pattern='^(.*/)?(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile(\.lock)?|pyproject\.toml|poetry\.lock|uv\.lock|Cargo\.(toml|lock)|go\.(mod|sum)|Gemfile(\.lock)?|composer\.(json|lock))$'
  files=$(git diff --name-only "origin/${base}..HEAD" | grep -E "$pattern" || true)
  [ -z "$files" ] && return 0

  printf '\n\n## Dependencies changed\n\n'
  printf 'Manifest or lockfile changes detected. Review carefully -- transitive\n'
  printf 'dependencies in lockfiles are the largest supply-chain attack surface.\n\n'
  printf 'Files changed:\n'
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    counts=$(git diff --numstat "origin/${base}..HEAD" -- "$f" \
      | awk '{printf "+%s -%s", $1, $2}')
    printf -- '- `%s` (%s)\n' "$f" "$counts"
  done <<<"$files"
}

# -- Bootstrap: ensure Igor's own repos are cloned -------------
#
# Brain is hard-required: identity.md is foundational, every system
# prompt loads it. If the bot doesn't own a brain repo, halt loudly
# rather than running ticks with generic-Claude voice.
#
# Website is soft: warn if absent but proceed -- Igor can still work
# other repos. The website is just one of his target repos, not
# essential infrastructure.

if ! forgejo_repo_exists "${BOT_USER}/brain"; then
  echo "igor: bootstrap failed -- ${BOT_USER}/brain does not exist or bot lacks access" >&2
  echo "  create the repo (see docs/setup.md) and try again." >&2
  exit 4
fi
ensure_repo_local "${BOT_USER}/brain"

if forgejo_repo_exists "${BOT_USER}/website"; then
  ensure_repo_local "${BOT_USER}/website"
else
  log "warning: ${BOT_USER}/website does not exist -- website work disabled"
fi

# -- Recovery: clear orphaned bot assignments ------------------
#
# Invariant: we hold the global flock, so no other Igor is currently
# running. Any open issue assigned to the bot right now is, by
# definition, an orphan from a crashed previous tick.

log "recovery sweep ($BOT_USER)"
ORPHANS=$(forgejo_my_assigned || echo '[]')
ORPHAN_COUNT=$(jq 'length' <<<"$ORPHANS")

if [ "$ORPHAN_COUNT" -gt 0 ]; then
  while read -r line; do
    [ -z "$line" ] && continue
    O_REPO=$(jq -r '.repo' <<<"$line")
    O_NUM=$(jq -r '.num' <<<"$line")
    log "recovery: ${O_REPO}#${O_NUM} orphaned, re-queueing"
    forgejo_comment "$O_REPO" "$O_NUM" \
      "Previous tick was interrupted before completion. Re-queueing -- the next tick will pick this up."
    forgejo_unassign_all "$O_REPO" "$O_NUM"

    O_LOCAL=$(repo_path_for "$O_REPO")
    O_WT="$IGOR_STATE_DIR/worktrees/$(worktree_key "$O_REPO" "$O_NUM")"
    if [ -d "$O_LOCAL/.git" ]; then
      if [ -d "$O_WT" ]; then
        (cd "$O_LOCAL" && git worktree remove "$O_WT" --force) 2>/dev/null || rm -rf "$O_WT"
      fi
      cleanup_agent_branches "$O_NUM" "$O_LOCAL"
    fi
  done < <(jq -c '.[] | {repo: .repository.full_name, num: .number}' <<<"$ORPHANS")
fi

# -- Discovery: find globally oldest claimable -----------------

REPOS=$(forgejo_list_bot_repos)
REPO_COUNT=$(jq 'length' <<<"$REPOS")
log "scanning $REPO_COUNT repo(s) for claimable work"

WINNER=""
WINNER_REPO=""
WINNER_PR_BASE=""
WINNER_CREATED=""

while read -r repo_line; do
  [ -z "$repo_line" ] && continue
  R_NAME=$(jq -r '.full_name' <<<"$repo_line")
  R_BASE=$(jq -r '.default_branch' <<<"$repo_line")
  R_PATH=$(repo_path_for "$R_NAME")

  # Onboarding gate: for repos we haven't cloned yet, validate via API
  # before we look at any issues there. Failing repos get an auto-filed
  # ticket (or a reopen on the existing one) and are excluded from
  # discovery until the human closes the ticket.
  if [ ! -d "$R_PATH/.git" ]; then
    if ! R_REPORT=$(validate_repo_via_api "$R_NAME"); then
      log "onboarding check failed on $R_NAME"
      handle_onboarding_failure "$R_NAME" "$BOT_USER" "$R_REPORT"
      continue
    fi
    log "onboarding check passed on $R_NAME"
  fi

  # One open Igor PR per repo. Skip until the human deals with it.
  if forgejo_has_open_bot_pr "$R_NAME" "$BOT_USER"; then
    log "skipping $R_NAME -- open Igor PR present"
    continue
  fi

  ISSUE=$(forgejo_find_claimable "$R_NAME" || true)
  [ -n "$ISSUE" ] && [ "$ISSUE" != "null" ] && [ "$ISSUE" != "empty" ] || continue
  CREATED=$(jq -r '.created_at' <<<"$ISSUE")
  if [ -z "$WINNER" ] || [[ "$CREATED" < "$WINNER_CREATED" ]]; then
    WINNER="$ISSUE"
    WINNER_REPO="$R_NAME"
    WINNER_PR_BASE="$R_BASE"
    WINNER_CREATED="$CREATED"
  fi
done < <(jq -c '.[]' <<<"$REPOS")

if [ -z "$WINNER" ]; then
  log "no claimable work across any repo"

  # -- Tier 2: discretionary maintenance pass ------------------
  #
  # When nothing's claimable, optionally fire one maintenance pass
  # on a random eligible repo. Three throttles:
  #
  #   (1) IGOR_DISCRETIONARY_RATE -- probability we even consider
  #       maintenance this tick. Default 0 (off). Range 0.0-1.0.
  #   (2) IGOR_MAX_OPEN_PRS -- if the bot already has this many open
  #       PRs across all repos, don't add more findings to the queue.
  #   (3) per-repo cooldown -- 5-7 days random since last pass.
  #
  # Findings flow same as journal: Claude writes
  # .git/IGOR_MAINTENANCE_FINDINGS.md, harness reads it and files an
  # Agent-labeled issue for follow-up work.

  DISCRETIONARY_RATE="${IGOR_DISCRETIONARY_RATE:-0}"
  MAX_OPEN_PRS="${IGOR_MAX_OPEN_PRS:-3}"

  RATE_X1000=$(awk "BEGIN { printf \"%d\", $DISCRETIONARY_RATE * 1000 }")
  ROLL=$(( RANDOM % 1000 ))

  if [ "$ROLL" -ge "$RATE_X1000" ]; then
    log "discretionary: dice $ROLL/1000 vs rate $RATE_X1000 -- skip"
    exit 0
  fi

  OPEN_PRS=$(forgejo_count_bot_open_prs 2>/dev/null || echo 0)
  if [ "$OPEN_PRS" -ge "$MAX_OPEN_PRS" ]; then
    log "discretionary: $OPEN_PRS open PRs (cap $MAX_OPEN_PRS) -- holding off"
    exit 0
  fi

  ELIGIBLE=()
  while read -r repo_line; do
    [ -z "$repo_line" ] && continue
    R_NAME=$(jq -r '.full_name' <<<"$repo_line")
    if maintenance_eligible "$R_NAME"; then
      ELIGIBLE+=("$R_NAME")
    fi
  done < <(jq -c '.[]' <<<"$REPOS")

  if [ "${#ELIGIBLE[@]}" -eq 0 ]; then
    # -- Tier 3: self-directed website work (fallback) ---------
    #
    # No claimable tickets, no maintenance due. If the bot owns a
    # website and has no open PR on it, do one freeform pass:
    # Claude reads the website's CLAUDE.md, picks one focused
    # improvement (post, design, copy, layout), and opens a PR.
    # No source issue means no Closes #N footer.

    W_REPO="${BOT_USER}/website"
    W_PATH=$(repo_path_for "$W_REPO")

    if [ ! -d "$W_PATH/.git" ]; then
      log "discretionary: no website cloned -- nothing to do"
      exit 0
    fi

    if forgejo_has_open_bot_pr "$W_REPO" "$BOT_USER"; then
      log "discretionary: website has open Igor PR -- holding off"
      exit 0
    fi

    log "discretionary: self-directed work on $W_REPO"

    W_BASE=$(cd "$W_PATH" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    W_BASE="${W_BASE:-master}"
    W_TS=$(date -u +%Y%m%d-%H%M%S)
    W_BRANCH="agent/discretionary-${W_TS}"
    W_WORKTREE="$IGOR_STATE_DIR/worktrees/website-discretionary-${W_TS}"
    mkdir -p "$IGOR_STATE_DIR/worktrees"
    (cd "$W_PATH" && git fetch --prune origin)
    (cd "$W_PATH" && git worktree add -b "$W_BRANCH" "$W_WORKTREE" "origin/${W_BASE}")

    W_CLEANUP() {
      [ -d "$W_WORKTREE" ] && (cd "$W_PATH" && git worktree remove --force "$W_WORKTREE") 2>/dev/null || true
      cleanup_agent_branches "discretionary-${W_TS}" "$W_PATH"
    }
    trap W_CLEANUP EXIT

    cd "$W_WORKTREE"

    W_USER_MSG=$(cat <<EOF
You are doing self-directed work on $W_REPO. No issue is assigned;
no human is waiting on a specific thing.

Read CLAUDE.md, especially the "Posts" and "Site shape" sections.
Look at what's there: src/index.md (homepage), src/about.md (about),
src/posts.njk (posts index template), src/posts/ (existing posts
if any), src/_includes/base.njk (layout).

Pick ONE focused improvement. Examples:

  - Write a new blog post (your choice of topic)
  - Improve the About page
  - Improve the homepage copy
  - Refine the layout, nav, or any CSS
  - Fix typos, broken links, stale content
  - Add a tag page if posts are tagged enough to warrant it

ONE thing. Under scope cap (400 lines / 10 commits).

This is the fever-dream venue -- personality welcome. See
identity.md's Voice section for the register layering.

Make the change on the agent branch. Write .git/PR_BODY.md with
the two-checklist format from AGENTS.md (What this PR does + Test
plan). Run npm test before exit -- must pass.

If nothing feels right after looking around, write IGOR_JOURNAL.md
with a brief note about what didn't click and exit without
commits. Empty ticks are fine.
EOF
)

    BRAIN_PATH="$IGOR_REPO_ROOT/${BOT_USER}/brain"
    if [ -f "$BRAIN_PATH/identity.md" ] && [ -f "$BRAIN_PATH/index.md" ]; then
      W_SYSTEM_PROMPT=$(cat "$BRAIN_PATH/identity.md" "$BRAIN_PATH/index.md" "$IGOR_HOME/AGENTS.md")
    else
      W_SYSTEM_PROMPT=$(cat "$IGOR_HOME/AGENTS.md")
    fi

    log "invoking claude for website work (timeout ${IGOR_TIMEOUT})"
    W_LOG="$W_WORKTREE/.git/claude-output.log"
    W_START=$(date +%s)
    set +e
    timeout --kill-after=30s "$IGOR_TIMEOUT" \
      claude \
        --model "$IGOR_MODEL" \
        --append-system-prompt "$W_SYSTEM_PROMPT" \
        --settings "$IGOR_HOME/agent-settings.json" \
        --max-turns 50 \
        --print "$W_USER_MSG" 2>&1 | tee "$W_LOG"
    W_EXIT=${PIPESTATUS[0]}
    set -e
    log "claude exited $W_EXIT after $(( $(date +%s) - W_START ))s"

    # Journal write
    W_JOURNAL_SRC="$W_WORKTREE/.git/IGOR_JOURNAL.md"
    if [ -s "$W_JOURNAL_SRC" ]; then
      W_JDATE=$(date -u +%Y-%m-%d)
      W_JFILE="$BRAIN_PATH/journal/${W_JDATE}.md"
      W_JTS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      log "journal: appending discretionary website tick"
      mkdir -p "$BRAIN_PATH/journal"
      (cd "$BRAIN_PATH" && git pull --rebase --quiet origin master 2>/dev/null) \
        || log "warning: brain pull failed"
      {
        printf '\n## %s -- discretionary on %s\n\n' "$W_JTS" "$W_REPO"
        cat "$W_JOURNAL_SRC"
      } >> "$W_JFILE"
      (cd "$BRAIN_PATH" \
        && git add "journal/${W_JDATE}.md" \
        && git commit --quiet -m "journal: discretionary on $W_REPO" \
        && git push --quiet origin master) \
        || log "warning: brain commit/push failed"
    fi

    # Outcome classification
    cd "$W_WORKTREE"
    W_COMMITS=$(git rev-list --count "origin/${W_BASE}..HEAD" 2>/dev/null || echo 0)

    if [ "$W_COMMITS" -eq 0 ]; then
      log "discretionary: no work produced on $W_REPO"
      exit 0
    fi

    W_ACTUAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$W_ACTUAL_BRANCH" != "$W_BRANCH" ]; then
      log "discretionary: HEAD on $W_ACTUAL_BRANCH, expected $W_BRANCH -- abandoning"
      exit 0
    fi

    W_CHANGED=$(git diff --shortstat "origin/${W_BASE}..HEAD" 2>/dev/null \
      | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
    W_CHANGED=${W_CHANGED:-0}
    if [ "$W_COMMITS" -gt 10 ] || [ "$W_CHANGED" -gt 400 ]; then
      log "discretionary: scope exceeded ($W_COMMITS commits, $W_CHANGED lines) -- abandoning"
      exit 0
    fi

    if grep -qiE 'tests:[[:space:]]+0[[:space:]]+(passed|failed|of|total)|no tests (ran|found|collected)|collected 0 items|(^|[^0-9])0 passing([^0-9]|$)|running 0 tests|ran 0 tests' "$W_LOG"; then
      log "discretionary: vacuous tests -- abandoning"
      exit 0
    fi

    log "discretionary: pushing $W_BRANCH and opening PR on $W_REPO"
    git push --force-with-lease -u origin "$W_BRANCH"

    W_EXISTING_PR=$(forgejo_find_pr_by_head "$W_REPO" "$W_BRANCH")
    if [ -n "$W_EXISTING_PR" ]; then
      log "PR #$W_EXISTING_PR already open"
    else
      W_PR_TITLE=$(git log -1 --pretty=%s)
      if [ -f .git/PR_BODY.md ]; then
        W_PR_BODY=$(cat .git/PR_BODY.md)
      else
        W_PR_BODY=$(git log "origin/${W_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
      fi
      W_PR_BODY+=$(build_deps_section "$W_BASE")
      forgejo_open_pr "$W_REPO" "$W_BRANCH" "$W_BASE" "$W_PR_TITLE" "$W_PR_BODY"
      log "discretionary: PR opened on $W_REPO"
    fi

    exit 0
  fi

  TARGET="${ELIGIBLE[RANDOM % ${#ELIGIBLE[@]}]}"
  log "discretionary: maintenance pass on $TARGET"

  ensure_repo_local "$TARGET"
  TARGET_PATH=$(repo_path_for "$TARGET")

  # Detached-HEAD worktree on the repo's current default branch.
  # No feature branch -- maintenance doesn't commit; it writes
  # findings to a known path that the harness reads after exit.
  TARGET_BASE=$(cd "$TARGET_PATH" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  TARGET_BASE="${TARGET_BASE:-master}"
  M_WORKTREE="$IGOR_STATE_DIR/worktrees/maintenance-${TARGET//\//_}-$$"
  mkdir -p "$IGOR_STATE_DIR/worktrees"
  (cd "$TARGET_PATH" && git fetch --prune origin)
  (cd "$TARGET_PATH" && git worktree add --detach "$M_WORKTREE" "origin/${TARGET_BASE}")

  M_CLEANUP() {
    [ -d "$M_WORKTREE" ] && (cd "$TARGET_PATH" && git worktree remove --force "$M_WORKTREE") 2>/dev/null || true
  }
  trap M_CLEANUP EXIT

  cd "$M_WORKTREE"

  M_USER_MSG=$(cat <<EOF
You are doing a discretionary maintenance pass on $TARGET.

No human is waiting on you. Your job:

  1. Read this repo's CLAUDE.md. Look for a "Maintenance" section
     declaring routine checks (security audit, dependency freshness,
     link checks, SEO scan, anything the repo defines).
  2. Run those checks.
  3. If anything notable surfaces -- vulnerabilities, outdated deps,
     broken links, regressions -- write a markdown summary to
     .git/IGOR_MAINTENANCE_FINDINGS.md in this worktree. The harness
     will file an Agent-labeled issue with that content as the body
     so tier-1 work picks it up on a future tick.
  4. If nothing notable, skip the findings file and exit cleanly.

Don't commit fixes during a maintenance pass -- file an issue and
let normal work flow address them on a future tick. Same content
rules as always: identity guardrails apply.
EOF
)

  BRAIN_PATH="$IGOR_REPO_ROOT/${BOT_USER}/brain"
  if [ -f "$BRAIN_PATH/identity.md" ] && [ -f "$BRAIN_PATH/index.md" ]; then
    M_SYSTEM_PROMPT=$(cat "$BRAIN_PATH/identity.md" "$BRAIN_PATH/index.md" "$IGOR_HOME/AGENTS.md")
  else
    M_SYSTEM_PROMPT=$(cat "$IGOR_HOME/AGENTS.md")
  fi

  log "invoking claude for maintenance (timeout ${IGOR_TIMEOUT})"
  M_LOG="$M_WORKTREE/.git/claude-output.log"
  M_START=$(date +%s)
  set +e
  timeout --kill-after=30s "$IGOR_TIMEOUT" \
    claude \
      --model "$IGOR_MODEL" \
      --append-system-prompt "$M_SYSTEM_PROMPT" \
      --settings "$IGOR_HOME/agent-settings.json" \
      --max-turns 50 \
      --print "$M_USER_MSG" 2>&1 | tee "$M_LOG"
  M_EXIT=${PIPESTATUS[0]}
  set -e
  log "claude exited $M_EXIT after $(( $(date +%s) - M_START ))s"

  FINDINGS="$M_WORKTREE/.git/IGOR_MAINTENANCE_FINDINGS.md"
  if [ -s "$FINDINGS" ]; then
    M_TITLE="Maintenance pass $(date -u +%Y-%m-%d): findings"
    M_BODY=$(cat "$FINDINGS")
    M_NUM=$(forgejo_open_issue "$TARGET" "$M_TITLE" "$M_BODY")
    forgejo_add_label "$TARGET" "$M_NUM" "Agent" 2>/dev/null \
      || log "warning: could not apply Agent label to #$M_NUM on $TARGET"
    log "maintenance: filed #$M_NUM on $TARGET"
  else
    log "maintenance: no findings on $TARGET"
  fi

  maintenance_mark_done "$TARGET"
  exit 0
fi

FORGEJO_REPO="$WINNER_REPO"
PR_BASE="$WINNER_PR_BASE"
REPO_PATH=$(repo_path_for "$FORGEJO_REPO")

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

log "claiming ${FORGEJO_REPO}#${ISSUE_NUMBER}: ${ISSUE_TITLE}"
log "branch: ${BRANCH}"

# Export early so agent-block.sh / agent-report.sh work for both
# preflight (called by tick.sh) and Claude (invoked below).
export ISSUE_NUMBER ISSUE_TITLE FORGEJO_REPO PR_BASE IGOR_HOME
export PATH="$IGOR_HOME/bin:$PATH"

# -- Cleanup on exit (set before worktree creation) ------------

WORKTREE=""

cleanup() {
  local rc=$?
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    log "removing worktree $WORKTREE"
    (cd "$REPO_PATH" && git worktree remove "$WORKTREE" --force) 2>/dev/null || true
  fi
  if [ -n "${ISSUE_NUMBER:-}" ] && [ -d "$REPO_PATH/.git" ]; then
    cleanup_agent_branches "$ISSUE_NUMBER" "$REPO_PATH"
  fi
  exit "$rc"
}
trap cleanup EXIT

# -- Claim -----------------------------------------------------

forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER"

# -- Clone if needed -------------------------------------------

if [ ! -d "$REPO_PATH/.git" ]; then
  CLONE_URL="git@${FORGEJO_SSH_HOST}:${FORGEJO_REPO}.git"
  log "cloning $CLONE_URL -> $REPO_PATH"
  mkdir -p "$(dirname "$REPO_PATH")"
  if ! git clone "$CLONE_URL" "$REPO_PATH"; then
    log "clone failed, blocking"
    agent-block.sh "Igor could not clone \`$CLONE_URL\`. Verify the bot user has SSH access to this repo and try again."
    exit 0
  fi
fi

# -- Preflight -------------------------------------------------

if [ ! -f "$REPO_PATH/CLAUDE.md" ]; then
  log "preflight: missing CLAUDE.md, blocking"
  agent-block.sh "Igor cannot work this repo: \`CLAUDE.md\` is missing at the repo root.

Igor relies on \`CLAUDE.md\` for project conventions (test commands, code style, gotchas). Add one, remove \`Status/Blocked\`, and the next tick will re-claim this issue."
  exit 0
fi

# -- Worktree --------------------------------------------------

mkdir -p "$IGOR_STATE_DIR/worktrees"
WORKTREE="$IGOR_STATE_DIR/worktrees/$(worktree_key "$FORGEJO_REPO" "$ISSUE_NUMBER")"

# Recovery should have cleared any stale path; this is a belt-and-braces check.
if [ -e "$WORKTREE" ]; then
  log "stale worktree at $WORKTREE -- aborting"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"
  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
    "Igor aborted: stale worktree from a previous run was present at \`$WORKTREE\`. Investigate and clear before retrying."
  WORKTREE=""
  exit 4
fi

cd "$REPO_PATH"
git fetch origin --prune
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${PR_BASE}"

# -- Invoke Claude ---------------------------------------------

cd "$WORKTREE"

USER_MSG=$(cat <<EOF
You are working Forgejo issue #${ISSUE_NUMBER} in ${FORGEJO_REPO}.

Title: ${ISSUE_TITLE}
Labels: ${ISSUE_LABELS}

Body:
${ISSUE_BODY}
EOF
)

# System prompt: identity + index from brain (most stable first, for
# prompt caching), then AGENTS.md. Brain files are bootstrap-required,
# but guard with -f in case identity.md or index.md was deleted in
# place -- degrade to AGENTS.md only rather than crashing the tick.
BRAIN_PATH="$IGOR_REPO_ROOT/${BOT_USER}/brain"
if [ -f "$BRAIN_PATH/identity.md" ] && [ -f "$BRAIN_PATH/index.md" ]; then
  SYSTEM_PROMPT=$(cat "$BRAIN_PATH/identity.md" "$BRAIN_PATH/index.md" "$IGOR_HOME/AGENTS.md")
else
  log "warning: brain identity.md or index.md missing at $BRAIN_PATH -- using AGENTS.md only"
  SYSTEM_PROMPT=$(cat "$IGOR_HOME/AGENTS.md")
fi

log "invoking claude (timeout ${IGOR_TIMEOUT})"
CLAUDE_LOG="$WORKTREE/.git/claude-output.log"
START_TS=$(date +%s)
set +e
timeout --kill-after=30s "$IGOR_TIMEOUT" \
  claude \
    --model "$IGOR_MODEL" \
    --append-system-prompt "$SYSTEM_PROMPT" \
    --settings "$IGOR_HOME/agent-settings.json" \
    --max-turns 50 \
    --print "$USER_MSG" 2>&1 | tee "$CLAUDE_LOG"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e
ELAPSED=$(( $(date +%s) - START_TS ))
log "claude exited $CLAUDE_EXIT (elapsed ${ELAPSED}s)"

# -- Brain journal: append Claude's reflection if present ------
#
# Claude optionally writes .git/IGOR_JOURNAL.md before exit. The
# harness owns the brain commit -- Claude's worktree never reaches
# across to brain. Best-effort: if pull/push fails, log it but
# don't fail the tick over a journal entry.

JOURNAL_SRC="$WORKTREE/.git/IGOR_JOURNAL.md"
if [ -s "$JOURNAL_SRC" ]; then
  BRAIN_LOCAL="$IGOR_REPO_ROOT/${BOT_USER}/brain"
  JOURNAL_DATE=$(date -u +%Y-%m-%d)
  JOURNAL_FILE="$BRAIN_LOCAL/journal/${JOURNAL_DATE}.md"
  JOURNAL_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "journal: appending tick reflection to brain/journal/${JOURNAL_DATE}.md"
  mkdir -p "$BRAIN_LOCAL/journal"

  (cd "$BRAIN_LOCAL" && git pull --rebase --quiet origin master 2>/dev/null) \
    || log "warning: brain pull failed; appending to local copy anyway"

  {
    printf '\n## %s -- %s#%s\n\n' "$JOURNAL_TS" "$FORGEJO_REPO" "$ISSUE_NUMBER"
    cat "$JOURNAL_SRC"
  } >> "$JOURNAL_FILE"

  (cd "$BRAIN_LOCAL" \
    && git add "journal/${JOURNAL_DATE}.md" \
    && git commit --quiet -m "journal: ${FORGEJO_REPO}#${ISSUE_NUMBER}" \
    && git push --quiet origin master) \
    || log "warning: brain commit/push failed; entry may be local-only"
fi

# -- Determine outcome -----------------------------------------

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
  # HEAD-equals-branch sanity check. AGENTS.md tells Claude to stay on
  # the agent branch, but trust-but-verify before we touch the remote.
  ACTUAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
    # OUTCOME: blocked
    log "outcome: blocked (HEAD on $ACTUAL_BRANCH, expected $BRANCH)"
    agent-block.sh "Igor refused to push: HEAD ended up on \`$ACTUAL_BRANCH\` instead of \`$BRANCH\`. Something went sideways during the work -- investigate before re-queueing."
    exit 0
  fi

  # Scope cap. Big diffs and long commit chains get blocked instead of
  # shipped; the human splits the work into smaller issues.
  CHANGED=$(git diff --shortstat "origin/${PR_BASE}..HEAD" 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
  CHANGED=${CHANGED:-0}
  if [ "$COMMITS" -gt 10 ] || [ "$CHANGED" -gt 400 ]; then
    # OUTCOME: blocked
    log "outcome: blocked (scope: $COMMITS commits, $CHANGED lines)"
    FILES=$(git diff --name-only "origin/${PR_BASE}..HEAD" | head -30 | sed 's/^/  - /')
    agent-block.sh "Scope exceeded: this branch reached **${COMMITS} commits / ${CHANGED} changed lines**, over the per-issue cap (10 commits / 400 lines).

Files touched (first 30):
${FILES}

Split this into smaller issues, then remove \`Status/Blocked\` and the next tick will re-claim what's left."
    exit 0
  fi

  # Vacuous-test heuristic. Catches the dumbest false positive: test
  # commands that exit 0 with zero tests run (jest --passWithNoTests,
  # pytest with no collected items, etc). Not a complete check -- still
  # relies on the project's test command being meaningful.
  if grep -qiE 'tests:[[:space:]]+0[[:space:]]+(passed|failed|of|total)|no tests (ran|found|collected)|collected 0 items|(^|[^0-9])0 passing([^0-9]|$)|running 0 tests|ran 0 tests' "$CLAUDE_LOG"; then
    # OUTCOME: blocked
    log "outcome: blocked (vacuous tests: 0 tests reported)"
    agent-block.sh "Tests ran but reported zero tests executed. Definition of done failed: the test suite must run at least one assertion. Either this repo's \`CLAUDE.md\` declares a meaningless test command, or the change skipped the relevant suite. Fix and remove \`Status/Blocked\` to re-queue."
    exit 0
  fi

  # OUTCOME: pr
  log "outcome: PR ($COMMITS commit(s), $CHANGED line(s))"

  # Idempotent push: --force-with-lease covers the crash-then-retry
  # case where a prior tick pushed but died before opening a PR. We
  # only overwrite the remote ref we last fetched; if anyone else has
  # touched it (human, another host), the push fails loud.
  git push --force-with-lease -u origin "$BRANCH"

  # Idempotent PR open: skip if one already exists for this branch.
  EXISTING_PR=$(forgejo_find_pr_by_head "$FORGEJO_REPO" "$BRANCH")
  if [ -n "$EXISTING_PR" ]; then
    log "PR #$EXISTING_PR already open for $BRANCH -- skipping open"
  else
    PR_TITLE=$(git log -1 --pretty=%s)
    if [ -f .git/PR_BODY.md ]; then
      PR_BODY=$(cat .git/PR_BODY.md)
    else
      PR_BODY=$(git log "origin/${PR_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
    fi
    PR_BODY+=$(build_deps_section "$PR_BASE")
    PR_BODY+=$'\n\nCloses #'"$ISSUE_NUMBER"

    forgejo_open_pr "$FORGEJO_REPO" "$BRANCH" "$PR_BASE" "$PR_TITLE" "$PR_BODY"
    log "PR opened"
  fi

else
  # Noop-loop guard. If the bot already left a "no work produced"
  # comment on this issue, this is the second attempt -- block rather
  # than burn another tick on it.
  NOOP_PREFIX="Igor completed with no work produced"
  PRIOR_NOOPS=$(forgejo_count_bot_comments_matching \
    "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER" "$NOOP_PREFIX")
  if [ "${PRIOR_NOOPS:-0}" -ge 1 ]; then
    # OUTCOME: blocked
    log "outcome: blocked (repeated noop, prior count: $PRIOR_NOOPS)"
    agent-block.sh "Igor produced no work on this issue twice. The issue is probably unclear, requires context Claude can't reach, or has a setup problem. Investigate, then remove \`Status/Blocked\` to re-queue."
    exit 0
  fi

  # OUTCOME: noop
  log "outcome: no work produced (elapsed ${ELAPSED}s)"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"

  TAIL="(no output captured)"
  [ -s "$CLAUDE_LOG" ] && TAIL=$(tail -c 4000 "$CLAUDE_LOG")

  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
"${NOOP_PREFIX} and no blocker reported. Investigate. (claude exit: ${CLAUDE_EXIT}, elapsed ${ELAPSED}s)

<details><summary>last bytes of claude output</summary>

\`\`\`
${TAIL}
\`\`\`
</details>"
fi

# Cleanup runs via trap on exit.
exit 0
