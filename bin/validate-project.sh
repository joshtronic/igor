#!/usr/bin/env bash
# validate-project.sh — Validate a Tick project's setup.
#
# Usage:
#   validate-project.sh <name>   # check one project
#   validate-project.sh          # check all projects in projects/
#
# Each check exits non-zero on any failure so the script is usable
# as a deploy gate or pre-tick sanity check.

set -uo pipefail

TICK_HOME="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

# Load .env so FORGEJO_TOKEN etc. are available for API checks.
if [ -f "$TICK_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$TICK_HOME/.env"
  set +a
fi

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s%s\n' "$1" "${2:+ — $2}"; FAIL=1; }

# ── Global checks (run once) ───────────────────────────────────

check_global() {
  echo "== global =="
  [ -n "${FORGEJO_URL:-}" ]            && pass "FORGEJO_URL set"            || fail "FORGEJO_URL set"            "missing from .env"
  [ -n "${FORGEJO_TOKEN:-}" ]          && pass "FORGEJO_TOKEN set"          || fail "FORGEJO_TOKEN set"          "missing from .env"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && pass "CLAUDE_CODE_OAUTH_TOKEN set" || fail "CLAUDE_CODE_OAUTH_TOKEN set" "missing from .env"

  local state_dir="${TICK_STATE_DIR:-$HOME/.local/state/tick}"
  if mkdir -p "$state_dir/worktrees" 2>/dev/null && [ -w "$state_dir/worktrees" ]; then
    pass "state dir writable ($state_dir)"
  else
    fail "state dir writable ($state_dir)"
  fi
  echo
}

# ── Per-project checks ─────────────────────────────────────────

check_project() {
  local project="$1"
  echo "== $project =="

  local conf="$TICK_HOME/projects/${project}.conf"
  if [ ! -f "$conf" ]; then
    fail "conf file" "$conf not found"
    echo
    return
  fi
  pass "conf file ($conf)"

  # Reset conf vars before sourcing
  unset REPO_PATH FORGEJO_REPO PR_BASE TICK_TIMEOUT BOT_USER
  # shellcheck source=/dev/null
  . "$conf"

  # Required
  [ -n "${REPO_PATH:-}" ]    && pass "REPO_PATH set"    || { fail "REPO_PATH set"; echo; return; }
  [ -n "${FORGEJO_REPO:-}" ] && pass "FORGEJO_REPO set" || { fail "FORGEJO_REPO set"; echo; return; }

  # Local repo
  if [ -d "$REPO_PATH/.git" ]; then
    pass "REPO_PATH is a git repo"
  else
    fail "REPO_PATH is a git repo" "$REPO_PATH/.git missing"
  fi

  # .claude/settings.json
  if [ -f "$REPO_PATH/.claude/settings.json" ]; then
    pass ".claude/settings.json present"
  else
    fail ".claude/settings.json present"
  fi

  # Forgejo API checks (skip if creds missing)
  if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_TOKEN:-}" ]; then
    fail "Forgejo API checks" "skipped — global creds missing"
    echo
    return
  fi

  local api="$FORGEJO_URL/api/v1"

  # Repo reachable
  if curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$api/repos/$FORGEJO_REPO" >/dev/null 2>&1; then
    pass "Forgejo repo reachable"
  else
    fail "Forgejo repo reachable" "GET /repos/$FORGEJO_REPO failed"
    echo
    return
  fi

  # Required labels
  local labels_json
  labels_json=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
                "$api/repos/$FORGEJO_REPO/labels" 2>/dev/null || echo "[]")
  for label in "Agent" "Status/Blocked"; do
    if jq -e --arg n "$label" '.[] | select(.name == $n)' >/dev/null 2>&1 <<<"$labels_json"; then
      pass "label '$label' exists"
    else
      fail "label '$label' exists"
    fi
  done

  # Bot user reachable
  local bot="${BOT_USER:-igor}"
  if curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$api/users/$bot" >/dev/null 2>&1; then
    pass "bot user '$bot' exists on Forgejo"
  else
    fail "bot user '$bot' exists on Forgejo"
  fi

  echo
}

# ── Main ───────────────────────────────────────────────────────

check_global

if [ $# -eq 0 ]; then
  shopt -s nullglob
  found=0
  for conf in "$TICK_HOME"/projects/*.conf; do
    found=1
    check_project "$(basename "$conf" .conf)"
  done
  if [ $found -eq 0 ]; then
    echo "no projects in $TICK_HOME/projects/"
  fi
else
  check_project "$1"
fi

exit $FAIL
