#!/usr/bin/env bash
# install.sh — One-time setup for Tick on this host.
#
# Copies the global tick.service / tick.timer units into the user's
# systemd directory and enables the timer. Idempotent — safe to run
# again after editing the templates.
#
# Adding a project does NOT require running this. Just drop a new
# file at projects/<name>.conf and the next tick will pick it up.

set -euo pipefail

TICK_HOME="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$UNIT_DIR"

echo "→ copying unit templates to $UNIT_DIR"
cp "$TICK_HOME/systemd/tick.service" "$UNIT_DIR/"
cp "$TICK_HOME/systemd/tick.timer"   "$UNIT_DIR/"

systemctl --user daemon-reload

echo "→ enabling tick.timer"
systemctl --user enable --now tick.timer

echo
systemctl --user list-timers tick.timer --no-pager || true
