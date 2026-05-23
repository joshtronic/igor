#!/usr/bin/env bash
# doctor.sh -- runtime health check for a live the agent install.
#
# Read-only. Reports on the current state of the system in one
# screen so the operator can spot anomalies without spelunking
# through journalctl, the state dir, and Forgejo manually.
#
# Run on the server (or anywhere with AGENT_HOME + .env):
#   bin/doctor.sh
#
# Sections:
#   - Environment / config
#   - Forgejo connectivity + bot identity
#   - Brain + website clone freshness
#   - State files (cooldowns, last runs)
#   - Worktrees on disk
#   - Stale local agent branches
#   - Open PRs across bot repos
#   - Recent tick outcomes (last 20 from journalctl, if available)
#
# No mutations. Safe to run anytime.

set -uo pipefail  # NOT -e: don't bail on first failing check

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
AGENT_REPO_ROOT="$AGENT_STATE_DIR/repos"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

# shellcheck source=lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh" 2>/dev/null || {
  echo "doctor: cannot source lib/forgejo.sh from $AGENT_HOME/lib/" >&2
  exit 1
}

# ----- helpers --------------------------------------------------

section() { printf '\n=== %s ===\n' "$*"; }
ok()      { printf '  [ok]   %s\n' "$*"; }
warn()    { printf '  [warn] %s\n' "$*"; }
bad()     { printf '  [bad]  %s\n' "$*"; }
info()    { printf '         %s\n' "$*"; }

# ----- environment ----------------------------------------------

section "Environment"
info "AGENT_HOME=$AGENT_HOME"
info "AGENT_STATE_DIR=$AGENT_STATE_DIR"
[ -n "${ANTHROPIC_API_KEY:-}" ] && ok "ANTHROPIC_API_KEY set" || bad "ANTHROPIC_API_KEY missing"
[ -n "${FORGEJO_URL:-}" ]       && ok "FORGEJO_URL=$FORGEJO_URL" || bad "FORGEJO_URL missing"
[ -n "${FORGEJO_TOKEN:-}" ]     && ok "FORGEJO_TOKEN set"  || bad "FORGEJO_TOKEN missing"
[ -n "${AGENT_MODEL:-}" ]        && ok "AGENT_MODEL=$AGENT_MODEL" || bad "AGENT_MODEL missing"
info "AGENT_DISCRETIONARY_RATE=${AGENT_DISCRETIONARY_RATE:-(unset, default 0)}"
info "FORGEJO_REVIEWER=${FORGEJO_REVIEWER:-(unset)}"
info "AGENT_SHIFT_START=${AGENT_SHIFT_START:-(unset)}  AGENT_SHIFT_END=${AGENT_SHIFT_END:-(unset)}"

# ----- Forgejo connectivity + bot identity ----------------------

section "Forgejo connectivity"
if BOT=$(forgejo_whoami 2>/dev/null) && [ -n "$BOT" ]; then
  ok "bot identity: $BOT"
  BOT_USER="$BOT"
else
  bad "could not resolve bot identity (API token? Forgejo reachable?)"
  BOT_USER=""
fi

# ----- Clones ---------------------------------------------------

section "Local clones"
for repo in brain website; do
  CLONE="$AGENT_REPO_ROOT/${BOT_USER}/$repo"
  if [ -d "$CLONE/.git" ]; then
    AHEAD=$(cd "$CLONE" && git rev-list --count HEAD..@{u} 2>/dev/null || echo "?")
    BEHIND=$(cd "$CLONE" && git rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
    LAST=$(cd "$CLONE" && git log -1 --pretty=format:'%h %s (%cr)' 2>/dev/null)
    ok "$repo: $LAST"
    [ "$AHEAD" != "0" ] && [ "$AHEAD" != "?" ] && warn "  behind remote by $AHEAD commit(s) -- pull pending"
    [ "$BEHIND" != "0" ] && [ "$BEHIND" != "?" ] && warn "  ahead of remote by $BEHIND commit(s) -- uncommitted push?"
  else
    warn "$repo: not cloned at $CLONE"
  fi
done

# ----- State files ----------------------------------------------

section "State files"
STATE_FILE="$AGENT_STATE_DIR/discretionary-state.json"
if [ -f "$STATE_FILE" ]; then
  ok "discretionary-state.json present"
  if command -v jq >/dev/null 2>&1; then
    POST_DAY=$(jq -r '.tier3.website_last_day // "(never)"' "$STATE_FILE" 2>/dev/null)
    info "  last post day: $POST_DAY"
    MAINT_COUNT=$(jq -r '.maintenance // {} | length' "$STATE_FILE" 2>/dev/null)
    info "  maintenance entries: $MAINT_COUNT"
  fi
else
  info "discretionary-state.json not yet created"
fi

LOCK_FILE="$AGENT_STATE_DIR/lock"
if [ -e "$LOCK_FILE" ]; then
  if command -v fuser >/dev/null 2>&1; then
    if fuser "$LOCK_FILE" >/dev/null 2>&1; then
      warn "lock file held -- a tick may be running right now"
    else
      ok "lock file present, not held"
    fi
  else
    info "lock file present (cannot check holders without fuser)"
  fi
fi

# ----- Worktrees ------------------------------------------------

section "Worktrees on disk"
WT_DIR="$AGENT_STATE_DIR/worktrees"
if [ -d "$WT_DIR" ]; then
  WT_COUNT=$(find "$WT_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  if [ "$WT_COUNT" -eq 0 ]; then
    ok "no worktrees on disk"
  else
    warn "$WT_COUNT worktree(s) on disk -- check for orphans if no tick running:"
    find "$WT_DIR" -maxdepth 1 -mindepth 1 -type d -printf '  %f (%TY-%Tm-%Td %TH:%TM)\n' 2>/dev/null \
      || find "$WT_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;
  fi
else
  info "no worktrees dir yet"
fi

# ----- Stale local agent branches -------------------------------

section "Local agent branches per clone"
for repo_path in $(find "$AGENT_REPO_ROOT" -maxdepth 2 -mindepth 2 -type d 2>/dev/null); do
  BRANCHES=$(cd "$repo_path" && git for-each-ref --format='%(refname:short)' 'refs/heads/agent/*' 2>/dev/null)
  if [ -n "$BRANCHES" ]; then
    COUNT=$(echo "$BRANCHES" | wc -l | tr -d ' ')
    warn "$(basename "$(dirname "$repo_path")")/$(basename "$repo_path"): $COUNT local agent branch(es)"
    echo "$BRANCHES" | sed 's/^/    /'
  fi
done

# ----- Open PRs across bot repos --------------------------------

section "Open bot PRs across all bot-accessible repos"
if [ -n "$BOT_USER" ]; then
  REPOS=$(forgejo_list_bot_repos 2>/dev/null || echo '[]')
  TOTAL_OPEN=0
  while read -r r; do
    [ -z "$r" ] && continue
    REPO_FULL=$(jq -r '.full_name' <<<"$r")
    if command -v forgejo_list_open_bot_prs >/dev/null 2>&1; then
      OPEN=$(forgejo_list_open_bot_prs "$REPO_FULL" "$BOT_USER" 2>/dev/null \
        | jq 'length' 2>/dev/null || echo 0)
    else
      # fallback: raw API
      OPEN=$(_fj GET "/repos/${REPO_FULL}/pulls?state=open&limit=50" 2>/dev/null \
        | jq --arg u "$BOT_USER" '[.[] | select(.user.login == $u)] | length' 2>/dev/null || echo 0)
    fi
    if [ "$OPEN" -gt 0 ]; then
      warn "$REPO_FULL: $OPEN open bot PR(s)"
      TOTAL_OPEN=$((TOTAL_OPEN + OPEN))
    fi
  done < <(jq -c '.[]' <<<"$REPOS" 2>/dev/null)
  [ "$TOTAL_OPEN" -eq 0 ] && ok "no open bot PRs"
else
  warn "skipped (no BOT_USER)"
fi

# ----- Recent tick outcomes (journalctl, if available) ----------

section "Recent tick outcomes (last 20)"
if command -v journalctl >/dev/null 2>&1; then
  # User service typical install; fall back to system if needed
  LOG=$(journalctl --user -u tick.service --since "24 hours ago" --no-pager 2>/dev/null | tail -200)
  if [ -z "$LOG" ]; then
    LOG=$(journalctl -u tick.service --since "24 hours ago" --no-pager 2>/dev/null | tail -200)
  fi
  if [ -n "$LOG" ]; then
    echo "$LOG" | grep -E "outcome:|discretionary:|scheduled:|PR-review:|harness-commit:|abandoning|FAIL" | tail -20 | sed 's/^/  /'
  else
    info "no journalctl entries for tick.service in last 24h"
  fi
else
  info "journalctl not available (not on systemd?)"
fi

# ----- summary --------------------------------------------------

printf '\n'
echo "doctor: scan complete."
