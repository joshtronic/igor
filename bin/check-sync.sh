#!/usr/bin/env bash
# check-sync.sh -- Verify the AGENTS.md <-> tick.sh contract is in sync, then
# run the repo's shell-function unit tests.
#
# Catches:
#  1. Outcome sets diverge -- a branch in tick.sh marked with
#     `# OUTCOME: <label>` must have a matching `<!-- OUTCOME: <label> -->`
#     in AGENTS.md, and vice versa.
#  2. Helper scripts referenced in AGENTS.md (anything matching
#     `agent-*.sh`) must exist and be executable in `bin/`.
#  3. Any bin/test-*.sh unit tests fail (each is self-contained and
#     skip-safe -- a missing tool exits 0 -- so this stays the single CI gate).
#
# Exits 0 on success, 1 on any mismatch or test failure. Run by
# .forgejo/workflows/lint.yml on every PR and push.

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AGENT_HOME"

# shellcheck source=../lib/suite-guard.sh
. "$AGENT_HOME/lib/suite-guard.sh"

FAIL=0

# -- Outcome sentinels ------------------------------------------

tick_outcomes=$(grep -oE '# OUTCOME: [a-z-]+'   bin/tick.sh 2>/dev/null \
                | awk '{print $3}' | sort -u)
agents_outcomes=$(grep -oE 'OUTCOME: [a-z-]+ ' AGENTS.md   2>/dev/null \
                | awk '{print $2}' | sort -u)

if [ -z "$tick_outcomes" ]; then
  echo "x no OUTCOME sentinels found in bin/tick.sh"
  FAIL=1
fi
if [ -z "$agents_outcomes" ]; then
  echo "x no OUTCOME sentinels found in AGENTS.md"
  FAIL=1
fi

if [ -n "$tick_outcomes" ] && [ -n "$agents_outcomes" ]; then
  if [ "$tick_outcomes" != "$agents_outcomes" ]; then
    echo "x outcome sets diverge"
    echo "  bin/tick.sh: $(echo "$tick_outcomes" | tr '\n' ' ')"
    echo "  AGENTS.md:   $(echo "$agents_outcomes" | tr '\n' ' ')"
    diff <(echo "$tick_outcomes") <(echo "$agents_outcomes") | sed 's/^/    /'
    FAIL=1
  else
    echo "+ outcomes match: $(echo "$tick_outcomes" | tr '\n' ' ')"
  fi
fi

# -- Referenced helpers -----------------------------------------

helpers=$(grep -oE 'agent-[a-z-]+\.sh' AGENTS.md 2>/dev/null | sort -u || true)
for h in $helpers; do
  if [ ! -f "bin/$h" ]; then
    echo "x AGENTS.md references bin/$h but it does not exist"
    FAIL=1
  elif [ ! -x "bin/$h" ]; then
    echo "x bin/$h exists but is not executable"
    FAIL=1
  else
    echo "+ bin/$h exists and is executable"
  fi
done

# -- Unit tests -------------------------------------------------

for t in bin/test-*.sh; do
  [ -f "$t" ] || continue   # no matches -> the literal glob; skip it
  # Captured rather than streamed so the guard below can inspect it; echoed
  # verbatim either way, so nothing is hidden by capturing.
  suite_out=$(bash "$t" 2>&1)
  suite_rc=$?
  printf '%s\n' "$suite_out"
  if [ "$suite_rc" -ne 0 ]; then
    echo "x $t failed"
    FAIL=1
  elif suite_output_skipped "$suite_out"; then
    # Exit 0 is not enough: these suites verdict on a FAIL counter, and a line
    # the shell refused to run never increments it (igor#430).
    echo "x $t exited 0 but the shell refused to run one of its lines --"
    echo "  a skipped assertion cannot fail, so this is NOT a pass:"
    suite_skipped_lines "$suite_out" | sed 's/^/    /'
    FAIL=1
  else
    echo "+ $t passed"
  fi
done

exit $FAIL
