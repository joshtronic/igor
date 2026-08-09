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
for cmd in jq curl git flock timeout claude sqlite3 openssl; do
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
      sqlite3)   apt_pkgs+=("sqlite3") ;;
      openssl)   apt_pkgs+=("openssl") ;;
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
    esac
  done
  exit 1
fi

# Recommended: dev tooling for `make test` / `make lint` (CLAUDE.md).
# Warn only -- the harness doesn't need these at runtime, but a host
# without them can't run the quality gates a PR is judged against.
missing_dev=()
for cmd in make shellcheck mdl; do
  command -v "$cmd" >/dev/null 2>&1 || missing_dev+=("$cmd")
done
if [ "${#missing_dev[@]}" -gt 0 ]; then
  echo "warning: missing recommended dev tools: ${missing_dev[*]}" >&2
  echo >&2
  echo "these aren't required to run the harness, but \`make lint\`" >&2
  echo "needs them:" >&2
  apt_pkgs=()
  for cmd in "${missing_dev[@]}"; do
    case "$cmd" in
      make)         apt_pkgs+=("make") ;;
      shellcheck)   apt_pkgs+=("shellcheck") ;;
      mdl)          apt_pkgs+=("markdownlint") ;;
    esac
  done
  if [ "${#apt_pkgs[@]}" -gt 0 ]; then
    echo "  sudo apt-get install -y ${apt_pkgs[*]}" >&2
  fi
  echo >&2
  echo "continuing install without them." >&2
  echo >&2
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

set -a
# shellcheck source=/dev/null
. "$AGENT_HOME/.env"
set +a

mkdir -p "$UNIT_DIR"
ln -sf "$AGENT_HOME/systemd/agent.service" "$UNIT_DIR/agent.service"
ln -sf "$AGENT_HOME/systemd/agent.timer"   "$UNIT_DIR/agent.timer"

systemctl --user daemon-reload
systemctl --user enable --now agent.timer
systemctl --user list-timers agent.timer --no-pager || true

# One initial successful pull of igor's prompt surfaces from the
# Distillery (joshtronic/distillery) is mandatory -- there's no in-repo
# fallback, only the last-good cache (lib/context-source.sh, igor#485).
# Seed it here rather than waiting for the first tick, so a broken or
# unreachable distillery is caught during install, not silently on the
# first minute after the timer fires.
echo
echo "-> seeding prompt-surface cache from the Distillery (joshtronic/distillery)"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
AGENT_REPO_ROOT="$AGENT_STATE_DIR/repos"
DISTILLERY_PATH="$AGENT_REPO_ROOT/distillery"

# Same SSH clone URL the harness uses (bin/tick.sh:ssh_clone_url).
ssh_clone_url() {
  local repo="$1"
  if [[ "${FORGEJO_HOST:-}" == *:* ]]; then
    echo "ssh://git@${FORGEJO_HOST}/${repo}.git"
  else
    echo "git@${FORGEJO_HOST}:${repo}.git"
  fi
}

if [ ! -d "$DISTILLERY_PATH/.git" ]; then
  mkdir -p "$AGENT_REPO_ROOT"
  git clone --quiet "$(ssh_clone_url joshtronic/distillery)" "$DISTILLERY_PATH" 2>/dev/null \
    || echo "warning: could not clone joshtronic/distillery" >&2
else
  git -C "$DISTILLERY_PATH" fetch --prune --quiet origin 2>/dev/null \
    || echo "warning: could not fetch joshtronic/distillery" >&2
fi

# shellcheck source=lib/context-source.sh
. "$AGENT_HOME/lib/context-source.sh"
if context_refresh && context_seeded; then
  echo "   prompt cache seeded OK"
else
  cat >&2 <<EOF2
warning: initial context pull did not succeed -- prompt-consuming work
(issue work, PR review, feedback triage, site-work, sports digest) will
stay BLOCKED until a tick manages one successful pull. Run
\`bin/doctor.sh\` after the timer's first fire to confirm it landed.
EOF2
fi

cat <<EOF

-> next steps

  1. bin/validate.sh -- confirm setup (env, Forgejo, bot identity).
  2. For each repo: ensure labels exist (Agent, Status/Blocked,
     Status/Need More Info, Priority/Critical) and run
     bin/validate-repo.sh <owner>/<name>.
EOF
