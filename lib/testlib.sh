#!/usr/bin/env bash
# lib/testlib.sh -- shared eq/has/lacks assertion helpers for bin/test-*.sh
# suites. Sourced, not run.
#
# Before this existed, 21 suites each hand-rolled `has`/`lacks` against `$2`,
# the fixture under test. When a `$(...)` building that fixture came back
# empty (a flaky build, not a feature defect), `has` failed with a misleading
# "[] lacks [needle]" -- read as "the feature is broken" when the truth is
# "the fixture never built" -- and `lacks` PASSED vacuously, since an empty
# haystack trivially lacks everything. Both now report a distinct, greppable
# FIXTURE EMPTY failure instead, so the signature can be told apart from a
# real regression (and, later, auto-retried on).
#
# `eq` gets the same treatment on its "got" side ($3) when the "expected"
# side ($2) is non-empty -- but NOT when $2 is empty, since `eq "d" "" "$(f)"`
# (asserting the real output is empty) is a legitimate, common assertion in
# these suites and must keep passing exactly as before.
#
# Sourcing scripts must set FAIL=0 before the first call.

eq() {
  if [ "$2" = "$3" ]; then
    printf '  + %s\n' "$1"
  elif [ -n "$2" ] && [ -z "$3" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected [%s] got nothing\n' "$1" "$2"
    FAIL=$((FAIL + 1))
  else
    printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

has() {
  if [ -z "$2" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$1" "$3"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$2" in
    *"$3"*) printf '  + %s\n' "$1" ;;
    *) printf '  x %s: [%s] lacks [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;;
  esac
}

lacks() {
  if [ -z "$2" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$1" "$3"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$2" in
    *"$3"*) printf '  x %s: [%s] still has [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;;
    *) printf '  + %s\n' "$1" ;;
  esac
}
