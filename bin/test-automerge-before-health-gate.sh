#!/usr/bin/env bash
# test-automerge-before-health-gate.sh -- source-assertion (igor#386): the
# validation sweep (which builds VALIDATED_REPOS_JSON) and the
# `do_automerge_tick && exit 0` call site in bin/tick.sh must both appear
# BEFORE the `claude_health_blocked` gate. do_automerge_tick is non-model
# (API + curl only) and is documented to run even during a live Claude
# cooldown -- but it depends on VALIDATED_REPOS_JSON, so if the sweep that
# builds that set sits below the gate, a cooldown silently skips auto-merge
# fleet-wide for its entire duration with no error and nothing to grep for
# (the actual root cause of igor#386: an eligible, approved, CI-green bot PR
# on knowthetable.com never got auto-merged).
#
# Doesn't run tick.sh -- just greps it, in the spirit of check-sync.sh's
# OUTCOME-sentinel checks and test-heartbeat-before-security-gate.sh. Catches
# a future edit that re-sinks either call site below the health gate.
#
# Run standalone (`bin/test-automerge-before-health-gate.sh`) or via
# `make test`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== validation sweep + do_automerge_tick sit above claude_health_blocked =="

gate_line=$(grep -n 'if claude_health_blocked; then' "$TICK" | head -1 | cut -d: -f1)
sweep_line=$(grep -n 'log "validation sweep' "$TICK" | head -1 | cut -d: -f1)
automerge_line=$(grep -n '^do_automerge_tick && exit 0' "$TICK" | head -1 | cut -d: -f1)

if [ -z "$gate_line" ]; then
  bad "no 'if claude_health_blocked' gate found in bin/tick.sh"
else
  ok "found claude_health_blocked gate at line $gate_line"
fi

if [ -z "$sweep_line" ]; then
  bad "no validation-sweep start ('log \"validation sweep') found in bin/tick.sh"
elif [ -n "$gate_line" ] && [ "$sweep_line" -lt "$gate_line" ]; then
  ok "validation sweep (line $sweep_line) precedes the health gate (line $gate_line)"
else
  bad "validation sweep (line $sweep_line) does NOT precede the health gate (line $gate_line) -- do_automerge_tick would starve during a Claude cooldown"
fi

if [ -z "$automerge_line" ]; then
  bad "no top-level 'do_automerge_tick && exit 0' call site found in bin/tick.sh"
elif [ -n "$gate_line" ] && [ "$automerge_line" -lt "$gate_line" ]; then
  ok "do_automerge_tick call (line $automerge_line) precedes the health gate (line $gate_line)"
else
  bad "do_automerge_tick call (line $automerge_line) does NOT precede the health gate (line $gate_line) -- auto-merge would silently stop firing during a Claude cooldown"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-automerge-before-health-gate: all passed"
else
  echo "test-automerge-before-health-gate: $FAIL FAILED"
  exit 1
fi
