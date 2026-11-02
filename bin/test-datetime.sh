#!/usr/bin/env bash
# test-datetime.sh -- unit tests for lib/datetime.sh: yesterday_date, the
# noon-anchored "previous calendar day" helper that replaced the
# now-relative `date -d yesterday` / `date -d '-1 days'` call sites that
# broke on the DST fall-back day (igor#34).
#
# Fakes "now" by shimming the bare `date +%F` call yesterday_date makes to
# find today's date -- everything else (the `-d ... yesterday` arithmetic)
# runs through the real `date` binary under a fixed TZ, so the test
# exercises the actual DST-sensitive computation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/datetime.sh
. "$HERE/lib/datetime.sh"
# shellcheck source=../lib/testlib.sh
. "$HERE/lib/testlib.sh"

export TZ=America/Chicago

FAIL=0

MOCK_TODAY=""
date() {
  if [ "$1" = "+%F" ] && [ "$#" -eq 1 ] && [ -n "$MOCK_TODAY" ]; then
    printf '%s\n' "$MOCK_TODAY"
  else
    command date "$@"
  fi
}

echo "== yesterday_date: DST fall-back day (2026-11-01 is 25 hours long) =="
MOCK_TODAY="2026-11-01"
eq "the day of fall-back resolves to the day before, not itself" "2026-10-31" "$(yesterday_date)"

echo "== yesterday_date: the day after fall-back =="
MOCK_TODAY="2026-11-02"
eq "resolves to fall-back day itself" "2026-11-01" "$(yesterday_date)"

echo "== yesterday_date: DST spring-forward day (2026-03-08 is 23 hours long) =="
MOCK_TODAY="2026-03-08"
eq "resolves to the day before" "2026-03-07" "$(yesterday_date)"

echo "== yesterday_date: an ordinary day =="
MOCK_TODAY="2026-06-15"
eq "resolves to the day before" "2026-06-14" "$(yesterday_date)"

unset -f date

if [ "$FAIL" -eq 0 ]; then
  echo "test-datetime: all checks passed"
else
  echo "test-datetime: $FAIL check(s) failed"
  exit 1
fi
