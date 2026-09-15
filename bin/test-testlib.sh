#!/usr/bin/env bash
# test-testlib.sh -- unit tests for lib/testlib.sh's eq/has/lacks (igor#626):
# an empty fixture must fail loudly and distinctly (FIXTURE EMPTY) in all
# three, including `lacks`, which used to pass vacuously on empty input.
# An explicitly empty EXPECTATION in `eq` must stay legal.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"

FAIL=0
PASS=0
# shellcheck source=../lib/testlib.sh
. "$HERE/../lib/testlib.sh"

META_FAIL=0

# check <desc> <fail-before> <pass-before> <want-fail-delta> <want-pass-delta>
# <output-substring-required> [<output-substring-forbidden>]
check() {
  local desc="$1" fb="$2" pb="$3" wf="$4" wp="$5" want="$6" forbid="${7:-}"
  local out; out="$(cat "$OUT")"
  local df=$((FAIL - fb)) dp=$((PASS - pb))
  local ok=1
  [ "$df" -eq "$wf" ] || ok=0
  [ "$dp" -eq "$wp" ] || ok=0
  if [ -n "$want" ]; then case "$out" in *"$want"*) ;; *) ok=0 ;; esac; fi
  if [ -n "$forbid" ]; then case "$out" in *"$forbid"*) ok=0 ;; esac; fi
  if [ "$ok" -eq 1 ]; then
    printf '  + %s\n' "$desc"
  else
    printf '  x %s: FAIL delta=%s (want %s), PASS delta=%s (want %s), output=[%s]\n' \
      "$desc" "$df" "$wf" "$dp" "$wp" "$out"
    META_FAIL=$((META_FAIL + 1))
  fi
}

echo "== eq =="
f=$FAIL; p=$PASS; eq "match" "x" "x" > "$OUT"
check "equal values pass" "$f" "$p" 0 1 "+ match"

f=$FAIL; p=$PASS; eq "mismatch" "x" "y" > "$OUT"
check "different non-empty values fail normally" "$f" "$p" 1 0 "expected [x] got [y]" "FIXTURE EMPTY"

f=$FAIL; p=$PASS; eq "fixture empty" "x" "" > "$OUT"
check "empty actual against non-empty expectation fails distinctly" "$f" "$p" 1 0 "FIXTURE EMPTY"

f=$FAIL; p=$PASS; eq "intentional empty expectation" "" "" > "$OUT"
check "explicit empty expectation stays legal (does not misfire FIXTURE EMPTY)" "$f" "$p" 0 1 "+ intentional" "FIXTURE EMPTY"

echo "== has =="
f=$FAIL; p=$PASS; has "d" "haystack" "hay" > "$OUT"
check "needle present passes" "$f" "$p" 0 1 "+ d"

f=$FAIL; p=$PASS; has "d" "haystack" "zzz" > "$OUT"
check "needle absent fails" "$f" "$p" 1 0 "lacks [zzz]"

f=$FAIL; p=$PASS; has "d" "" "needle" > "$OUT"
check "empty fixture fails distinctly instead of misreporting a broken feature" "$f" "$p" 1 0 "FIXTURE EMPTY"

echo "== lacks =="
f=$FAIL; p=$PASS; lacks "d" "haystack" "zzz" > "$OUT"
check "needle truly absent passes" "$f" "$p" 0 1 "+ d"

f=$FAIL; p=$PASS; lacks "d" "haystack" "hay" > "$OUT"
check "needle present fails" "$f" "$p" 1 0 "still has [hay]"

f=$FAIL; p=$PASS; lacks "d" "" "needle" > "$OUT"
check "empty fixture fails instead of vacuously passing (igor#626)" "$f" "$p" 1 0 "FIXTURE EMPTY"

if [ "$META_FAIL" -eq 0 ]; then
  echo "test-testlib: all checks passed"
  exit 0
else
  echo "test-testlib: $META_FAIL check(s) FAILED"
  exit 1
fi
