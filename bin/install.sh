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

# Pre-flight: systemd --user must be talkable. The common failure is
# sudo -iu / su - sessions that skip pam_systemd, leaving the runtime
# dir + DBus envs unset even when linger is enabled. Detect early
# with a clear fix message rather than the cryptic DBus error.
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
  cat >&2 <<EOF
no systemd user session in this shell (XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}).

systemctl --user can't reach its bus from here. usually because sudo -iu
or su - skipped pam_systemd, or linger isn't enabled for this account.

fix, in order:

  1. Enable linger so the user-systemd persists without active login:
       (as root) loginctl enable-linger $(whoami)

  2. Get a proper login session via one of:
       sudo machinectl shell $(whoami)@.host
       ssh $(whoami)@localhost
     (sudo -iu / su - often skip pam_systemd setup; avoid them.)

  3. Re-run bin/install.sh from the new session.
EOF
  exit 1
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
     Status/Needs More Info, Priority/High) and run
     bin/validate-repo.sh <owner>/<name>.
EOF
