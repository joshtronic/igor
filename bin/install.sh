#!/usr/bin/env bash
# install.sh -- One-time setup for Igor on this host.
#
# Scaffolds ~/.config/igor/ (seeds .env from .env.example if missing),
# copies the systemd units into the user's systemd dir, and enables
# the timer. Idempotent -- safe to re-run after editing templates.
#
# Adding a repo does NOT require running this. Add the bot user as a
# collaborator (write perm) on the repo in Forgejo and the next tick
# discovers it automatically.

set -euo pipefail

IGOR_HOME="$(cd "$(dirname "$0")/.." && pwd)"
IGOR_CONFIG_DIR="${IGOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/igor}"
UNIT_DIR="$HOME/.config/systemd/user"

# ── Config scaffolding ─────────────────────────────────────────

mkdir -p "$IGOR_CONFIG_DIR"
chmod 700 "$IGOR_CONFIG_DIR"

if [ ! -f "$IGOR_CONFIG_DIR/.env" ]; then
  cp "$IGOR_HOME/.env.example" "$IGOR_CONFIG_DIR/.env"
  chmod 600 "$IGOR_CONFIG_DIR/.env"
  echo "-> scaffolded $IGOR_CONFIG_DIR/.env (edit before first tick)"
else
  echo "-> $IGOR_CONFIG_DIR/.env already exists, leaving alone"
fi

# ── systemd units ──────────────────────────────────────────────

mkdir -p "$UNIT_DIR"

echo "-> copying unit templates to $UNIT_DIR"
cp "$IGOR_HOME/systemd/tick.service" "$UNIT_DIR/"
cp "$IGOR_HOME/systemd/tick.timer"   "$UNIT_DIR/"

systemctl --user daemon-reload

echo "-> enabling tick.timer"
systemctl --user enable --now tick.timer

echo
systemctl --user list-timers tick.timer --no-pager || true
