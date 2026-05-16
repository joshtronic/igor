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
