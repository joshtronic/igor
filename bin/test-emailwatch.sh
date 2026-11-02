#!/usr/bin/env bash
# test-emailwatch.sh -- unit tests for lib/emailwatch.sh: the day-gate,
# dynamic surface enumeration off discretionary-state.json, and the pure
# ok/no-evidence/not-run verdict (igor#636). The Forgejo alarm-filing glue
# (do_emailwatch_tick) lives in bin/tick.sh and isn't exercised here -- see
# the docstring on emailwatch_verdict for why the split matters: this file
# proves the DECISION is right off fixtures, with no network and no journal.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-emailwatch: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/datetime.sh
. "$HERE/../lib/datetime.sh"
# shellcheck source=../lib/emailwatch.sh
. "$HERE/../lib/emailwatch.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"
SF="$TMP/discretionary-state.json"

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }

echo "== emailwatch_window_day: yesterday, not today =="
YEST=$(yesterday_date)
eq "window day is yesterday" "$YEST" "$(emailwatch_window_day)"

echo "== emailwatch_window_day: survives the DST fall-back day (igor#34) =="
# date -d '-1 days' means now-minus-24h, which lands back on the fall-back
# day itself when it's run late in the evening of the 25-hour day. Fake the
# bare `date +%F` call yesterday_date makes to find "today," so the real
# -d-based subtraction runs for each scenario under a fixed TZ.
export TZ=America/Chicago
MOCK_TODAY=""
date() {
  if [ "$1" = "+%F" ] && [ "$#" -eq 1 ] && [ -n "$MOCK_TODAY" ]; then
    printf '%s\n' "$MOCK_TODAY"
  else
    command date "$@"
  fi
}
MOCK_TODAY="2026-11-01"
eq "2026-11-01 (25h fall-back day) resolves to the day before, not itself" \
  "2026-10-31" "$(emailwatch_window_day)"
MOCK_TODAY="2026-11-02"
eq "the day after fall-back resolves to fall-back day itself" \
  "2026-11-01" "$(emailwatch_window_day)"
MOCK_TODAY="2026-03-08"
eq "2026-03-08 (23h spring-forward day) resolves to the day before" \
  "2026-03-07" "$(emailwatch_window_day)"
MOCK_TODAY="2026-06-15"
eq "an ordinary day resolves to the day before" \
  "2026-06-14" "$(emailwatch_window_day)"
unset -f date

echo "== done-today round trip (mirrors logwatch's day-stamp) =="
rm -f "$SF"
no "fresh state -> not done" emailwatch_done_today
emailwatch_mark_done
ok "after mark -> done" emailwatch_done_today
eq "stamped with the window day, not today's date" "$YEST" "$(jq -r '.emailwatch.day' "$SF")"

echo "== emailwatch_mark_done merges, never wipes unrelated state =="
echo '{"shipreport":{"date":"'"$YEST"'","sent":true},"other":"keepme"}' > "$SF"
emailwatch_mark_done
eq "sibling key survives" "keepme" "$(jq -r '.other' "$SF")"
eq "shipreport key survives" "true" "$(jq -r '.shipreport.sent' "$SF")"

echo "== emailwatch_surfaces: dynamic day+sent enumeration, not a hardcoded list =="
cat > "$SF" <<EOF
{
  "shipreport": {"date": "$YEST", "sent": true, "failures": 0},
  "sports": {"date": "$YEST", "sent": false, "failures": 2},
  "market": {"date": "2026-06-29", "sent": true},
  "logwatch": {"day": "$YEST"},
  "health": {"kind": "auth"},
  "cascade": {"tick": 5}
}
EOF
eq "finds every day+sent-shaped surface, sorted, nothing else" \
  "market
shipreport
sports" "$(emailwatch_surfaces)"

echo "== emailwatch_surfaces: missing state file -> empty, not a crash =="
rm -f "$SF"
eq "no state file -> empty enumeration" "" "$(emailwatch_surfaces)"

echo "== emailwatch_surface_date / emailwatch_surface_sent =="
cat > "$SF" <<EOF
{"shipreport": {"date": "$YEST", "sent": true}}
EOF
eq "date getter" "$YEST" "$(emailwatch_surface_date shipreport)"
eq "sent getter" "true" "$(emailwatch_surface_sent shipreport)"
eq "missing surface -> empty date" "" "$(emailwatch_surface_date nosuch)"
eq "missing surface -> false sent" "false" "$(emailwatch_surface_sent nosuch)"

echo "== emailwatch_verdict: pure decision, no IO =="
# This IS the 2026-09-14 case: sent=true, the day matches, but the journal
# carries no line either success pattern matches. Must alarm.
eq "sent:true, no matching success line -> no-evidence (the E2BIG case)" "no-evidence" \
  "$(emailwatch_verdict true "$YEST" "$YEST" "Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: WARN comment fetch failed for a/b#1" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "genuine send: stamp + success line -> ok" "ok" \
  "$(emailwatch_verdict true "$YEST" "$YEST" "Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: sent (2 shipped, 0 needs-you, 1 in-flight, 0 landed, 0 judgment item(s)) to a@b.com" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "a genuinely quiet day is also ok, not just an explicit send" "ok" \
  "$(emailwatch_verdict true "$YEST" "$YEST" "Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: quiet 24h -- nothing to report (stamping done)" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "date doesn't match the window -> not-run (stale/frozen stamp)" "not-run" \
  "$(emailwatch_verdict true "2026-06-29" "$YEST" "" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "no date at all (stamp removed entirely) -> not-run" "not-run" \
  "$(emailwatch_verdict false "" "$YEST" "" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "date matches but sent is false -> not-run (attempted, never completed)" "not-run" \
  "$(emailwatch_verdict false "$YEST" "$YEST" "Sep 14 07:03:01 h tick.sh[1]: [agent] shipreport: WARN judgment merge failed" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "an unrelated journal line never satisfies the pattern" "no-evidence" \
  "$(emailwatch_verdict true "$YEST" "$YEST" "Sep 14 03:00:01 h tick.sh[1]: [agent] sports: emailed digest for 2026-09-13 (2 new concepts) to a@b.com" 'shipreport: sent \(' 'shipreport: quiet 24h')"

echo "== emailwatch_verdict: the stamp has moved on to today, but the window day's own journal evidence still backs it (igor#644) =="
# This is the igor#641/#642 false alarm exactly: by the time this check
# runs, today's send has already overwritten the single-slot stamp, so
# stamp_date != window_day. The journal for the window day still has the
# success line and must win -- the stamp's silence on a day it no longer
# describes must never veto real evidence.
TODAY=$(date +%F)
eq "stamp has moved on to today, journal for the window day matches -> ok" "ok" \
  "$(emailwatch_verdict true "$TODAY" "$YEST" "Sep 13 07:01:00 h tick.sh[1]: [agent] shipreport: sent (21 shipped, 0 needs-you, 5 in-flight, 2 landed) to josh@example.com" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "a genuinely missed day: stamp moved on AND journal silent -> not-run" "not-run" \
  "$(emailwatch_verdict true "$TODAY" "$YEST" "" 'shipreport: sent \(' 'shipreport: quiet 24h')"

eq "a lying stamp still alarms: stamp covers the window day, journal silent -> no-evidence" "no-evidence" \
  "$(emailwatch_verdict true "$YEST" "$YEST" "" 'shipreport: sent \(' 'shipreport: quiet 24h')"

if [ "$FAIL" -eq 0 ]; then
  echo "test-emailwatch: all checks passed"
else
  echo "test-emailwatch: $FAIL FAILED"
  exit 1
fi
