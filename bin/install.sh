#!/usr/bin/env bash
# install.sh -- One-time systemd setup for Igor on this host.
#
# Symlinks the unit files into the user systemd dir (so `git pull`
# updates them with a subsequent `systemctl --user daemon-reload`)
# and enables the timer. Idempotent; safe to re-run.
#
# Local dev does NOT need this -- `cp .env.example .env`, edit, run
# `bin/tick.sh` directly. install.sh is only for the systemd-managed
# install.
#
# Adding a repo to Igor's care does NOT require running this -- add
# the bot user as a collaborator on the repo and the next tick
# discovers it (and onboards if needed).

set -euo pipefail

IGOR_HOME="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

# Pre-flight: harness depends on these being on PATH. Fail loudly here
# rather than mysteriously deep inside tick.sh later.
missing=()
for cmd in jq curl git flock timeout claude; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing required commands: ${missing[*]}" >&2
  echo >&2
  echo "on Debian/Ubuntu:" >&2
  apt_pkgs=()
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      jq)      apt_pkgs+=("jq") ;;
      curl)    apt_pkgs+=("curl") ;;
      git)     apt_pkgs+=("git") ;;
      flock)   apt_pkgs+=("util-linux") ;;
      timeout) apt_pkgs+=("coreutils") ;;
      claude)  ;;  # not in apt; install per Anthropic's docs
    esac
  done
  if [ "${#apt_pkgs[@]}" -gt 0 ]; then
    echo "  sudo apt-get install -y ${apt_pkgs[*]}" >&2
  fi
  for cmd in "${missing[@]}"; do
    [ "$cmd" = "claude" ] && echo "  claude: install via Anthropic's CLI installer (see docs.claude.com)" >&2
  done
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

if [ ! -f "$IGOR_HOME/.env" ]; then
  echo "no $IGOR_HOME/.env -- run \`cp .env.example .env\`, edit it, then re-run install" >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"
ln -sf "$IGOR_HOME/systemd/tick.service" "$UNIT_DIR/tick.service"
ln -sf "$IGOR_HOME/systemd/tick.timer"   "$UNIT_DIR/tick.timer"

systemctl --user daemon-reload
systemctl --user enable --now tick.timer
systemctl --user list-timers tick.timer --no-pager || true

cat <<EOF

-> next steps

  1. bin/validate.sh -- confirm setup (env, Forgejo, bot identity).
  2. For each repo: ensure labels exist (Agent, Status/Blocked,
     Status/Needs More Info, Priority/Critical) and run
     bin/validate-repo.sh <owner>/<name>.
EOF
