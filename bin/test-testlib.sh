#!/usr/bin/env bash
# test-testlib.sh -- unit tests for lib/testlib.sh: the shared eq/has/lacks
# assertion helpers (igor#626). Guards the one behavior change that matters:
# a fixture that comes back empty must fail loudly and distinctly in all
# three, including lacks, which used to pass vacuously on an empty haystack.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/testlib.sh
. "$HERE/../lib/testlib.sh"

FAIL=0
eq_meta()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has_meta() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== eq: ordinary equality is unchanged =="
OUT="$(eq "equal strings pass" "same" "same")"
has_meta "pass line printed" "$OUT" "+ equal strings pass"
OUT="$(eq "different strings fail" "foo" "bar")"
has_meta "fail line names expected and got" "$OUT" "expected [foo] got [bar]"

echo "== eq: an explicitly empty EXPECTATION stays legal (deliverable 3) =="
OUT="$(eq "empty expectation, empty actual -> pass" "" "")"
has_meta "passes, no FIXTURE EMPTY" "$OUT" "+ empty expectation, empty actual -> pass"
case "$(eq "x" "" "")" in
  *"FIXTURE EMPTY"*) printf '  x empty-expectation case must not mention FIXTURE EMPTY\n'; FAIL=$((FAIL + 1)) ;;
  *) printf '  + empty-expectation case stays a plain pass\n' ;;
esac

echo "== eq: an empty FIXTURE against a non-empty expectation is a distinct failure =="
OUT="$(eq "fixture never built" "needle" "")"
has_meta "reports FIXTURE EMPTY" "$OUT" "FIXTURE EMPTY"
has_meta "names the expected value" "$OUT" "needle"
case "$OUT" in
  *"+ "*) printf '  x an empty fixture against a non-empty expectation must not pass\n'; FAIL=$((FAIL + 1)) ;;
  *) printf '  + empty fixture against non-empty expectation fails\n' ;;
esac

echo "== has: ordinary substring match is unchanged =="
OUT="$(has "finds the needle" "haystack with needle in it" "needle")"
has_meta "pass line printed" "$OUT" "+ finds the needle"
OUT="$(has "missing needle fails" "haystack" "needle")"
has_meta "fail line names haystack and needle" "$OUT" "lacks [needle]"

echo "== has: an empty fixture is a distinct, loud failure (not read as 'missing') =="
OUT="$(has "fixture never built" "" "needle")"
has_meta "reports FIXTURE EMPTY" "$OUT" "FIXTURE EMPTY"
has_meta "names the needle it expected to find" "$OUT" "needle"

echo "== lacks: ordinary negated substring match is unchanged =="
OUT="$(lacks "needle truly absent" "haystack" "needle")"
has_meta "pass line printed" "$OUT" "+ needle truly absent"
OUT="$(lacks "needle present fails" "haystack with needle" "needle")"
has_meta "fail line says still has" "$OUT" "still has [needle]"

echo "== lacks: an empty fixture must FAIL, not pass vacuously (the core bug) =="
OUT="$(lacks "fixture never built" "" "needle")"
has_meta "reports FIXTURE EMPTY" "$OUT" "FIXTURE EMPTY"
case "$OUT" in
  *"+ "*) printf '  x lacks must not pass vacuously on an empty fixture\n'; FAIL=$((FAIL + 1)) ;;
  *) printf '  + lacks on an empty fixture fails instead of passing vacuously\n' ;;
esac

if [ "$FAIL" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '\nall assertions passed\n'
