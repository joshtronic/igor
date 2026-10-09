#!/usr/bin/env bash
# testlib.sh -- shared eq/has/lacks assertion helpers for bin/test-*.sh
# (igor#626).
#
# A fixture built via a $(...) that comes back empty used to be misread as
# a broken feature by `has` (the real symptom) and, worse, as nothing at
# all by `lacks` -- an empty haystack contains no needle, so lacks passed
# vacuously and could mask a real regression. Both now fail loudly and
# distinctly, naming the cause instead of the symptom, so the failure is
# greppable and never confused with a feature defect. An explicitly empty
# EXPECTATION in eq (`eq "desc" "" "$(f)"`) stays legal -- only an empty
# fixture where content was required is the error.
#
# Callers declare FAIL=0 before sourcing; these increment the caller's
# global on failure, matching the inline convention this file replaces.

eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ -n "$expected" ] && [ -z "$actual" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected [%s], got nothing\n' "$desc" "$expected"
    FAIL=$((FAIL + 1))
  elif [ "$expected" = "$actual" ]; then
    printf '  + %s\n' "$desc"
  else
    printf '  x %s: expected [%s] got [%s]\n' "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

has() {
  local desc="$1" haystack="$2" needle="$3"
  if [ -z "$haystack" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$desc" "$needle"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$haystack" in
    *"$needle"*) printf '  + %s\n' "$desc" ;;
    *) printf '  x %s: [%s] lacks [%s]\n' "$desc" "${haystack:0:200}" "$needle"; FAIL=$((FAIL + 1)) ;;
  esac
}

lacks() {
  local desc="$1" haystack="$2" needle="$3"
  if [ -z "$haystack" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$desc" "$needle"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$haystack" in
    *"$needle"*) printf '  x %s: [%s] still has [%s]\n' "$desc" "${haystack:0:200}" "$needle"; FAIL=$((FAIL + 1)) ;;
    *) printf '  + %s\n' "$desc" ;;
  esac
}
