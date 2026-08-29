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
# (bin/test-security-gate.sh, bin/test-blockprobe.sh -- including the
# behavioural pair: this reason WITH a transient probe self-clears, the same
# reason with the probe recording severed reads UNPROBED) for the underlying
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
  REL_END=$(tail -n "+$START" "$TICK" | grep -n '^[[:space:]]*exit 0[[:space:]]*$' | head -1 | cut -d: -f1)
  if [ -z "$REL_END" ]; then
    bad "could not find the closing 'exit 0' for the issue-work security-gate block"
  else
    END=$((START + REL_END - 1))
    BLOCK=$(sed -n "${START},${END}p" "$TICK")

    # `$?` is clobbered by the next command that runs, so SEC_RC must be the
    # FIRST statement in the else branch -- a `log` line slipped above it
    # would make every gate error read as rc 0 and take the material-finding
    # branch, silently. Comments and blank lines don't clobber $?.
    OUTER_ELSE=$(printf '%s\n' "$BLOCK" | grep -nE '^[[:space:]]*else[[:space:]]*$' | head -1 | cut -d: -f1)
    FIRST_STMT=$(printf '%s\n' "$BLOCK" | tail -n "+$((${OUTER_ELSE:-0} + 1))" \
      | grep -vE '^[[:space:]]*(#.*)?$' | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$OUTER_ELSE" ] && [ "$FIRST_STMT" = 'SEC_RC=$?' ]; then
      ok "captures security_gate's exit code as the first statement of the else branch"
    else
      bad "SEC_RC=\$? is not the first statement after 'else' (found: ${FIRST_STMT:-<none>}) -- \$? is clobbered, so every gate error would misread as a material finding"
    fi

    if printf '%s\n' "$BLOCK" | grep -qE '\[ "\$SEC_RC" -eq 2 \]'; then
      ok "branches on SEC_RC -eq 2 (the fail-closed/no-verdict return code)"
    else
      bad "does not branch on the no-verdict return code (2)"
    fi

    # Assert per BRANCH, not on the reason prose: each agent-block.sh call's
    # reason is a multi-line double-quoted argument, so the probe kind is the
    # trailing word on the line that closes it. Slicing the if/else lets the
    # reason wording change freely without breaking the wiring check.
    IF_LN=$(printf '%s\n' "$BLOCK" | grep -nE '\[ "\$SEC_RC" -eq 2 \]' | head -1 | cut -d: -f1)
    ELSE_LN=$(printf '%s\n' "$BLOCK" | tail -n "+${IF_LN:-1}" | grep -nE '^[[:space:]]*else[[:space:]]*$' | head -1 | cut -d: -f1)
    FI_LN=$(printf '%s\n' "$BLOCK" | tail -n "+${IF_LN:-1}" | grep -nE '^[[:space:]]*fi[[:space:]]*$' | head -1 | cut -d: -f1)

    if [ -z "$IF_LN" ] || [ -z "$ELSE_LN" ] || [ -z "$FI_LN" ]; then
      bad "could not slice the SEC_RC if/else branches -- the call site's shape changed"
    else
      NO_VERDICT_BRANCH=$(printf '%s\n' "$BLOCK" | sed -n "$((IF_LN + 1)),$((IF_LN + ELSE_LN - 2))p")
      MATERIAL_BRANCH=$(printf '%s\n' "$BLOCK" | sed -n "$((IF_LN + ELSE_LN)),$((IF_LN + FI_LN - 2))p")

      _branch_records() {   # <branch text> <expected kind>
        printf '%s\n' "$1" | grep -q 'agent-block\.sh' \
          && printf '%s\n' "$1" | grep -qE "\" $2\$"
      }

      if _branch_records "$NO_VERDICT_BRANCH" transient; then
        ok "the no-verdict branch calls agent-block.sh with a 'transient' probe"
      else
        bad "the no-verdict branch does not record a 'transient' probe -- will read UNPROBED forever"
      fi

      if _branch_records "$MATERIAL_BRANCH" operator; then
        ok "the material-finding branch calls agent-block.sh with an 'operator' probe"
      else
        bad "the material-finding branch does not record an 'operator' probe -- will read UNPROBED forever"
      fi
    fi

    # Regression guard on the OLD call shape: pre-igor#555 this block called
    # agent-block.sh with no trailing probe-kind argument at all. Counting
    # calls against probe-kind terminators proves no unprobed call survives
    # anywhere in the block, without depending on any reason wording.
    N_CALLS=$(printf '%s\n' "$BLOCK" | grep -c 'agent-block\.sh')
    N_KINDS=$(printf '%s\n' "$BLOCK" | grep -cE '" (transient|operator)$')
    if [ "$N_CALLS" -gt 0 ] && [ "$N_CALLS" -eq "$N_KINDS" ]; then
      ok "every agent-block.sh call in the block records a probe kind ($N_CALLS/$N_CALLS)"
    else
      bad "an unprobed agent-block.sh call survives: $N_CALLS call(s), $N_KINDS probe kind(s)"
    fi
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-security-gate-block-probe: all passed"
else
  echo "test-security-gate-block-probe: $FAIL FAILED"
  exit 1
fi
