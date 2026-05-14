#!/usr/bin/env bash
# uninstall-project.sh — Stop and disable a project's Foreman timers.
#
# Usage: uninstall-project.sh <project>
#
# Safe to run on a project whose .conf has already been deleted.
# Does not remove the shared unit templates (other projects may use them).

set -uo pipefail

PROJECT="${1:?usage: uninstall-project.sh <project>}"

for unit in "foreman-tick@${PROJECT}.timer" "foreman-enqueue@${PROJECT}.timer"; do
  if systemctl --user list-unit-files "$unit" --no-pager 2>/dev/null | grep -q "$unit"; then
    echo "→ stopping and disabling $unit"
    systemctl --user disable --now "$unit" 2>/dev/null || true
  else
    echo "→ $unit not installed, skipping"
  fi
done

systemctl --user daemon-reload
echo "done"
