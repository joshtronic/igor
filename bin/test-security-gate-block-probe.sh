#!/usr/bin/env bash
# test-security-gate-block-probe.sh -- source-assertion (igor#555): the
# issue-work security-gate block site in bin/tick.sh must record a probe
# that distinguishes a completed review's material finding from a gate that
# never produced a verdict at all.
#
# Before igor#555, both cases called `agent-block.sh "<reason>"` with no
# probe args at all, so the block read UNPROBED forever -- reported
# honestly by lib/blockprobe.sh's sweep, but never cleared without a human.
# The motivating case (joshing.you#220) was blocked by exactly this path.
#
# lib/security-gate.sh and lib/blockprobe.sh are unit-tested elsewhere
# (bin/test-security-gate.sh, bin/test-blockprobe.sh) for the underlying
# return-code split and probe semantics; this file is the wiring check that
# bin/tick.sh's call site actually USES both, in the spirit of
# bin/test-heartbeat-before-security-gate.sh. Doesn't run tick.sh -- just
# greps it, so it catches a future edit that reverts to the unconditional
# no-probe call without needing to execute the whole tick.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== issue-work security-gate block site records a probe for both paths (igor#555) =="

# Isolate the block: from the security_gate call for "security-gate-issue"
# to the first `exit 0` that follows it.
START=$(grep -n 'security_gate "\$WORKTREE" "\$PR_BASE" "security-gate-issue"' "$TICK" | head -1 | cut -d: -f1)
if [ -z "$START" ]; then
  bad "could not find the issue-work security_gate call site in bin/tick.sh"
else
  REL_END=$(tail -n "+$START" "$TICK" | grep -n '^\s*exit 0\s*$' | head -1 | cut -d: -f1)
  if [ -z "$REL_END" ]; then
    bad "could not find the closing 'exit 0' for the issue-work security-gate block"
  else
    END=$((START + REL_END - 1))
    BLOCK=$(sed -n "${START},${END}p" "$TICK")

    if printf '%s\n' "$BLOCK" | grep -qF 'SEC_RC=$?'; then
      ok "captures the security_gate exit code (SEC_RC)"
    else
      bad "does not capture security_gate's exit code -- can't distinguish material BLOCK from a gate error"
    fi

    if printf '%s\n' "$BLOCK" | grep -qE '\[ "\$SEC_RC" -eq 2 \]'; then
      ok "branches on SEC_RC -eq 2 (the fail-closed/no-verdict return code)"
    else
      bad "does not branch on the no-verdict return code (2)"
    fi

    # Each agent-block.sh call's reason string spans several lines (a
    # multi-line double-quoted argument), so the probe-kind word that
    # closes it is the LAST line of that call, not the one with
    # "agent-block.sh" itself. Match on that closing line directly.
    if printf '%s\n' "$BLOCK" | grep -qF 'forever." transient'; then
      ok "the no-verdict path records a 'transient' probe"
    else
      bad "the no-verdict path does not record a 'transient' probe -- will read UNPROBED forever"
    fi

    if printf '%s\n' "$BLOCK" | grep -qF 're-queue." operator'; then
      ok "the material-finding path records an 'operator' probe"
    else
      bad "the material-finding path does not record an 'operator' probe -- will read UNPROBED forever"
    fi

    # Negative check: the pre-igor#555 shape called agent-block.sh exactly
    # once in this block, with no trailing probe-kind argument at all --
    # proving the OLD unprobed call is actually gone, not just that new
    # strings were added alongside it.
    if printf '%s\n' "$BLOCK" | grep -qF "that's a transient error -- just re-queue.)\""; then
      bad "the old unprobed agent-block.sh call (no probe-kind argument) is still present"
    else
      ok "the old unprobed agent-block.sh call is gone"
    fi
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-security-gate-block-probe: all passed"
else
  echo "test-security-gate-block-probe: $FAIL FAILED"
  exit 1
fi
