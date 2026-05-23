#!/usr/bin/env bash
# install.sh -- One-time systemd setup for the agent on this host.
#
# Symlinks the unit files into the user systemd dir (so `git pull`
# updates them with a subsequent `systemctl --user daemon-reload`)
# and enables the timer. Idempotent; safe to re-run.
#
# Local dev does NOT need this -- `cp .env.example .env`, edit, run
# `bin/tick.sh` directly. install.sh is only for the systemd-managed
# install.
#
# Adding a repo to the agent's care does NOT require running this --
# add the bot user as a collaborator on the repo and the next tick
# discovers it (and onboards if needed).

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

# Pre-flight: harness depends on these being on PATH. Fail loudly here
# rather than mysteriously deep inside tick.sh later.
missing=()
for cmd in jq curl git flock timeout claude python3 redis-cli; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing required commands: ${missing[*]}" >&2
  echo >&2
  echo "on Debian/Ubuntu:" >&2
  apt_pkgs=()
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      jq)        apt_pkgs+=("jq") ;;
      curl)      apt_pkgs+=("curl") ;;
      git)       apt_pkgs+=("git") ;;
      flock)     apt_pkgs+=("util-linux") ;;
      timeout)   apt_pkgs+=("coreutils") ;;
      python3)   apt_pkgs+=("python3" "python3-venv") ;;
      redis-cli) ;;  # provided by redis-stack-server, separate install
      claude)    ;;  # not in apt; install per Anthropic's docs
    esac
  done
  if [ "${#apt_pkgs[@]}" -gt 0 ]; then
    echo "  sudo apt-get install -y ${apt_pkgs[*]}" >&2
  fi
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      claude)
        echo "  claude: install via Anthropic's CLI installer (see docs.claude.com)" >&2
        ;;
      redis-cli)
        echo "  redis-cli: install redis-stack-server from Redis's official apt repo" >&2
        echo "  (https://redis.io/docs/latest/operate/oss_and_stack/install/install-redis/install-redis-on-linux/)" >&2
        ;;
    esac
  done
  exit 1
fi

# Pre-flight: python3-venv (the venv module is split out on Debian)
if ! python3 -c "import venv" 2>/dev/null; then
  echo "python3 is installed but the venv module is not. Install with:" >&2
  echo "  sudo apt-get install -y python3-venv" >&2
  exit 1
fi

# Pre-flight: Redis must have the vector search module loaded.
# Redis 8+ from packages.redis.io bundles it; Debian's older Redis
# (7.x) does not. Try a quick MODULE LIST; if Redis isn't running
# we'll get a different error and fall through.
if redis-cli ping >/dev/null 2>&1; then
  if ! redis-cli MODULE LIST 2>/dev/null | grep -qi search; then
    echo "Redis is reachable but the search/vector module is not loaded." >&2
    echo "The RAG layer requires Redis 8+ (which bundles vector search)." >&2
    echo "Likely on Debian's older redis-server (7.x). Switch to Redis's" >&2
    echo "official apt repo:" >&2
    echo "  sudo apt remove --purge redis-server" >&2
    echo "  # add packages.redis.io to apt, then:" >&2
    echo "  sudo apt install redis-server" >&2
    echo "See docs/setup.md for the full apt repo setup." >&2
    exit 1
  fi
else
  echo "redis-cli installed but Redis is not running on localhost:6379." >&2
  echo "Start it: sudo systemctl enable --now redis-server" >&2
  exit 1
fi

# Pre-flight: bootstrap the RAG Python venv. Idempotent -- no-op
# after first successful run (or when requirements.txt changes).
# Done up front so first tick doesn't pay the install cost.
if ! "$AGENT_HOME/bin/setup-rag.sh"; then
  echo "RAG venv setup failed. See output above." >&2
  exit 1
fi

# Pre-flight: systemd --user needs XDG_RUNTIME_DIR + DBUS env to
# reach its bus. sudo -iu / su - sessions skip pam_systemd and don't
# set these, even when linger is enabled and the runtime dir
# physically exists. Try to fix it ourselves before failing.
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
  CANDIDATE="/run/user/$(id -u)"
  if [ -d "$CANDIDATE" ] && [ -S "$CANDIDATE/bus" ]; then
    echo "-> XDG_RUNTIME_DIR was unset; linger appears active, using $CANDIDATE"
    export XDG_RUNTIME_DIR="$CANDIDATE"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$CANDIDATE/bus"
  else
    cat >&2 <<EOF
no systemd user session reachable, and $CANDIDATE doesn't exist (or
has no bus socket). this account needs linger enabled so its user-
systemd instance persists without an active login.

fix (run by a user with sudo, doesn't have to be $(whoami)):

  sudo loginctl enable-linger $(whoami)

then re-run bin/install.sh from this same shell. linger creates the
runtime dir immediately -- no need to log out and back in.
EOF
    exit 1
  fi
fi

if [ ! -f "$AGENT_HOME/.env" ]; then
  echo "no $AGENT_HOME/.env -- run \`cp .env.example .env\`, edit it, then re-run install" >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"
ln -sf "$AGENT_HOME/systemd/agent.service" "$UNIT_DIR/agent.service"
ln -sf "$AGENT_HOME/systemd/agent.timer"   "$UNIT_DIR/agent.timer"

systemctl --user daemon-reload
systemctl --user enable --now agent.timer
systemctl --user list-timers agent.timer --no-pager || true

cat <<EOF

-> next steps

  1. bin/validate.sh -- confirm setup (env, Forgejo, bot identity).
  2. For each repo: ensure labels exist (Agent, Status/Blocked,
     Status/Needs More Info, Priority/Critical) and run
     bin/validate-repo.sh <owner>/<name>.
EOF
