#!/usr/bin/env bash
# uninstall.sh -- Stop and disable Tick's systemd timer on this host.
#
# Leaves projects/, agent-settings.json, .env, etc. alone -- this is
# the inverse of install.sh only. Pair with `rm -rf` on the repo if
# you want a full teardown.

set -uo pipefail

UNIT_DIR="$HOME/.config/systemd/user"

if systemctl --user list-unit-files tick.timer --no-pager 2>/dev/null | grep -q tick.timer; then
  echo "-> stopping and disabling tick.timer"
  systemctl --user disable --now tick.timer 2>/dev/null || true
else
  echo "-> tick.timer not installed, nothing to disable"
fi

if [ -f "$UNIT_DIR/tick.timer" ] || [ -f "$UNIT_DIR/tick.service" ]; then
  echo "-> removing unit files from $UNIT_DIR"
  \rm -f "$UNIT_DIR/tick.timer" "$UNIT_DIR/tick.service"
fi

systemctl --user daemon-reload
echo "done"
