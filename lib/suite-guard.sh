#!/usr/bin/env bash
# suite-guard.sh -- catch a bin/test-*.sh suite that PASSED without running
# all of its assertions.
#
# Every suite in bin/ runs under `set -uo pipefail` -- deliberately without
# `-e`, since the assertions themselves invoke failing commands on purpose --
# and reports its verdict from a FAIL counter that each assertion helper
# increments. That combination has a hole: a line that never executes cannot
# increment the counter, so a mistyped helper name is a SKIPPED assertion the
# suite still reports as a pass.
#
# Observed for real (igor#430): three assertions written as `has ...` in
# bin/test-forgejo.sh, which defines only `eq`, died as `has: command not
# found` on stderr while the suite printed "all checks passed" and exited 0.
# The runner only checked the exit code, so CI was green on a suite that had
# silently skipped a third of the block it was added for.
#
# This is a runner-level guard, not a per-suite one, so it covers every
# existing suite and every future one without touching any of them.
#
# Requires bash; sourced by bin/check-sync.sh.

# Patterns that mean "the shell reported a line it could not run". Anchored to
# the shell's own diagnostic format (`<script>: line N: ...`) so a suite whose
# ASSERTION TEXT merely contains one of these words -- a test named "reports
# command not found", say -- doesn't trip it.
SUITE_GUARD_PATTERNS='line [0-9]+: [^:]*: command not found|line [0-9]+: [^:]*: unbound variable'

# suite_output_skipped <combined-output>
# 0 (true) when the output carries evidence that the shell refused to run one
# of the suite's own lines. The caller treats that as a failure even when the
# suite exited 0.
suite_output_skipped() {
  grep -qE "$SUITE_GUARD_PATTERNS" <<<"$1"
}

# suite_skipped_lines <combined-output>
# The offending diagnostic lines, for the runner to echo so the failure names
# itself instead of just asserting something went wrong.
suite_skipped_lines() {
  grep -E "$SUITE_GUARD_PATTERNS" <<<"$1" || true
}
