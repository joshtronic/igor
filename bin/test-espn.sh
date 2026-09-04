#!/usr/bin/env bash
# test-espn.sh -- unit tests for lib/espn.sh's fetch wrappers. No
# network: request_get is doubled as a shell function (lib/request.sh is
# never sourced), so these assert the URL espn.sh builds and how it
# handles a fetch failure, not HTTP behavior -- bin/test-request.sh owns
# that half.
# Skip-safe: needs jq and mktemp; exits 0 with a notice if either is absent.
set -uo pipefail

for tool in jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test-espn: $tool absent -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"

URL_LOG=$(mktemp)
trap 'rm -f "$URL_LOG"' EXIT

# shellcheck source=../lib/espn.sh
. "$HERE/../lib/espn.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# -- request_get double ------------------------------------------------
# Logs every URL it is handed to a FILE: espn_scoreboard's stdout is
# captured via $(...), which forks the call into a subshell where a plain
# variable would not survive.
REQUEST_RC=0
REQUEST_BODY='{"events":[]}'
request_get() {
  printf '%s\n' "$1" >>"$URL_LOG"
  [ "$REQUEST_RC" != "0" ] && return "$REQUEST_RC"
  printf '%s' "$REQUEST_BODY"
}
urls() { cat "$URL_LOG"; }
reset_mock() { : >"$URL_LOG"; REQUEST_RC=0; REQUEST_BODY='{"events":[]}'; }

# shellcheck disable=SC2034  # read by espn_scoreboard/espn_news (lib/espn.sh)
ESPN_BASE_URL="https://espn.test/sports"

echo "== espn_scoreboard: builds the dated scoreboard URL =="
reset_mock
REQUEST_BODY='{"events":[{"name":"A"}]}'
OUT=$(espn_scoreboard "football/nfl" "20260903")
eq "returns the payload verbatim" '{"events":[{"name":"A"}]}' "$OUT"
eq "URL carries league and date" \
  "https://espn.test/sports/football/nfl/scoreboard?dates=20260903" "$(urls)"

echo "== espn_scoreboard: a non-digit date is rejected without a fetch =="
# The URL is built by interpolation, not curl --data-urlencode, so the
# digits-only invariant has to be enforced rather than assumed.
for bad in "2026-09-03" "2026090" "202609031" "" "20260903&limit=1" "../../news"; do
  reset_mock
  OUT=$(espn_scoreboard "football/nfl" "$bad")
  RC=$?
  eq "rc=1 for [$bad]" "1" "$RC"
  eq "empty events for [$bad]" '{"events":[]}' "$OUT"
  eq "no fetch attempted for [$bad]" "" "$(urls)"
done

echo "== espn_scoreboard: an empty league is rejected without a fetch =="
reset_mock
OUT=$(espn_scoreboard "" "20260903")
eq "rc=1" "1" "$?"
eq "empty events" '{"events":[]}' "$OUT"
eq "no fetch attempted" "" "$(urls)"

echo "== espn_scoreboard: a failed fetch degrades to empty events =="
reset_mock
REQUEST_RC=7
OUT=$(espn_scoreboard "football/nfl" "20260903")
eq "rc=1" "1" "$?"
eq "empty events" '{"events":[]}' "$OUT"

echo "== espn_scoreboard: a non-JSON body degrades to empty events =="
reset_mock
REQUEST_BODY='<html>maintenance</html>'
OUT=$(espn_scoreboard "football/nfl" "20260903" 2>/dev/null)
eq "rc=1" "1" "$?"
eq "empty events" '{"events":[]}' "$OUT"

echo "== espn_news: builds the news URL =="
reset_mock
REQUEST_BODY='{"articles":[{"headline":"H"}]}'
OUT=$(espn_news "hockey/nhl")
eq "returns the payload verbatim" '{"articles":[{"headline":"H"}]}' "$OUT"
eq "URL carries the league" "https://espn.test/sports/hockey/nhl/news" "$(urls)"

echo "== espn_news: an empty league is rejected without a fetch =="
reset_mock
OUT=$(espn_news "")
eq "rc=1" "1" "$?"
eq "empty articles" '{"articles":[]}' "$OUT"
eq "no fetch attempted" "" "$(urls)"

echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "test-espn: all checks passed"
  exit 0
else
  echo "test-espn: $FAIL check(s) failed"
  exit 1
fi
