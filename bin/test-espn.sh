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
# URL substring whose fetch fails, so a caller that falls back from one
# path to another can be exercised without failing both.
REQUEST_FAIL_MATCH=''
request_get() {
  printf '%s\n' "$1" >>"$URL_LOG"
  [ "$REQUEST_RC" != "0" ] && return "$REQUEST_RC"
  [ -n "$REQUEST_FAIL_MATCH" ] && [[ "$1" == *"$REQUEST_FAIL_MATCH"* ]] && return 1
  printf '%s' "$REQUEST_BODY"
}
urls() { cat "$URL_LOG"; }
reset_mock() { : >"$URL_LOG"; REQUEST_RC=0; REQUEST_BODY='{"events":[]}'; REQUEST_FAIL_MATCH=''; }

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

echo "== espn_team_schedule: reduces a team payload to the documented shape, with caps applied =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [{
    name: "Angels at Athletics",
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{
      notes: [{headline: "Doubleheader Game 1"}],
      competitors: [range(0;12) | {team: {displayName: ("Team " + (. | tostring))}, score: (. | tostring), winner: (. == 0)}]
    }]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
RC=$?
eq "rc=0" "0" "$RC"
eq "URL carries league and team" \
  "https://espn.test/sports/baseball/mlb/teams/laa/schedule" "$(urls)"
eq "team name carried" "Los Angeles Angels" "$(jq -r '.team' <<<"$OUT")"
eq "team_id carried" "laa" "$(jq -r '.team_id' <<<"$OUT")"
eq "event name mapped" "Angels at Athletics" "$(jq -r '.events[0].name' <<<"$OUT")"
eq "event date split from datetime" "2026-09-14" "$(jq -r '.events[0].date' <<<"$OUT")"
eq "event status mapped" "Final" "$(jq -r '.events[0].status' <<<"$OUT")"
eq "note headline mapped" "Doubleheader Game 1" "$(jq -r '.events[0].notes[0]' <<<"$OUT")"
eq "competitors capped at 10" "10" "$(jq '.events[0].competitors | length' <<<"$OUT")"

echo "== espn_team_schedule: a competitor's overall record is carried, home/road splits are not =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [{
    name: "Angels at Athletics",
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{
      notes: [],
      competitors: [{
        team: {displayName: "Los Angeles Angels"},
        score: "4",
        winner: true,
        records: [{name: "overall", summary: "67-73"}, {name: "Home", summary: "34-37"}, {name: "Road", summary: "33-36"}]
      }]
    }]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
eq "overall summary carried as record" "67-73" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"
eq "home/road splits not carried" "false" "$(jq '.events[0].competitors[0] | has("Home") or has("Road")' <<<"$OUT")"

echo "== espn_team_schedule: a competitor with no records array reduces cleanly to a null record =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [{
    name: "Angels at Athletics",
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{notes: [], competitors: [{team: {displayName: "Los Angeles Angels"}, score: "4", winner: true}]}]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
RC=$?
eq "rc=0, no error on missing records" "0" "$RC"
eq "record is null" "null" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"

echo "== espn_team_schedule: a competitor with a malformed (non-array) records value reduces cleanly to a null record =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [{
    name: "Angels at Athletics",
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{notes: [], competitors: [{team: {displayName: "Los Angeles Angels"}, score: "4", winner: true, records: "not-an-array"}]}]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
RC=$?
eq "rc=0, no error on malformed records" "0" "$RC"
eq "record is null" "null" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"

echo "== espn_team_schedule: the event count is capped =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [range(0;25) | {
    name: ("Game " + (. | tostring)),
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{notes: [], competitors: []}]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
eq "events capped" "20" "$(jq '.events | length' <<<"$OUT")"

echo "== espn_team_schedule: the event window excludes events far outside it =="
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [
    {name: "Way in the past", date: "2026-01-01T20:00Z", status: {type:{description:"Final"}}, competitions:[{notes:[],competitors:[]}]},
    {name: "Way in the future", date: "2026-12-01T20:00Z", status: {type:{description:"Scheduled"}}, competitions:[{notes:[],competitors:[]}]},
    {name: "In the window", date: "2026-09-13T20:00Z", status: {type:{description:"Final"}}, competitions:[{notes:[],competitors:[]}]}
  ]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
eq "only the in-window event survives" "1" "$(jq '.events | length' <<<"$OUT")"
eq "the in-window event is the one kept" "In the window" "$(jq -r '.events[0].name' <<<"$OUT")"

echo "== espn_team_schedule: a late-UTC-start event is windowed and dated by its ET calendar day, not the UTC date =="
reset_mock
# 2026-09-05T02:30:00Z is a September 4 game in ET (a 10pm PT first pitch is
# already "tomorrow" in UTC). Window: today=20260901, back=5 -> lo=2026-08-27,
# forward=3 -> hi=2026-09-04. The naive UTC split would put this event on
# 2026-09-05, past hi, and wrongly drop it from the window.
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [{
    name: "Late West Coast start",
    date: "2026-09-05T02:30:00Z",
    status: {type: {description: "Final"}},
    competitions: [{notes: [], competitors: []}]
  }]
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260901")
eq "rc=0" "0" "$?"
eq "the ET-dated event survives at the window's edge" "1" "$(jq '.events | length' <<<"$OUT")"
eq "emitted date is the ET calendar date, not the UTC date" "2026-09-04" "$(jq -r '.events[0].date' <<<"$OUT")"

echo "== _et_session_date: the BSD date fallback converts through UTC, not the parse zone =="
# BSD `date -j -f` parses in the CURRENT zone and matches the trailing Z as a
# literal character, so a one-step TZ=America/New_York parse silently returns
# the naive UTC date. Stub a BSD-shaped date (no GNU -d, has -j/-f and -r) so
# that branch runs on a GNU host, where it otherwise never would.
date() {
  case "${1:-}" in
    -d) return 1 ;;
    -j)
      # BSD matches the format strictly: the seconds-bearing one rejects a
      # minute-precision timestamp, which is why espn.sh tries both.
      case "$3" in
        *:%SZ) [[ "$4" == *T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z ]] || return 1 ;;
        *) [[ "$4" == *T[0-9][0-9]:[0-9][0-9]Z ]] || return 1 ;;
      esac
      command date -d "${4%Z}" "$5"
      ;;
    -r) command date -d "@$2" "$3" ;;
    *) command date "$@" ;;
  esac
}
eq "a late UTC start resolves to the previous ET day" "2026-09-04" "$(_et_session_date "2026-09-05T02:30:00Z")"
eq "the minute-precision form falls through to the second format" "2026-09-04" "$(_et_session_date "2026-09-05T02:30Z")"
eq "a midday UTC start stays on its own ET day" "2026-09-05" "$(_et_session_date "2026-09-05T20:10:00Z")"
eq "an unparseable timestamp returns nonzero" "1" "$(_et_session_date "not-a-timestamp" >/dev/null 2>&1; echo $?)"
unset -f date

echo "== espn_team_schedule: a payload past the argv size limit still reduces =="
# Linux caps a single argv string at 131072 bytes, so the event array has to
# reach jq on stdin -- passing it as --argjson fails execve with E2BIG, which
# this function would report as a failed fetch.
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: [range(0;40) | {
    name: ("Game " + (. | tostring)),
    date: "2026-09-14T20:10Z",
    status: {type: {description: "Final"}},
    filler: ("x" * 5000),
    competitions: [{notes: [], competitors: [{team: {displayName: "Los Angeles Angels"}, score: "4", winner: true}]}]
  }]
}')
BYTES=$(printf '%s' "$REQUEST_BODY" | wc -c)
eq "the fixture is larger than the argv-string limit" "yes" \
  "$( [ "$BYTES" -gt 131072 ] && echo yes || echo no )"
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
RC=$?
eq "rc=0" "0" "$RC"
eq "events capped, not lost to E2BIG" "20" "$(jq '.events | length' <<<"$OUT")"
eq "the first event survives intact" "Game 0" "$(jq -r '.events[0].name' <<<"$OUT")"

echo "== espn_team_schedule: an in-window event deep in a long payload is not truncated away =="
# The window filter, not a slice of the payload's head, is what bounds the
# candidate set: a season's worth of past games ahead of today must not push
# today's game out.
reset_mock
REQUEST_BODY=$(jq -n '{
  team: {displayName: "Los Angeles Angels"},
  events: ([range(0;250) | {
    name: ("Old game " + (. | tostring)),
    date: "2026-04-01T20:10Z",
    status: {type: {description: "Final"}},
    competitions: [{notes: [], competitors: []}]
  }] + [{
    name: "Today",
    date: "2026-09-15T20:10Z",
    status: {type: {description: "Scheduled"}},
    competitions: [{notes: [], competitors: []}]
  }])
}')
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
eq "only the in-window event survives" "1" "$(jq '.events | length' <<<"$OUT")"
eq "the tail event is the one kept" "Today" "$(jq -r '.events[0].name' <<<"$OUT")"

echo "== espn_team_schedule: a 404 on /schedule falls back to the bare team endpoint =="
reset_mock
REQUEST_FAIL_MATCH='/schedule'
REQUEST_BODY=$(jq -n '{
  team: {
    displayName: "Rhode Island Rams",
    nextEvent: [{
      name: "Rhode Island at Brown",
      date: "2026-09-16T23:00Z",
      status: {type: {description: "Scheduled"}},
      competitions: [{notes: [], competitors: [{team: {displayName: "Rhode Island Rams"}}]}]
    }]
  }
}')
OUT=$(espn_team_schedule "football/college-football" "227" "20260915")
RC=$?
eq "rc=0" "0" "$RC"
eq "tries /schedule first, then the bare team endpoint" \
  "https://espn.test/sports/football/college-football/teams/227/schedule
https://espn.test/sports/football/college-football/teams/227" "$(urls)"
eq "team name carried from the fallback payload" "Rhode Island Rams" "$(jq -r '.team' <<<"$OUT")"
eq "nextEvent read as the event list" "Rhode Island at Brown" "$(jq -r '.events[0].name' <<<"$OUT")"
eq "fallback event date split from datetime" "2026-09-16" "$(jq -r '.events[0].date' <<<"$OUT")"

echo "== espn_team_schedule: both endpoints failing returns nonzero and emits nothing =="
reset_mock
REQUEST_FAIL_MATCH='/teams/'
OUT=$(espn_team_schedule "football/college-football" "227" "20260915" 2>/dev/null)
RC=$?
eq "rc=1" "1" "$RC"
eq "emits nothing" "" "$OUT"

echo "== espn_team_schedule: an unparseable team payload returns nonzero and emits nothing =="
reset_mock
REQUEST_BODY='<html>maintenance</html>'
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915" 2>/dev/null)
RC=$?
eq "rc=1" "1" "$RC"
eq "emits nothing" "" "$OUT"
eq "a parseable fetch that answered garbage is not retried elsewhere" "1" "$(urls | grep -c .)"

echo "== espn_team_schedule: an empty team payload returns nonzero and emits nothing =="
reset_mock
REQUEST_BODY=''
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915" 2>/dev/null)
RC=$?
eq "rc=1" "1" "$RC"
eq "emits nothing" "" "$OUT"

echo "== espn_team_schedule: a failed fetch returns nonzero and emits nothing =="
reset_mock
REQUEST_RC=7
OUT=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
RC=$?
eq "rc=1" "1" "$RC"
eq "emits nothing" "" "$OUT"

echo "== espn_team_schedule: empty args are rejected without a fetch =="
reset_mock
OUT=$(espn_team_schedule "" "laa" "20260915")
RC=$?
eq "rc=1" "1" "$RC"
eq "no fetch attempted" "" "$(urls)"

echo "== espn_slim_league: a competitor's overall record is carried, home/road splits are not =="
SB=$(jq -n '{events: [{
  name: "Team A at Team B",
  date: "2026-09-14T20:10Z",
  status: {type: {description: "Final"}},
  competitions: [{
    notes: [],
    competitors: [{
      team: {displayName: "Team A"},
      score: "4",
      winner: true,
      records: [{name: "overall", summary: "67-73"}, {name: "Home", summary: "34-37"}, {name: "Road", summary: "33-36"}]
    }]
  }]
}]}')
OUT=$(espn_slim_league "baseball/mlb" "$SB" '{"articles":[]}')
eq "overall summary carried as record" "67-73" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"
eq "home/road splits not carried" "false" "$(jq '.events[0].competitors[0] | has("Home") or has("Road")' <<<"$OUT")"

echo "== espn_slim_league: a competitor with no records array reduces cleanly to a null record =="
SB=$(jq -n '{events: [{
  name: "Team A at Team B",
  date: "2026-09-14T20:10Z",
  status: {type: {description: "Final"}},
  competitions: [{notes: [], competitors: [{team: {displayName: "Team A"}, score: "4", winner: true}]}]
}]}')
OUT=$(espn_slim_league "baseball/mlb" "$SB" '{"articles":[]}')
eq "record is null" "null" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"

echo "== espn_slim_league: a competitor with a malformed (non-array) records value reduces cleanly to a null record =="
SB=$(jq -n '{events: [{
  name: "Team A at Team B",
  date: "2026-09-14T20:10Z",
  status: {type: {description: "Final"}},
  competitions: [{notes: [], competitors: [{team: {displayName: "Team A"}, score: "4", winner: true, records: "not-an-array"}]}]
}]}')
OUT=$(espn_slim_league "baseball/mlb" "$SB" '{"articles":[]}')
eq "record is null" "null" "$(jq -r '.events[0].competitors[0].record' <<<"$OUT")"

echo "== espn_parse_follow: parses multiple entries, tolerates whitespace, keeps the rest past a malformed entry =="
OUT=$(espn_parse_follow " baseball/mlb:laa , basketball/nba:ny,bad-entry-no-colon, basketball/nba:cha , football/college-football: " 2>/dev/null)
eq "3 valid entries survive" "3" "$(printf '%s\n' "$OUT" | grep -c .)"
eq "first entry" "$(printf 'baseball/mlb\tlaa')" "$(printf '%s\n' "$OUT" | sed -n '1p')"
eq "second entry" "$(printf 'basketball/nba\tny')" "$(printf '%s\n' "$OUT" | sed -n '2p')"
eq "third entry" "$(printf 'basketball/nba\tcha')" "$(printf '%s\n' "$OUT" | sed -n '3p')"

echo "== espn_parse_follow: whitespace around the colon is trimmed, not carried into the URL =="
OUT=$(espn_parse_follow "baseball/mlb: laa , basketball/nba :ny" 2>/dev/null)
eq "space after the colon dropped" "$(printf 'baseball/mlb\tlaa')" "$(printf '%s\n' "$OUT" | sed -n '1p')"
eq "space before the colon dropped" "$(printf 'basketball/nba\tny')" "$(printf '%s\n' "$OUT" | sed -n '2p')"

echo "== espn_parse_follow: a whitespace-only half is a malformed entry, not a blank team_id =="
OUT=$(espn_parse_follow "baseball/mlb:   ,basketball/nba:ny" 2>/dev/null)
eq "only the valid entry survives" "$(printf 'basketball/nba\tny')" "$OUT"

echo "== espn_parse_follow: unset/empty input emits nothing (the SPORTS_LEAGUES-only regression guard) =="
OUT=$(espn_parse_follow "" 2>/dev/null)
RC=$?
eq "rc=0" "0" "$RC"
eq "emits nothing" "" "$OUT"

echo "== followed-team and league-news entries for the same league are structurally distinguishable =="
reset_mock
REQUEST_BODY=$(jq -n '{team:{displayName:"Los Angeles Angels"}, events:[{name:"Angels at Athletics", date:"2026-09-14T20:10Z", status:{type:{description:"Final"}}, competitions:[{notes:[],competitors:[]}]}]}')
FOLLOWED=$(espn_team_schedule "baseball/mlb" "laa" "20260915")
LEAGUE=$(espn_slim_league "baseball/mlb" '{"events":[]}' '{"articles":[]}')
eq "followed carries team_id" "laa" "$(jq -r '.team_id' <<<"$FOLLOWED")"
eq "league entry has no team_id key" "false" "$(jq 'has("team_id")' <<<"$LEAGUE")"
eq "league entry carries headlines key" "true" "$(jq 'has("headlines")' <<<"$LEAGUE")"
eq "followed entry has no headlines key" "false" "$(jq 'has("headlines")' <<<"$FOLLOWED")"

echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "test-espn: all checks passed"
  exit 0
else
  echo "test-espn: $FAIL check(s) failed"
  exit 1
fi
