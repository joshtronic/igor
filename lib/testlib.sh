#!/usr/bin/env bash
# lib/testlib.sh -- shared eq/has/lacks assertion helpers for bin/test-*.sh.
#
# Before this existed, 24 suites each pasted their own copy. All three
# shared one bug: when the fixture ($2 for has/lacks, $3 for eq) came back
# empty -- a flaky `$(...)` that built it returning nothing -- the suite
# misreported the cause. `has` failed with "[] lacks [needle]", reading as
# a broken feature when the fixture never built. `lacks` PASSED, vacuously:
# an empty haystack contains nothing, so every `lacks` assertion against a
# dead fixture silently succeeds (igor#626).
#
# These versions treat an empty fixture as a distinct, loud failure in all
# three, tagged FIXTURE EMPTY so it's greppable and can never again be
# misread as a feature defect. An explicitly empty EXPECTATION in `eq`
# (asserting a command legitimately returns "") stays legal: the fixture-
# empty check only fires when the actual/got side is empty AND a non-empty
# value was expected.
#
# Callers must have FAIL=0 (and, if they report a pass count, PASS=0)
# declared before sourcing this -- these functions increment both.
: "${FAIL:=0}"
: "${PASS:=0}"

eq() {
  local d="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1)); printf '  + %s\n' "$d"
  elif [ -z "$got" ] && [ -n "$want" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected [%s] got nothing\n' "$d" "$want"
    FAIL=$((FAIL + 1))
  else
    printf '  x %s: expected [%s] got [%s]\n' "$d" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

has() {
  local d="$1" hay="$2" needle="$3"
  if [ -z "$hay" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$d" "$needle"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$hay" in
    *"$needle"*) PASS=$((PASS + 1)); printf '  + %s\n' "$d" ;;
    *) printf '  x %s: [%s] lacks [%s]\n' "$d" "${hay:0:200}" "$needle"; FAIL=$((FAIL + 1)) ;;
  esac
}

lacks() {
  local d="$1" hay="$2" needle="$3"
  if [ -z "$hay" ]; then
    printf '  x %s: FIXTURE EMPTY -- expected to contain [%s]\n' "$d" "$needle"
    FAIL=$((FAIL + 1))
    return
  fi
  case "$hay" in
    *"$needle"*) printf '  x %s: [%s] still has [%s]\n' "$d" "${hay:0:200}" "$needle"; FAIL=$((FAIL + 1)) ;;
    *) PASS=$((PASS + 1)); printf '  + %s\n' "$d" ;;
  esac
}
