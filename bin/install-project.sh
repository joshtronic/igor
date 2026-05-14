#!/usr/bin/env bash
# install-project.sh — Install systemd timers for a Foreman project.
#
# Usage: install-project.sh <project>
#
# - Verifies projects/<project>.conf exists
# - Copies template units to ~/.config/systemd/user/ (idempotent)
# - Enables foreman-tick@<project>.timer
# - Enables foreman-enqueue@<project>.timer if ENQUEUE_CMD is set

set -euo pipefail

FOREMAN_HOME="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${1:?usage: install-project.sh <project>}"

CONF="$FOREMAN_HOME/projects/${PROJECT}.conf"
if [ ! -f "$CONF" ]; then
  echo "install: no conf at $CONF" >&2
  echo "  create the .conf first; nothing to install otherwise" >&2
  exit 2
fi

# shellcheck source=/dev/null
. "$CONF"

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

echo "→ copying unit templates to $UNIT_DIR"
cp "$FOREMAN_HOME"/systemd/foreman-tick@.service    "$UNIT_DIR/"
cp "$FOREMAN_HOME"/systemd/foreman-tick@.timer      "$UNIT_DIR/"
cp "$FOREMAN_HOME"/systemd/foreman-enqueue@.service "$UNIT_DIR/"
cp "$FOREMAN_HOME"/systemd/foreman-enqueue@.timer   "$UNIT_DIR/"

systemctl --user daemon-reload

echo "→ enabling foreman-tick@${PROJECT}.timer"
systemctl --user enable --now "foreman-tick@${PROJECT}.timer"

if [ -n "${ENQUEUE_CMD:-}" ]; then
  echo "→ enabling foreman-enqueue@${PROJECT}.timer"
  systemctl --user enable --now "foreman-enqueue@${PROJECT}.timer"
else
  echo "→ no ENQUEUE_CMD in conf — skipping enqueue timer"
fi

echo
systemctl --user list-timers "foreman-*@${PROJECT}.timer" --no-pager || true
