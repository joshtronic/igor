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

if [ "$FAIL" -eq 0 ]; then
  echo "test-suite-guard: all checks passed"
else
  echo "test-suite-guard: $FAIL FAILED"
  exit 1
fi
