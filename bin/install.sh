#!/usr/bin/env bash
# install.sh -- One-time setup for Tick on this host.
#
# Scaffolds ~/.config/tick/ (seeds .env from .env.example if missing),
# copies the systemd units into the user's systemd dir, and enables
# the timer. Idempotent -- safe to re-run after editing templates.
#
# Adding a project does NOT require running this. Drop a new file at
# ~/.config/tick/projects/<name>.conf and the next tick picks it up.

set -euo pipefail

TICK_HOME="$(cd "$(dirname "$0")/.." && pwd)"
TICK_CONFIG_DIR="${TICK_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/tick}"
UNIT_DIR="$HOME/.config/systemd/user"

# ── Config scaffolding ─────────────────────────────────────────

mkdir -p "$TICK_CONFIG_DIR/projects"
chmod 700 "$TICK_CONFIG_DIR"

if [ ! -f "$TICK_CONFIG_DIR/.env" ]; then
  cp "$TICK_HOME/.env.example" "$TICK_CONFIG_DIR/.env"
  chmod 600 "$TICK_CONFIG_DIR/.env"
  echo "-> scaffolded $TICK_CONFIG_DIR/.env (edit before first tick)"
else
  echo "-> $TICK_CONFIG_DIR/.env already exists, leaving alone"
fi

# ── systemd units ──────────────────────────────────────────────

mkdir -p "$UNIT_DIR"

echo "-> copying unit templates to $UNIT_DIR"
cp "$TICK_HOME/systemd/tick.service" "$UNIT_DIR/"
cp "$TICK_HOME/systemd/tick.timer"   "$UNIT_DIR/"

systemctl --user daemon-reload

echo "-> enabling tick.timer"
systemctl --user enable --now tick.timer

echo
systemctl --user list-timers tick.timer --no-pager || true
