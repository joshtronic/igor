#!/usr/bin/env bash
# validate.sh — Validate Tick's setup: global env, then every project
# in projects/. Exits non-zero on any failure.

set -uo pipefail

TICK_HOME="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

if [ -f "$TICK_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$TICK_HOME/.env"
  set +a
fi

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s%s\n' "$1" "${2:+ — $2}"; FAIL=1; }

# ── Global checks ──────────────────────────────────────────────

echo "== global =="
[ -n "${FORGEJO_URL:-}" ]             && pass "FORGEJO_URL set"             || fail "FORGEJO_URL set"             "missing from .env"
[ -n "${FORGEJO_TOKEN:-}" ]           && pass "FORGEJO_TOKEN set"           || fail "FORGEJO_TOKEN set"           "missing from .env"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && pass "CLAUDE_CODE_OAUTH_TOKEN set" || fail "CLAUDE_CODE_OAUTH_TOKEN set" "missing from .env"

[ -f "$TICK_HOME/agent-settings.json" ] && pass "agent-settings.json present" || fail "agent-settings.json present"

state_dir="${TICK_STATE_DIR:-$HOME/.local/state/tick}"
if mkdir -p "$state_dir/worktrees" 2>/dev/null && [ -w "$state_dir/worktrees" ]; then
  pass "state dir writable ($state_dir)"
else
  fail "state dir writable ($state_dir)"
fi
echo

# ── Per-project checks ─────────────────────────────────────────

shopt -s nullglob
confs=("$TICK_HOME"/projects/*.conf)
if [ ${#confs[@]} -eq 0 ]; then
  echo "no projects in $TICK_HOME/projects/"
  exit $FAIL
fi

for conf in "${confs[@]}"; do
  project="$(basename "$conf" .conf)"
  echo "== $project =="

  unset REPO_PATH FORGEJO_REPO PR_BASE TICK_TIMEOUT BOT_USER
  # shellcheck source=/dev/null
  . "$conf"

  [ -n "${REPO_PATH:-}" ]    && pass "REPO_PATH set"    || { fail "REPO_PATH set";    echo; continue; }
  [ -n "${FORGEJO_REPO:-}" ] && pass "FORGEJO_REPO set" || { fail "FORGEJO_REPO set"; echo; continue; }

  if [ -d "$REPO_PATH/.git" ]; then
    pass "REPO_PATH is a git repo"
  else
    fail "REPO_PATH is a git repo" "$REPO_PATH/.git missing"
  fi

  if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_TOKEN:-}" ]; then
    fail "Forgejo API checks" "skipped — global creds missing"
    echo
    continue
  fi

  api="$FORGEJO_URL/api/v1"

  if curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$api/repos/$FORGEJO_REPO" >/dev/null 2>&1; then
    pass "Forgejo repo reachable"
  else
    fail "Forgejo repo reachable" "GET /repos/$FORGEJO_REPO failed"
    echo
    continue
  fi

  labels_json=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
                "$api/repos/$FORGEJO_REPO/labels" 2>/dev/null || echo "[]")
  for label in "Agent" "Status/Blocked"; do
    if jq -e --arg n "$label" '.[] | select(.name == $n)' >/dev/null 2>&1 <<<"$labels_json"; then
      pass "label '$label' exists"
    else
      fail "label '$label' exists"
    fi
  done

  bot="${BOT_USER:-agent}"
  if curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$api/users/$bot" >/dev/null 2>&1; then
    pass "bot user '$bot' exists on Forgejo"
  else
    fail "bot user '$bot' exists on Forgejo"
  fi

  echo
done

exit $FAIL
