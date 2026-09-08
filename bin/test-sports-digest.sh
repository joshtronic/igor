#!/usr/bin/env bash
# test-sports-digest.sh -- unit tests for lib/sports-digest.sh's story
# ledger: the "what did we already send" record that sits alongside the
# taught-concepts curriculum (igor#598). No network -- these are pure
# jq/file functions.
# Skip-safe: needs jq and mktemp; exits 0 with a notice if either is absent.
set -uo pipefail

for tool in jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test-sports-digest: $tool absent -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"

STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
export AGENT_STATE_DIR="$STATE_DIR"

# shellcheck source=../lib/sports-digest.sh
. "$HERE/../lib/sports-digest.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

reset_state() { rm -f "$STATE_DIR/sports-curriculum.json"; }

echo "== sports_stories_load: no file yet behaves as nothing reported =="
reset_state
OUT=$(sports_stories_load)
eq "empty articles" "[]" "$(jq -c '.articles' <<<"$OUT")"
eq "empty events" "[]" "$(jq -c '.events' <<<"$OUT")"

echo "== sports_stories_load: a curriculum file with only concepts (the real upgrade path) doesn't crash =="
reset_state
printf '{"concepts":[{"name":"offside","date":"2026-09-01"}]}' > "$STATE_DIR/sports-curriculum.json"
OUT=$(sports_stories_load)
RC=$?
eq "rc=0" "0" "$RC"
eq "empty articles" "[]" "$(jq -c '.articles' <<<"$OUT")"
eq "empty events" "[]" "$(jq -c '.events' <<<"$OUT")"

echo "== sports_stories_filter_news: a link recorded yesterday is dropped from today's payload =="
PAYLOAD='[{"league":"basketball/nba","events":[],"headlines":[{"headline":"Star signs deal","link":"http://espn.test/a"}]}]'
STORIES='{"articles":[{"link":"http://espn.test/a","date":"2026-09-06"}],"events":[]}'
OUT=$(sports_stories_filter_news "$PAYLOAD" "$STORIES" "2026-09-07")
eq "the repeated headline is gone" "0" "$(jq '.[0].headlines | length' <<<"$OUT")"

echo "== sports_stories_filter_news: a link recorded 8 days ago survives -- the window expires =="
PAYLOAD='[{"league":"basketball/nba","events":[],"headlines":[{"headline":"Star signs deal","link":"http://espn.test/a"}]}]'
STORIES='{"articles":[{"link":"http://espn.test/a","date":"2026-08-30"}],"events":[]}'
OUT=$(sports_stories_filter_news "$PAYLOAD" "$STORIES" "2026-09-07")
eq "the stale-recorded headline stays" "1" "$(jq '.[0].headlines | length' <<<"$OUT")"
eq "it is the same headline" "Star signs deal" "$(jq -r '.[0].headlines[0].headline' <<<"$OUT")"

echo "== sports_stories_filter_news: an unrecorded link is untouched =="
PAYLOAD='[{"league":"basketball/nba","events":[],"headlines":[{"headline":"Fresh news","link":"http://espn.test/z"}]}]'
STORIES='{"articles":[],"events":[]}'
OUT=$(sports_stories_filter_news "$PAYLOAD" "$STORIES" "2026-09-07")
eq "the fresh headline survives" "1" "$(jq '.[0].headlines | length' <<<"$OUT")"

echo "== sports_stories_mark_events: a completed event recorded yesterday is still present, carrying reported_on =="
PAYLOAD='[{"league":"basketball/nba","events":[{"name":"Lakers at Warriors","date":"2026-09-06","status":"Final"}],"headlines":[]}]'
STORIES='{"articles":[],"events":[{"key":"basketball/nba|2026-09-06|Lakers at Warriors","reported_on":"2026-09-06"}]}'
OUT=$(sports_stories_mark_events "$PAYLOAD" "$STORIES")
eq "the event is still present" "1" "$(jq '.[0].events | length' <<<"$OUT")"
eq "it carries reported_on" "2026-09-06" "$(jq -r '.[0].events[0].reported_on' <<<"$OUT")"

echo "== sports_stories_mark_events: a completed event never reported carries no reported_on =="
PAYLOAD='[{"league":"basketball/nba","events":[{"name":"Bucks at Celtics","date":"2026-09-06","status":"Final"}],"headlines":[]}]'
STORIES='{"articles":[],"events":[]}'
OUT=$(sports_stories_mark_events "$PAYLOAD" "$STORIES")
eq "no reported_on key" "false" "$(jq '.[0].events[0] | has("reported_on")' <<<"$OUT")"

echo "== sports_stories_record: a completed event included in the digest is recorded, keyed on league+date+name =="
PAYLOAD='[{"league":"basketball/nba","events":[{"name":"Lakers at Warriors","date":"2026-09-06","status":"Final"}],"headlines":[]}]'
FOLLOWED='[]'
STORIES='{"articles":[],"events":[]}'
OUT=$(sports_stories_record "$PAYLOAD" "$FOLLOWED" "$STORIES" "2026-09-07")
eq "one event recorded" "1" "$(jq '.events | length' <<<"$OUT")"
eq "keyed on league+date+name" "basketball/nba|2026-09-06|Lakers at Warriors" "$(jq -r '.events[0].key' <<<"$OUT")"
eq "stamped with today, not yesterday's date" "2026-09-07" "$(jq -r '.events[0].reported_on' <<<"$OUT")"

echo "== sports_stories_record: a non-completed event is not recorded =="
PAYLOAD='[{"league":"basketball/nba","events":[{"name":"Bucks at Celtics","date":"2026-09-06","status":"Scheduled"}],"headlines":[]}]'
OUT=$(sports_stories_record "$PAYLOAD" '[]' '{"articles":[],"events":[]}' "2026-09-07")
eq "no events recorded" "0" "$(jq '.events | length' <<<"$OUT")"

echo "== sports_stories_record: every article link in the payload is recorded =="
PAYLOAD='[{"league":"basketball/nba","events":[],"headlines":[{"headline":"H1","link":"http://espn.test/a"},{"headline":"H2","link":"http://espn.test/b"}]}]'
OUT=$(sports_stories_record "$PAYLOAD" '[]' '{"articles":[],"events":[]}' "2026-09-07")
eq "both links recorded" "2" "$(jq '.articles | length' <<<"$OUT")"
eq "stamped with today" "2026-09-07" "$(jq -r '.articles[0].date' <<<"$OUT")"

echo "== sports_stories_record: followed-team events are recorded too, not just league events =="
FOLLOWED='[{"league":"baseball/mlb","team_id":"laa","events":[{"name":"Angels at Athletics","date":"2026-09-06","status":"Final"}]}]'
OUT=$(sports_stories_record '[]' "$FOLLOWED" '{"articles":[],"events":[]}' "2026-09-07")
eq "one followed event recorded" "1" "$(jq '.events | length' <<<"$OUT")"
eq "keyed on its own league" "baseball/mlb|2026-09-06|Angels at Athletics" "$(jq -r '.events[0].key' <<<"$OUT")"

echo "== sports_stories_record + sports_stories_save: sending twice in one day does not duplicate entries =="
reset_state
PAYLOAD='[{"league":"basketball/nba","events":[{"name":"Lakers at Warriors","date":"2026-09-06","status":"Final"}],"headlines":[{"headline":"H1","link":"http://espn.test/a"}]}]'
S1=$(sports_stories_load)
S1=$(sports_stories_record "$PAYLOAD" '[]' "$S1" "2026-09-07")
sports_stories_save "$S1"
S2=$(sports_stories_load)
S2=$(sports_stories_record "$PAYLOAD" '[]' "$S2" "2026-09-07")
sports_stories_save "$S2"
FINAL=$(sports_stories_load)
eq "articles not duplicated" "1" "$(jq '.articles | length' <<<"$FINAL")"
eq "events not duplicated" "1" "$(jq '.events | length' <<<"$FINAL")"

echo "== sports_stories_save: preserves the existing concepts ledger untouched =="
reset_state
printf '{"concepts":[{"name":"offside","date":"2026-09-01"}]}' > "$STATE_DIR/sports-curriculum.json"
sports_stories_save '{"articles":[{"link":"http://espn.test/a","date":"2026-09-07"}],"events":[]}'
eq "concepts survive" "offside" "$(jq -r '.concepts[0].name' "$STATE_DIR/sports-curriculum.json")"
eq "stories written alongside" "http://espn.test/a" "$(jq -r '.stories.articles[0].link' "$STATE_DIR/sports-curriculum.json")"

echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "test-sports-digest: all checks passed"
  exit 0
else
  echo "test-sports-digest: $FAIL check(s) failed"
  exit 1
fi
