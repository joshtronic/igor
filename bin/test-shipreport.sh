#!/usr/bin/env bash
# test-shipreport.sh -- unit tests for lib/ship-report.sh: bucketing, the
# shadow-vs-human gate tag, empty-window handling, the daily stamp round-trip,
# and that the module makes NO model call (it's fully scripted). Skip-safe:
# needs jq; exits 0 with a notice if absent, like the other bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-shipreport: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/ship-report.sh
. "$HERE/../lib/ship-report.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== shipreport_build: bucketing + gate tag =="
ITEMS='[
  {"repo":"acme/deffo","number":1,"title":"shadow merge","url":"u1","state":"merged","gate":"shadow","require_human":false},
  {"repo":"acme/carve","number":2,"title":"human merge","url":"u2","state":"merged","gate":"human","require_human":true},
  {"repo":"acme/carve","number":3,"title":"awaiting josh","url":"u3","state":"open","gate":"","require_human":true},
  {"repo":"acme/deffo","number":4,"title":"in the loop","url":"u4","state":"open","gate":"","require_human":false}
]'
REPORT=$(printf '%s' "$ITEMS" | shipreport_build)
eq "shipped: both merges"           "1 2" "$(jq -r '[.shipped[].number]|join(" ")' <<<"$REPORT")"
eq "needs_you: open carve-out PR"   "3"   "$(jq -r '[.needs_you[].number]|join(" ")' <<<"$REPORT")"
eq "inflight: open default PR"      "4"   "$(jq -r '[.inflight[].number]|join(" ")' <<<"$REPORT")"

echo "== shipreport_is_empty =="
ok "is_empty: all buckets empty"    shipreport_is_empty '{"needs_you":[],"shipped":[],"inflight":[]}'
no "is_empty: something present"    shipreport_is_empty "$REPORT"

echo "== renderers (text + html) =="
TEXT=$(printf '%s' "$REPORT" | shipreport_render_text)
has "text: NEEDS YOU section"       "$TEXT" "NEEDS YOU"
has "text: SHIPPED section"         "$TEXT" "SHIPPED"
has "text: tags a shadow merge"     "$TEXT" "[shadow]"
has "text: tags a human merge"      "$TEXT" "[you]"
has "text: lists the needs-you PR"  "$TEXT" "acme/carve#3"
HTML=$(printf '%s' "$REPORT" | shipreport_render_html)
has "html: wraps in a div"          "$HTML" "<div"
has "html: links a shipped PR"      "$HTML" 'href="u1"'
has "html: links the needs-you PR"  "$HTML" 'href="u3"'
has "html: escapes titles via @html" "$HTML" "shadow merge"

echo "== empty report renders cleanly (no crash, says so) =="
EMPTY=$(printf '%s' '{"needs_you":[],"shipped":[],"inflight":[]}' | shipreport_render_text)
has "empty text: nothing shipped"   "$EMPTY" "nothing shipped"

echo "== daily stamp round-trip =="
no "sent_today: fresh -> not sent"  shipreport_sent_today
shipreport_mark_sent
ok "sent_today: after mark -> sent" shipreport_sent_today

echo "== landed-note drain (igor#512): read / merge / is_empty / clear =="
eq "landed_read: nothing queued -> empty array" "[]" "$(shipreport_landed_read)"
MERGED_EMPTY=$(shipreport_merge_landed '{"needs_you":[],"shipped":[],"inflight":[]}' "[]")
eq "merge_landed with an empty array adds an empty landed key" "0" "$(jq -r '.landed | length' <<<"$MERGED_EMPTY")"
ok "is_empty: landed key present but empty still counts as empty" shipreport_is_empty "$MERGED_EMPTY"
ETEXT=$(shipreport_render_text <<<"$MERGED_EMPTY")
has "text: an explicitly-merged empty bucket renders an empty section" "$ETEXT" "(nothing landed)"
EHTML=$(shipreport_render_html <<<"$MERGED_EMPTY")
has "html: an explicitly-merged empty bucket renders an empty section" "$EHTML" "nothing landed"

LANDED_JSON='[{"repo":"joshtronic/igor","pr":"521","sha":"c0ffee1234567890","detail":"self-pull HEAD is c0ffee12"}]'
MERGED=$(shipreport_merge_landed '{"needs_you":[],"shipped":[],"inflight":[]}' "$LANDED_JSON")
no "is_empty: landed notes alone -> NOT empty (still sends)" shipreport_is_empty "$MERGED"
eq "merge_landed: one landed note present" "1" "$(jq -r '.landed | length' <<<"$MERGED")"

LTEXT=$(shipreport_render_text <<<"$MERGED")
has "text: LANDED section appears"          "$LTEXT" "LANDED"
has "text: names the landed repo#pr"        "$LTEXT" "joshtronic/igor#521"
has "text: truncates the sha to 8 chars"    "$LTEXT" "c0ffee12"
LHTML=$(shipreport_render_html <<<"$MERGED")
has "html: Landed heading appears"          "$LHTML" "Landed"
has "html: names the landed repo#pr"        "$LHTML" "joshtronic/igor#521"

NO_LANDED_TEXT=$(shipreport_render_text <<<"$REPORT")
if printf '%s' "$NO_LANDED_TEXT" | grep -q 'LANDED'; then
  printf '  x %s\n' "text: no LANDED section when the report never merged one in"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: no LANDED section when the report never merged one in"
fi

sf="$AGENT_STATE_DIR/discretionary-state.json"
jq -n --argjson l "$LANDED_JSON" '{landed_notes: $l}' > "$sf"
eq "landed_read: reads back what was queued" "$LANDED_JSON" "$(shipreport_landed_read)"
shipreport_landed_clear
eq "landed_clear: drains the queue" "[]" "$(shipreport_landed_read)"
eq "landed_clear: is a no-op when the state file is missing" "[]" "$(rm -f "$sf"; shipreport_landed_clear; shipreport_landed_read)"

echo "== fully scripted: no model call in the module =="
if grep -qE "claude_call|claude_run|anthropic_call" "$HERE/../lib/ship-report.sh"; then
  printf '  x %s\n' "ship-report.sh contains a model call"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "ship-report.sh makes no model call"
fi

[ "$FAIL" -eq 0 ] && { echo "test-shipreport: all checks passed"; exit 0; }
echo "test-shipreport: $FAIL check(s) FAILED"
exit 1
