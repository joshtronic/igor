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
  {"repo":"acme/carve","number":3,"title":"awaiting reviewer","url":"u3","state":"open","gate":"","require_human":true},
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

echo "== shipreport_metrics_build: merges cost/timing/version into one object =="
COST_NOW='{"count":2,"has_data":true,"total_usd":12.3,"by_site":[{"site":"tier-1-issue","usd":9.43,"count":1},{"site":"review","usd":2.87,"count":1}]}'
COST_PREV='{"count":1,"has_data":true,"total_usd":8.0,"by_site":[]}'
COST_PREV_NONE='{"count":0,"has_data":false,"total_usd":0,"by_site":[]}'
TIMING_NOW='{"count":1440,"has_data":true,"median_s":12,"p90_s":45,"max_s":3612}'
TIMING_PREV='{"count":1440,"has_data":true,"median_s":10,"p90_s":40,"max_s":3600}'
CV_BEHIND='{"installed":"2.1.229","latest":"2.1.269","checked_ok":true,"behind":true,"since_days":31}'
CV_CURRENT='{"installed":"2.1.269","latest":"2.1.269","checked_ok":true,"behind":false,"since_days":1}'
CV_UNKNOWN='{"installed":null,"latest":null,"checked_ok":false,"behind":false,"since_days":null}'

METRICS=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV" "$TIMING_NOW" "$TIMING_PREV" "$CV_BEHIND")
eq "metrics: delta_usd computed"    "4.3" "$(jq -r '.metrics.cost.delta_usd' <<<"$METRICS")"
eq "metrics: delta_median_s computed" "2" "$(jq -r '.metrics.timing.delta_median_s' <<<"$METRICS")"
eq "metrics: claude_version passed through" "2.1.229" "$(jq -r '.claude_version.installed' <<<"$METRICS")"

METRICS_NO_PREV=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV_NONE" "$TIMING_NOW" "$TIMING_PREV" "$CV_BEHIND")
eq "metrics: no prior data -> delta_usd null" "null" "$(jq -r '.metrics.cost.delta_usd' <<<"$METRICS_NO_PREV")"

echo "== shipreport_is_empty: metrics/version can keep an otherwise-quiet report NOT empty =="
QUIET='{"needs_you":[],"shipped":[],"inflight":[]}'
WITH_COST=$(jq -c --argjson m "$METRICS" '. + $m' <<<"$QUIET")
no "is_empty: real cost data present -> NOT empty" shipreport_is_empty "$WITH_COST"

COST_ZERO=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_CURRENT")
WITH_NO_DATA=$(jq -c --argjson m "$COST_ZERO" '. + $m' <<<"$QUIET")
ok "is_empty: no cost/timing data + version current -> still empty" shipreport_is_empty "$WITH_NO_DATA"

COST_ZERO_BEHIND=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_BEHIND")
WITH_BEHIND_ONLY=$(jq -c --argjson m "$COST_ZERO_BEHIND" '. + $m' <<<"$QUIET")
no "is_empty: version behind alone -> NOT empty" shipreport_is_empty "$WITH_BEHIND_ONLY"

echo "== renderers: cost/timing + version sections =="
FULL_REPORT=$(jq -c --argjson m "$METRICS" '. + $m' <<<"$REPORT")
FTEXT=$(shipreport_render_text <<<"$FULL_REPORT")
has "text: COST & TIMING heading"      "$FTEXT" "COST & TIMING"
has "text: total spend"                "$FTEXT" '$12.3'
has "text: delta vs prior period"      "$FTEXT" "vs prior 24h"
has "text: per-call-site breakdown"    "$FTEXT" "tier-1-issue: \$9.43"
has "text: tick count + median/p90"    "$FTEXT" "median 12s"
has "text: BEHIND version line"        "$FTEXT" "BEHIND latest 2.1.269"
FHTML=$(shipreport_render_html <<<"$FULL_REPORT")
has "html: cost/timing block present"  "$FHTML" "COST & TIMING"
has "html: version line present"       "$FHTML" "BEHIND latest 2.1.269"

echo "== renderers: no metrics key -> no cost/version section (existing plain report) =="
NO_METRICS_TEXT=$(shipreport_render_text <<<"$REPORT")
if printf '%s' "$NO_METRICS_TEXT" | grep -q 'COST & TIMING'; then
  printf '  x %s\n' "text: no COST & TIMING section when metrics was never merged in"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: no COST & TIMING section when metrics was never merged in"
fi

echo "== renderers: stale ledger says so explicitly, never a bare \$0.00 =="
NO_DATA_METRICS=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_UNKNOWN")
STALE_REPORT=$(jq -c --argjson m "$NO_DATA_METRICS" '. + $m' <<<"$REPORT")
STEXT=$(shipreport_render_text <<<"$STALE_REPORT")
has "text: says no cost data recorded"   "$STEXT" "no cost data recorded"
has "text: says no tick-timing data"     "$STEXT" "no tick-timing data recorded"
has "text: says could not check version" "$STEXT" "could not check"
if printf '%s' "$STEXT" | grep -q '\$0\.00'; then
  printf '  x %s\n' "text: never prints a bare \$0.00 for missing data"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: never prints a bare \$0.00 for missing data"
fi

echo "== renderers: version current -> one quiet line, not silence =="
CURRENT_METRICS=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV" "$TIMING_NOW" "$TIMING_PREV" "$CV_CURRENT")
CURRENT_REPORT=$(jq -c --argjson m "$CURRENT_METRICS" '. + $m' <<<"$REPORT")
CTEXT=$(shipreport_render_text <<<"$CURRENT_REPORT")
has "text: up to date line"  "$CTEXT" "up to date"
if printf '%s' "$CTEXT" | grep -q 'BEHIND'; then
  printf '  x %s\n' "text: does not shout BEHIND when current"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: does not shout BEHIND when current"
fi

echo "== shipreport_judgment_build + rendering (igor#610) =="
eq "judgment_build with no arg defaults to an empty array" "[]" "$(jq -c '.judgment_items' <<<"$(shipreport_judgment_build)")"

NO_JUDGMENT_TEXT=$(shipreport_render_text <<<"$REPORT")
has "text: JUDGMENT ITEMS section renders even when never merged in (mandatory)" \
  "$NO_JUDGMENT_TEXT" "JUDGMENT ITEMS"
has "text: says nothing unresolved when absent" \
  "$NO_JUDGMENT_TEXT" "no unresolved judgment items"
NO_JUDGMENT_HTML=$(shipreport_render_html <<<"$REPORT")
has "html: Judgment items heading renders even when never merged in (mandatory)" \
  "$NO_JUDGMENT_HTML" "Judgment items"
has "html: says nothing unresolved when absent" \
  "$NO_JUDGMENT_HTML" "no unresolved judgment items"

JUDGMENT_JSON='[{"repo":"acme/x","number":12,"title":"Fix thing","url":"https://forge/acme/x/pulls/12","items":[
  {"kind":"review","verdict":"REQUEST_CHANGES","comment_url":"https://forge/acme/x/pulls/12#issuecomment-1","created_at":"2026-01-01T00:00:00Z","body":"This silently drops errors on line 42."},
  {"kind":"dismissal","verdict":null,"comment_url":"","created_at":"2026-01-01T01:00:00Z","body":"Dismissed: the caller already guards against it."}
]}]'
JUDGMENT=$(shipreport_judgment_build "$JUDGMENT_JSON")
eq "judgment_build: one PR carried through" "1" "$(jq -r '.judgment_items | length' <<<"$JUDGMENT")"

REPORT_WITH_JUDGMENT=$(jq -c --argjson j "$JUDGMENT" '. + $j' <<<"$REPORT")
JTEXT=$(shipreport_render_text <<<"$REPORT_WITH_JUDGMENT")
has "text: JUDGMENT ITEMS count in heading"  "$JTEXT" "1 PR(s), 2 item(s)"
has "text: names the repo#PR"                "$JTEXT" "acme/x#12"
has "text: shows the review's verdict"       "$JTEXT" "[REQUEST_CHANGES]"
has "text: deep-links the review comment"    "$JTEXT" "issuecomment-1"
has "text: body kept verbatim"               "$JTEXT" "This silently drops errors on line 42."
has "text: shows a dismissal as unresolved"  "$JTEXT" "[dismissed]"
has "text: dismissal reasoning kept verbatim" "$JTEXT" "Dismissed: the caller already guards against it."
has "text: no direct link falls back to a plain note" "$JTEXT" "(no direct link)"

JHTML=$(shipreport_render_html <<<"$REPORT_WITH_JUDGMENT")
has "html: names the repo#PR"                "$JHTML" "acme/x#12"
has "html: links the review comment"         "$JHTML" 'href="https://forge/acme/x/pulls/12#issuecomment-1"'
has "html: shows the dismissal verdict badge" "$JHTML" "[dismissed]"
has "html: body kept verbatim"               "$JHTML" "This silently drops errors on line 42."

echo "== do_shipreport_tick guards an empty comment fetch before the call =="
# Source-assertion, in the spirit of test-automerge-before-health-gate.sh.
# review_corpus_judgment_items reads STDIN when its argument is empty, and
# stdin inside do_shipreport_tick's merged-PR loop is the process
# substitution feeding that loop -- so an empty-but-successful
# forgejo_pr_comments would drain the remaining PRs into `cat` and end the
# loop early with no log line. The `|| comments='[]'` fallback alone does
# not cover that: it only fires on a NONZERO exit.
TICK_SRC="$HERE/tick.sh"
GATHER=$(sed -n '/local pr_line pr_num pr_title pr_url comments pr_judgment/,/^    done < <(jq -c/p' "$TICK_SRC")
has "the gather loop was found in bin/tick.sh" "$GATHER" "review_corpus_judgment_items"
has "empty comments are coerced to [] before the call" "$GATHER" '[ -n "$comments" ] || comments='"'"'[]'"'"
has "an empty judgment result is coerced too"          "$GATHER" '[ -n "$pr_judgment" ] || pr_judgment='"'"'[]'"'"
has "a failed append is logged, not swallowed"         "$GATHER" "dropped judgment items"

echo "== fully scripted: no model call in the module =="
if grep -qE "claude_call|claude_run|anthropic_call" "$HERE/../lib/ship-report.sh"; then
  printf '  x %s\n' "ship-report.sh contains a model call"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "ship-report.sh makes no model call"
fi

[ "$FAIL" -eq 0 ] && { echo "test-shipreport: all checks passed"; exit 0; }
echo "test-shipreport: $FAIL check(s) FAILED"
exit 1
