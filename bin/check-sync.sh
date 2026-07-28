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

# -- Cascade stages ---------------------------------------------
#
# cascade_run dispatches each name in CASCADE_STAGES as `do_<stage>_tick`. A
# typo exits 127, which the gate reads as "this stage did no work" -- so the
# stage is silently never run AND, because cascade_run stamped it as reached,
# silently never starved either. Two things can drift: a name with no matching
# function, and the literal `cascade_run <stage>` gates falling out of step
# with the list they are supposed to enumerate.

cascade_stages=$(sed -n 's/^CASCADE_STAGES="\([^"]*\)".*/\1/p' bin/tick.sh | head -1)
if [ -z "$cascade_stages" ]; then
  echo "x CASCADE_STAGES not found in bin/tick.sh"
  FAIL=1
else
  for stage in $cascade_stages; do
    if grep -qE "^do_${stage}_tick\(\)" bin/tick.sh lib/*.sh; then
      echo "+ cascade stage '$stage' -> do_${stage}_tick"
    else
      echo "x cascade stage '$stage' has no do_${stage}_tick function"
      FAIL=1
    fi
  done

  cascade_calls=$(grep -oE '^if cascade_run [a-z]+' bin/tick.sh | awk '{print $3}' | sort -u)
  if [ "$cascade_calls" != "$(echo "$cascade_stages" | tr ' ' '\n' | sort -u)" ]; then
    echo "x CASCADE_STAGES and the cascade_run gates diverge"
    diff <(echo "$cascade_stages" | tr ' ' '\n' | sort -u) <(echo "$cascade_calls") | sed 's/^/    /'
    FAIL=1
  fi
fi

# -- Unit tests -------------------------------------------------

for t in bin/test-*.sh; do
  [ -f "$t" ] || continue   # no matches -> the literal glob; skip it
  # Runs the suite, echoes its output verbatim, and applies the skipped-
  # assertion guard. Must stay in a condition context -- under `set -e` a bare
  # call would abort the loop on the first failing suite.
  suite_run_report "$t" || FAIL=1
done

exit $FAIL
