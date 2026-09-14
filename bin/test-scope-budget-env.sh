#!/usr/bin/env bash
# test-scope-budget-env.sh -- source-assertion (igor#608): every prompt in
# bin/tick.sh that tells the agent to run bin/scope-budget.sh must be built
# on a path where the vars that helper hard-requires are already EXPORTED.
#
# scope-budget.sh guards its inputs with `: "${VAR:?...}"`, so an unexported
# var doesn't degrade -- the helper aborts the first time the agent runs it,
# on a name the prompt advertised. The issue-work path exports PR_BASE at its
# claim; the PR-review rework path set it as a plain shell var, so the
# rework prompt pointed at a helper that could never run there.
#
# Doesn't run tick.sh -- just greps it, in the spirit of check-sync.sh's
# OUTCOME-sentinel checks and test-heartbeat-before-security-gate.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"
HELPER="$HERE/bin/scope-budget.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== every prompt advertising scope-budget.sh exports what it requires =="

REQUIRED=$(grep -oE ': "\$\{[A-Z_]+:\?' "$HELPER" | grep -oE '[A-Z_]+')
if [ -z "$REQUIRED" ]; then
  bad "no \`: \${VAR:?}\` guards found in bin/scope-budget.sh (expected at least AGENT_HOME + PR_BASE)"
fi

# A comment naming the path isn't a dispatch site -- nothing dereferences a
# comment (test-retired-directives.sh narrows its reader grep the same way).
SITES=$(grep -n 'scope-budget\.sh' "$TICK" | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
if [ -z "$SITES" ]; then
  bad "no prompt in bin/tick.sh mentions scope-budget.sh (expected the issue-work + rework notes)"
fi

for ln in $SITES; do
  for var in $REQUIRED; do
    # An export at a LOWER line number than the prompt: same dispatch path,
    # already in the child's environment by the time the agent reads the note.
    if grep -nE "^[[:space:]]*export ([A-Z_]+ )*${var}\b" "$TICK" \
      | cut -d: -f1 | awk -v limit="$ln" '$1 < limit { found = 1 } END { exit !found }'; then
      ok "line $ln: $var exported earlier in bin/tick.sh"
    else
      bad "line $ln: prompt advertises scope-budget.sh but $var is never exported before it"
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "test-scope-budget-env: all passed"
else
  echo "test-scope-budget-env: $FAIL FAILED"
  exit 1
fi
