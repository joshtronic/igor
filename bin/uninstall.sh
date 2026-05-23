#!/usr/bin/env bash
# uninstall.sh -- Stop and disable the agent's systemd timer on this host.
#
# Leaves the clone (with .env) and ~/.local/state/agent/ alone -- this
# is the inverse of install.sh only. Pair with `rm -rf` on those for
# a full teardown.

set -uo pipefail

UNIT_DIR="$HOME/.config/systemd/user"

if systemctl --user list-unit-files agent.timer --no-pager 2>/dev/null | grep -q agent.timer; then
  echo "-> stopping and disabling agent.timer"
  systemctl --user disable --now agent.timer 2>/dev/null || true
else
  echo "-> agent.timer not installed, nothing to disable"
fi

if [ -f "$UNIT_DIR/agent.timer" ] || [ -f "$UNIT_DIR/agent.service" ]; then
  echo "-> removing unit files from $UNIT_DIR"
  \rm -f "$UNIT_DIR/agent.timer" "$UNIT_DIR/agent.service"
fi

systemctl --user daemon-reload
echo "done"
