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
#
# Deliberately narrow: these two are the diagnostics a MISWRITTEN ASSERTION
# produces (a helper name that doesn't exist, a variable the suite forgot to
# set). Other "this line didn't run" diagnostics -- `syntax error near
# unexpected token`, `No such file or directory`, `Permission denied`, `bad
# substitution` -- are left out because they usually also break the suite's
# exit code, which the runner already catches. Extend the alternation if one
# of them ever shows up as a silent pass.
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

# suite_run_report <suite-path>
# Run one suite, echo its output verbatim, then a verdict line. Returns 0 when
# the suite passed, 1 when it failed or skipped an assertion.
#
# The capture is `|| rc=$?`, never a bare assignment: the runner sources this
# under `set -e`, where a plain `out=$(bash "$suite")` takes the substitution's
# exit status and aborts the whole script the moment a suite fails -- throwing
# away that suite's output, its verdict line, and every suite after it. The
# old inline `if bash "$t"; then` was exempt only because it sat in a
# condition context.
#
# Lives here rather than inline in the runner's loop so that failure path is
# unit-testable; bin/test-suite-guard.sh drives it with real fixture suites.
# Note the output is buffered until the suite finishes (no incremental
# feedback on a long suite) and its stderr is folded into stdout -- the price
# of being able to inspect it.
suite_run_report() {
  local suite=$1 out rc=0
  out=$(bash "$suite" 2>&1) || rc=$?
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "x $suite failed"
    return 1
  fi
  if suite_output_skipped "$out"; then
    # Exit 0 is not enough: these suites verdict on a FAIL counter, and a line
    # the shell refused to run never increments it (igor#430).
    echo "x $suite exited 0 but the shell refused to run one of its lines --"
    echo "  a skipped assertion cannot fail, so this is NOT a pass:"
    suite_skipped_lines "$out" | sed 's/^/    /'
    return 1
  fi
  echo "+ $suite passed"
}
