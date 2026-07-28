#!/usr/bin/env bash
# test-needsyou.sh -- unit tests for the pure functions in lib/needsyou.sh:
# the event-driven "needs you" diff engine (new-vs-carried-vs-gone), the wait-time
# formatter, the renderers, and the notified-set state round-trip. Skip-safe:
# needs jq; exits 0 with a notice if absent, like the other bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-needsyou: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/needsyou.sh
. "$HERE/../lib/needsyou.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }
hasnt() { case "$2" in *"$3"*) printf '  x %s: [%s] unexpectedly has [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "$1" ;; esac; }

NOW=$(( 1700000000 ))

echo "== needsyou_add_item builds a well-shaped item =="
ITEMS='[]'
ITEMS=$(needsyou_add_item "$ITEMS" "issue:acme/x#1" "acme/x" "labeled Status/Blocked" "https://x/1" "$NOW")
eq "one item added"        "1"                  "$(jq 'length' <<<"$ITEMS")"
eq "id round-trips"        "issue:acme/x#1"     "$(jq -r '.[0].id' <<<"$ITEMS")"
eq "repo round-trips"      "acme/x"             "$(jq -r '.[0].repo' <<<"$ITEMS")"
eq "since round-trips"     "$NOW"               "$(jq -r '.[0].since' <<<"$ITEMS")"

echo "== needsyou_current_ids =="
TWO=$(needsyou_add_item "$ITEMS" "pr:acme/x#2" "acme/x" "awaiting review" "https://x/2" "$NOW")
eq "two ids"                '["issue:acme/x#1","pr:acme/x#2"]' "$(jq -c '.' <<<"$(needsyou_current_ids "$TWO")")"

echo "== needsyou_new_items: the four acceptance scenarios =="
A=$(needsyou_add_item '[]' "A" "acme/x" "why A" "u" "$NOW")
B=$(needsyou_add_item '[]' "B" "acme/x" "why B" "u" "$NOW")
AB=$(jq -c -s 'add' <<<"$(printf '%s\n%s' "$A" "$B")")

eq "first entry: prev empty, A present -> A is new" \
  "A" "$(jq -r '.[0].id' <<<"$(needsyou_new_items '[]' "$A")")"

eq "unchanged set: prev=[A], current=[A] -> silent" \
  "0" "$(jq 'length' <<<"$(needsyou_new_items '["A"]' "$A")")"

eq "removal: prev=[A,B], current=[B] -> silent" \
  "0" "$(jq 'length' <<<"$(needsyou_new_items '["A","B"]' "$B")")"

eq "second distinct item: prev=[A], current=[A,B] -> only B is new" \
  "B" "$(jq -r '.[0].id' <<<"$(needsyou_new_items '["A"]' "$AB")")"

echo "== needsyou_fmt_wait =="
eq "just now (0s)"    "just now" "$(needsyou_fmt_wait "$NOW" "$NOW")"
eq "just now (59s)"   "just now" "$(needsyou_fmt_wait "$((NOW - 59))" "$NOW")"
eq "5 minutes"        "5m"       "$(needsyou_fmt_wait "$((NOW - 5*60))" "$NOW")"
eq "3 hours"          "3h"       "$(needsyou_fmt_wait "$((NOW - 3*3600))" "$NOW")"
eq "3 days"           "3d"       "$(needsyou_fmt_wait "$((NOW - 3*86400))" "$NOW")"

echo "== renderers (text + html), grouped by repo, wait time shown =="
C=$(needsyou_add_item '[]' "C" "acme/y" "a minute-old thing" "https://y/1" "$NOW")
STALE=$(needsyou_add_item '[]' "D" "acme/x" "a three-day-old thing" "https://x/3" "$((NOW - 3*86400))")
MULTI=$(jq -c -s 'add' <<<"$(printf '%s\n%s\n%s' "$A" "$C" "$STALE")")

TEXT=$(needsyou_render_text "$NOW" <<<"$MULTI")
has "text: groups acme/x"          "$TEXT" "acme/x"
has "text: groups acme/y"          "$TEXT" "acme/y"
has "text: names the why"          "$TEXT" "why A"
has "text: shows a fresh wait"     "$TEXT" "just now"
has "text: shows a 3-day wait"     "$TEXT" "3d"
has "text: links the item"         "$TEXT" "https://x/3"

EMPTY_TEXT=$(needsyou_render_text "$NOW" <<<"[]")
has "text: empty set says so"      "$EMPTY_TEXT" "nothing"

HTML=$(needsyou_render_html "$NOW" <<<"$MULTI")
has "html: wraps in a div"         "$HTML" "<div"
has "html: links an item"          "$HTML" 'href="https://x/3"'
has "html: shows a 3-day wait"     "$HTML" "3d"

echo "== notified-ids state round-trip =="
SF="$TMP/discretionary-state.json"
eq "load: fresh state -> empty"    "[]" "$(needsyou_load_ids "$SF")"
needsyou_save_ids "$SF" '["A","B"]'
eq "load: after save -> round-trips" '["A","B"]' "$(needsyou_load_ids "$SF")"
needsyou_save_ids "$SF" '["B"]'
eq "save: overwrites, does not merge" '["B"]' "$(needsyou_load_ids "$SF")"

echo "== fully scripted: no model call in the module =="
if grep -qE "claude_call|claude_run|anthropic_call" "$HERE/../lib/needsyou.sh"; then
  printf '  x %s\n' "needsyou.sh contains a model call"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "needsyou.sh makes no model call"
fi

[ "$FAIL" -eq 0 ] && { echo "test-needsyou: all checks passed"; exit 0; }
echo "test-needsyou: $FAIL check(s) FAILED"
exit 1
