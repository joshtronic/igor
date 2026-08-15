#!/usr/bin/env bash
# Unit tests for lib/suite-guard.sh -- the runner-level guard that stops a
# bin/test-*.sh suite from reporting a pass when the shell refused to run one
# of its own lines (igor#430).
#
# The regression this exists for: three assertions in bin/test-forgejo.sh were
# written as `has ...` in a suite that defines only `eq`. They died as
# `has: command not found` on stderr, the FAIL counter was never incremented
# because the lines never ran, and the suite exited 0 -- CI green on a third
# of a block that had silently evaporated.
#
# Fixtures are real bash output captured from real sub-shells, not
# hand-written strings, so the patterns stay pinned to what bash ACTUALLY
# emits rather than to what this file assumes it emits.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/suite-guard.sh
. "$HERE/lib/suite-guard.sh"

FAIL=0
yes_() {  # <desc> <output> -- expect the guard to TRIP
  if suite_output_skipped "$2"; then printf '  + %s\n' "$1"
  else printf '  x %s: guard did not trip on [%s]\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}
no_() {   # <desc> <output> -- expect the guard to stay quiet
  if suite_output_skipped "$2"; then printf '  x %s: guard tripped on [%s]\n' "$1" "$2"; FAIL=$((FAIL + 1))
  else printf '  + %s\n' "$1"; fi
}

echo "== the igor#430 case: a typo'd helper in a set -uo pipefail suite =="
# Exactly the shape of a real suite: no -e, verdict from a FAIL counter, and
# one assertion calling a helper that was never defined.
TYPO_OUT=$(bash -c '
  set -uo pipefail
  FAIL=0
  eq() { if [ "$2" = "$3" ]; then printf "  + %s\n" "$1"; else FAIL=$((FAIL+1)); fi; }
  eq "a real assertion" "x" "x"
  has "the typo one" "haystack" "needle"
  if [ "$FAIL" -eq 0 ]; then echo "all checks passed"; exit 0; fi
  exit 1' 2>&1)
TYPO_RC=$?
yes_ "guard trips on the missing helper" "$TYPO_OUT"
if [ "$TYPO_RC" -eq 0 ]; then
  printf '  + %s\n' "fixture reproduces the hole: suite exited 0 despite the skipped line"
else
  printf '  x %s: fixture exited %s, expected 0 -- the hole is not reproduced\n' "premise" "$TYPO_RC"
  FAIL=$((FAIL + 1))
fi
case "$TYPO_OUT" in
  *"all checks passed"*) printf '  + %s\n' "fixture even printed its success banner" ;;
  *) printf '  x %s\n' "fixture did not print the banner"; FAIL=$((FAIL + 1)) ;;
esac

echo "== unbound variable under set -u is the same class of skip =="
UNBOUND_OUT=$(bash -c 'set -uo pipefail; echo start; printf "%s" "$NOPE_NOT_SET"; echo end' 2>&1)
yes_ "guard trips on an unbound variable" "$UNBOUND_OUT"

echo "== a clean suite is left alone =="
CLEAN_OUT=$(bash -c '
  set -uo pipefail
  echo "  + one"
  echo "  + two"
  echo "test-clean: all checks passed"' 2>&1)
no_ "clean output does not trip the guard" "$CLEAN_OUT"
no_ "empty output does not trip the guard" ""

echo "== assertion TEXT mentioning the words is not a skip =="
# The guard is anchored to bash's own `<file>: line N: <cmd>: ...` diagnostic
# shape, so a suite that legitimately tests error-message handling stays green.
no_ "a passing assertion whose description says 'command not found'" \
  "  + surfaces 'command not found' to the caller"
no_ "a fixture echoing the phrase as data" \
  "  + stderr was: command not found"
no_ "a description mentioning an unbound variable" \
  "  + rejects an unbound variable in the template"

echo "== the shared missing-tool skip convention is recognized (igor#523) =="
# Every skip-safe suite's top-of-file guard echoes exactly one line ending
# "-- skipping" and exits 0 before running any assertions -- indistinguishable
# from a real pass by exit code alone. suite_output_skip_reason names it.
SKIP_LINE="test-automerge: jq absent -- skipping"
reason=$(suite_output_skip_reason "$SKIP_LINE")
if [ "$reason" = "$SKIP_LINE" ]; then
  printf '  + %s\n' "recognizes the missing-tool skip line"
else
  printf '  x %s: got [%s]\n' "skip-reason extraction" "$reason"
  FAIL=$((FAIL + 1))
fi
no_reason=$(suite_output_skip_reason "$CLEAN_OUT")
if [ -z "$no_reason" ]; then
  printf '  + %s\n' "a clean pass has no skip reason"
else
  printf '  x %s: got [%s]\n' "clean output falsely read as a skip" "$no_reason"
  FAIL=$((FAIL + 1))
fi

echo "== the reported lines name the offender =="
LINES=$(suite_skipped_lines "$TYPO_OUT")
case "$LINES" in
  *"has: command not found"*) printf '  + %s\n' "skipped-line report names the missing helper" ;;
  *) printf '  x %s: got [%s]\n' "skipped-line report" "$LINES"; FAIL=$((FAIL + 1)) ;;
esac
eq_count=$(printf '%s\n' "$LINES" | grep -c . || true)
if [ "$eq_count" -eq 1 ]; then
  printf '  + %s\n' "reports exactly the one offending line, not the whole output"
else
  printf '  x %s: expected 1 line, got %s\n' "skipped-line count" "$eq_count"
  FAIL=$((FAIL + 1))
fi

echo "== a suite that FAILS is reported, not swallowed =="
# The runner runs under `set -e`, where a bare `out=$(bash "$t")` assignment
# aborts the script the instant a suite exits nonzero -- taking the suite's
# output, the verdict line, and every later suite with it. That is why the
# capture lives in suite_run_report and why this block exists.
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
cat >"$FIXTURES/test-aa-fails.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "fixture-fails: 1 FAILED"
exit 1
EOF
cat >"$FIXTURES/test-zz-passes.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "fixture-passes: all checks passed"
EOF

FAILED_OUT=$(suite_run_report "$FIXTURES/test-aa-fails.sh" 2>&1)
FAILED_RC=$?
if [ "$FAILED_RC" -eq 1 ]; then
  printf '  + %s\n' "a nonzero suite makes suite_run_report return 1"
else
  printf '  x %s: returned %s, expected 1\n' "failing suite" "$FAILED_RC"
  FAIL=$((FAIL + 1))
fi
case "$FAILED_OUT" in
  *"fixture-fails: 1 FAILED"*) printf '  + %s\n' "the failing suite's own output is still printed" ;;
  *) printf '  x %s\n' "failing suite's output was swallowed"; FAIL=$((FAIL + 1)) ;;
esac
case "$FAILED_OUT" in
  *"x $FIXTURES/test-aa-fails.sh failed"*) printf '  + %s\n' "it is reported as 'x <suite> failed'" ;;
  *) printf '  x %s: got [%s]\n' "failing suite verdict" "$FAILED_OUT"; FAIL=$((FAIL + 1)) ;;
esac

# The runner's actual loop, `set -e` and all, over a failing suite followed by
# a passing one. Both the later suite and the post-loop line must survive.
LOOP_OUT=$(bash -c '
  set -euo pipefail
  . "$1/lib/suite-guard.sh"
  loop_fail=0
  for t in "$2"/test-*.sh; do
    suite_run_report "$t" || loop_fail=1
  done
  echo "loop finished loop_fail=$loop_fail"' _ "$HERE" "$FIXTURES" 2>&1)
case "$LOOP_OUT" in
  *"fixture-passes: all checks passed"*"loop finished loop_fail=1"*)
    printf '  + %s\n' "a failing suite does not abort the set -e runner loop" ;;
  *)
    printf '  x %s: got [%s]\n' "runner loop aborted early" "$LOOP_OUT"
    FAIL=$((FAIL + 1)) ;;
esac

echo "== a passing suite still reports a pass =="
PASS_OUT=$(suite_run_report "$FIXTURES/test-zz-passes.sh" 2>&1)
PASS_RC=$?
if [ "$PASS_RC" -eq 0 ]; then
  printf '  + %s\n' "a clean suite returns 0"
else
  printf '  x %s: returned %s, expected 0\n' "passing suite" "$PASS_RC"
  FAIL=$((FAIL + 1))
fi
case "$PASS_OUT" in
  *"+ $FIXTURES/test-zz-passes.sh passed"*) printf '  + %s\n' "it is reported as '+ <suite> passed'" ;;
  *) printf '  x %s: got [%s]\n' "passing suite verdict" "$PASS_OUT"; FAIL=$((FAIL + 1)) ;;
esac

echo "== suite_run_report distinguishes a skip from a pass (igor#523) =="
# A CI runner missing jq must not read a whole class of suites (automerge,
# dossier, forgejo, needsyou, ...) as ordinary passes -- that's exactly how
# the merge machinery's coverage went silently unexecuted.
cat >"$FIXTURES/test-mm-skips.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "test-mm-skips: jq absent -- skipping"
exit 0
EOF
SKIP_OUT=$(suite_run_report "$FIXTURES/test-mm-skips.sh" 2>&1)
SKIP_RC=$?
if [ "$SKIP_RC" -eq 0 ]; then
  printf '  + %s\n' "a skipped suite still returns 0 -- not a CI failure"
else
  printf '  x %s: returned %s, expected 0\n' "skipped suite" "$SKIP_RC"
  FAIL=$((FAIL + 1))
fi
case "$SKIP_OUT" in
  *"! $FIXTURES/test-mm-skips.sh skipped (test-mm-skips: jq absent -- skipping)"*)
    printf '  + %s\n' "it is reported as '! <suite> skipped (<reason>)', not '+ <suite> passed'" ;;
  *)
    printf '  x %s: got [%s]\n' "skipped suite verdict" "$SKIP_OUT"
    FAIL=$((FAIL + 1)) ;;
esac
case "$SKIP_OUT" in
  *"+ $FIXTURES/test-mm-skips.sh passed"*)
    printf '  x %s\n' "a skip must not also be reported as an ordinary pass"
    FAIL=$((FAIL + 1)) ;;
  *) printf '  + %s\n' "not double-reported as a pass" ;;
esac

echo "== a silent suite emits no stray blank line =="
cat >"$FIXTURES/silent.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
SILENT_OUT=$(suite_run_report "$FIXTURES/silent.sh" 2>&1)
silent_lines=$(printf '%s\n' "$SILENT_OUT" | grep -c . || true)
if [ "$silent_lines" -eq 1 ]; then
  printf '  + %s\n' "silent suite prints only its verdict line"
else
  printf '  x %s: expected 1 line, got %s [%s]\n' "silent suite" "$silent_lines" "$SILENT_OUT"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-suite-guard: all checks passed"
else
  echo "test-suite-guard: $FAIL FAILED"
  exit 1
fi
