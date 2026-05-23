#!/usr/bin/env bash
# validate.sh -- Validate the agent's setup: env, library deps, Forgejo
# reachability, bot identity, and accessible repos. Exits non-zero on
# any failure.

set -uo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ENV_PRESENT=0

if [ -f "$AGENT_HOME/.env" ]; then
  ENV_PRESENT=1
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

pass() { printf '  \033[32m+\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mx\033[0m %s%s\n' "$1" "${2:+ -- $2}"; FAIL=1; }

# -- Required commands on PATH ----------------------------------

echo "== deps =="
for cmd in jq curl git flock timeout claude python3 redis-cli; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd installed"
  else
    case "$cmd" in
      jq|curl|git)        fail "$cmd installed" "sudo apt-get install -y $cmd" ;;
      flock)              fail "$cmd installed" "sudo apt-get install -y util-linux" ;;
      timeout)            fail "$cmd installed" "sudo apt-get install -y coreutils" ;;
      claude)             fail "$cmd installed" "install per Anthropic's CLI docs" ;;
      python3)            fail "$cmd installed" "sudo apt-get install -y python3 python3-venv" ;;
      redis-cli)          fail "$cmd installed" "install redis-server 8+ from packages.redis.io (see docs/setup.md)" ;;
    esac
  fi
done

if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import venv" 2>/dev/null; then
    pass "python3-venv module available"
  else
    fail "python3-venv module available" "sudo apt-get install -y python3-venv"
  fi
fi
echo

# -- Global env -------------------------------------------------

echo "== env =="
if [ "$ENV_PRESENT" -eq 1 ]; then
  pass ".env present"
else
  fail ".env present" "cp .env.example .env, then fill in every var"
fi

# Mirrors the required-var list enforced at tick.sh entry. Keep
# these two in sync -- a var added there should be added here so
# operators see the missing config before kicking off a tick.
for var in \
    ANTHROPIC_API_KEY \
    AGENT_MODEL \
    AGENT_MODEL_THINKING \
    FORGEJO_URL \
    FORGEJO_TOKEN \
    FORGEJO_HOST \
    FORGEJO_REVIEWER \
    REDIS_URL \
    TICK_TIMEOUT \
    AGENT_SHIFT_START \
    AGENT_SHIFT_END \
    AGENT_RECALL_DAYS \
    ; do
  if [ -n "${!var:-}" ]; then
    case "$var" in
      ANTHROPIC_API_KEY|FORGEJO_TOKEN) pass "$var set" ;;
      *) pass "$var set (${!var})" ;;
    esac
  else
    fail "$var set" "missing from .env"
  fi
done

# Light format checks on the vars where a typo silently breaks
# behavior later (timeout that won't parse, shift outside 0-23, etc.).
if [ -n "${TICK_TIMEOUT:-}" ] && ! [[ "$TICK_TIMEOUT" =~ ^[0-9]+[smhd]$ ]]; then
  fail "TICK_TIMEOUT format" "expected like 60m, 2h, 30s, 1d -- got '$TICK_TIMEOUT'"
fi
for shift_var in AGENT_SHIFT_START AGENT_SHIFT_END; do
  val="${!shift_var:-}"
  if [ -n "$val" ] && ! [[ "$val" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    fail "$shift_var format" "expected 0-23 (24h clock) -- got '$val'"
  fi
done
if [ -n "${AGENT_RECALL_DAYS:-}" ] && ! [[ "$AGENT_RECALL_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  fail "AGENT_RECALL_DAYS format" "expected positive integer -- got '$AGENT_RECALL_DAYS'"
fi

[ -f "$AGENT_HOME/agent-settings.json" ] && pass "agent-settings.json present" || fail "agent-settings.json present"

state_dir="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
if mkdir -p "$state_dir/worktrees" "$state_dir/repos" 2>/dev/null \
   && [ -w "$state_dir/worktrees" ] && [ -w "$state_dir/repos" ]; then
  pass "state dir writable ($state_dir)"
else
  fail "state dir writable ($state_dir)"
fi
echo

# -- RAG layer (Redis 8+ with vector index, Python venv, deps) --

echo "== rag =="

if command -v redis-cli >/dev/null 2>&1; then
  if redis-cli ping >/dev/null 2>&1; then
    pass "Redis reachable at localhost:6379"
    if redis-cli MODULE LIST 2>/dev/null | grep -qi search; then
      pass "Redis vector search module loaded"
    else
      fail "Redis vector search module loaded" \
           "running older Redis without modules; install redis-server 8+ from packages.redis.io (see docs/setup.md)"
    fi
  else
    fail "Redis reachable at localhost:6379" \
         "sudo systemctl enable --now redis-server"
  fi
fi

venv="$state_dir/rag-venv"
if [ -x "$venv/bin/python" ]; then
  pass "RAG venv exists ($venv)"
  if "$venv/bin/python" -c "import redisvl, fastembed" 2>/dev/null; then
    pass "RAG deps importable (redisvl, fastembed)"
  else
    fail "RAG deps importable (redisvl, fastembed)" \
         "rerun bin/install.sh, or directly bin/setup-rag.sh"
  fi
else
  fail "RAG venv exists ($venv)" \
       "rerun bin/install.sh, or directly bin/setup-rag.sh"
fi
echo

# -- Forgejo connectivity + bot identity ------------------------

echo "== forgejo =="
if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_TOKEN:-}" ]; then
  fail "Forgejo checks" "skipped -- creds missing"
  exit $FAIL
fi

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"

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
echo

# -- SSH connectivity to git endpoint ---------------------------
#
# HTTPS-to-the-API working (above) doesn't mean SSH-for-git-clone
# works. Different port, different auth (key vs token), different
# failure modes. Test SSH explicitly.

echo "== SSH =="

SSH_TARGET="${FORGEJO_HOST:-$(echo "$FORGEJO_URL" | sed -E 's|^[a-z]+://([^/:]+).*|\1|')}"
SSH_HOST_ONLY="$SSH_TARGET"
SSH_PORT_FLAG=()
if [[ "$SSH_TARGET" == *:* ]]; then
  SSH_HOST_ONLY="${SSH_TARGET%:*}"
  SSH_PORT_FLAG=("-p" "${SSH_TARGET##*:}")
fi

ssh_out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  "${SSH_PORT_FLAG[@]}" "git@${SSH_HOST_ONLY}" 2>&1 || true)

if grep -qE 'Connection timed out|No route to host|Could not resolve hostname|Connection refused' <<<"$ssh_out"; then
  fail "Forgejo SSH endpoint reachable ($SSH_TARGET)" \
       "endpoint unreachable. If Forgejo SSH is on a non-default port, set FORGEJO_HOST=host:port in .env, or add a Host entry to ~/.ssh/config"
elif grep -qE 'Permission denied \(publickey\)' <<<"$ssh_out"; then
  fail "Forgejo SSH authenticates as bot ($SSH_TARGET)" \
       "SSH key not recognized by Forgejo. ssh-keygen -t ed25519 if needed, then add the .pub to the bot user's Forgejo SSH keys"
elif grep -qiE 'authenticated|Hi |welcome' <<<"$ssh_out"; then
  pass "Forgejo SSH reachable + authenticates as bot ($SSH_TARGET)"
else
  fail "Forgejo SSH check ($SSH_TARGET)" \
       "unexpected response: $(echo "$ssh_out" | head -1)"
fi

exit $FAIL
