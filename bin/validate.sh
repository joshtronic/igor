#!/usr/bin/env bash
# validate.sh -- Validate Igor's setup: env, library deps, Forgejo
# reachability, bot identity, and accessible repos. Exits non-zero on
# any failure.

set -uo pipefail

IGOR_HOME="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

if [ -f "$IGOR_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_HOME/.env"
  set +a
fi

pass() { printf '  \033[32m+\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mx\033[0m %s%s\n' "$1" "${2:+ -- $2}"; FAIL=1; }

# -- Global env -------------------------------------------------

echo "== env =="
[ -n "${FORGEJO_URL:-}" ]       && pass "FORGEJO_URL set"       || fail "FORGEJO_URL set"       "missing from .env"
[ -n "${FORGEJO_TOKEN:-}" ]     && pass "FORGEJO_TOKEN set"     || fail "FORGEJO_TOKEN set"     "missing from .env"
[ -n "${ANTHROPIC_API_KEY:-}" ] && pass "ANTHROPIC_API_KEY set" || fail "ANTHROPIC_API_KEY set" "missing from .env"
[ -n "${IGOR_MODEL:-}" ]        && pass "IGOR_MODEL set ($IGOR_MODEL)" || fail "IGOR_MODEL set" "missing from .env"

[ -f "$IGOR_HOME/agent-settings.json" ] && pass "agent-settings.json present" || fail "agent-settings.json present"

state_dir="${IGOR_STATE_DIR:-$HOME/.local/state/igor}"
if mkdir -p "$state_dir/worktrees" "$state_dir/repos" 2>/dev/null \
   && [ -w "$state_dir/worktrees" ] && [ -w "$state_dir/repos" ]; then
  pass "state dir writable ($state_dir)"
else
  fail "state dir writable ($state_dir)"
fi
echo

# -- Forgejo connectivity + bot identity ------------------------

echo "== forgejo =="
if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_TOKEN:-}" ]; then
  fail "Forgejo checks" "skipped -- creds missing"
  exit $FAIL
fi

# shellcheck source=../lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"

bot=$(forgejo_whoami 2>/dev/null || echo "")
if [ -n "$bot" ]; then
  pass "bot identity resolves ($bot via /api/v1/user)"
else
  fail "bot identity resolves" "GET /api/v1/user failed"
  exit $FAIL
fi

repos=$(forgejo_list_bot_repos 2>/dev/null || echo "[]")
repo_count=$(jq 'length' <<<"$repos" 2>/dev/null || echo 0)
if [ "$repo_count" -gt 0 ]; then
  pass "bot has push access to $repo_count repo(s)"
  jq -r '.[] | "    - \(.full_name) (default: \(.default_branch))"' <<<"$repos"
else
  fail "bot has push access to at least one repo" \
       "add $bot as a collaborator with write permission on a repo"
fi

exit $FAIL
