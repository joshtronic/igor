#!/usr/bin/env bash
# test-heartbeat-before-security-gate.sh -- source-assertion (igor#360):
# every `security_gate` invocation in bin/tick.sh must be immediately
# preceded (within a few lines, allowing for a comment block) by an
# `hc_ping heartbeat` call. security_gate always follows another long
# model call earlier in the same tick (the tier-1/PR-review build), so
# without a heartbeat right before it the dead-man's-switch gap between
# pings is the SUM of both stages (~55m) instead of the longest single
# one (~30m).
#
# Doesn't run tick.sh -- just greps it, in the spirit of check-sync.sh's
# OUTCOME-sentinel checks. Catches a future edit that adds/moves a
# security_gate call site without carrying the heartbeat along.
#
# Run standalone (`bin/test-heartbeat-before-security-gate.sh`) or via
# `make test`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== heartbeat precedes every security_gate call =="

LOOKBACK=8

lines=$(grep -n 'security_gate "' "$TICK" | cut -d: -f1)
if [ -z "$lines" ]; then
  bad "no security_gate call sites found in bin/tick.sh (expected at least 2)"
else
  for ln in $lines; do
    start=$(( ln - LOOKBACK ))
    [ "$start" -lt 1 ] && start=1
    window=$(sed -n "${start},${ln}p" "$TICK")
    if printf '%s\n' "$window" | grep -q 'hc_ping heartbeat'; then
      ok "line $ln: hc_ping heartbeat found within $LOOKBACK lines before"
    else
      bad "line $ln: no hc_ping heartbeat within $LOOKBACK lines before security_gate call"
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-heartbeat-before-security-gate: all passed"
else
  echo "test-heartbeat-before-security-gate: $FAIL FAILED"
  exit 1
fi
